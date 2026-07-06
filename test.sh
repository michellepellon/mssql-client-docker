#!/usr/bin/env bash
# ABOUTME: Test harness for the mssql-client image: lint (unit), build + structure
# ABOUTME: checks (integration), and a live query against real SQL Server (e2e).

set -euo pipefail

IMAGE="${IMAGE:-mssql-client:test}"
HADOLINT_IMAGE="hadolint/hadolint:v2.14.0-alpine"
MSSQL_SERVER_IMAGE="${MSSQL_SERVER_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Single source of truth for the pinned version is the Dockerfile ARG.
SQLCMD_VERSION="$(sed -n 's/^ARG SQLCMD_VERSION=v//p' "${SCRIPT_DIR}/Dockerfile")"
: "${SQLCMD_VERSION:?could not read SQLCMD_VERSION from ${SCRIPT_DIR}/Dockerfile}"

usage() {
    cat <<EOF
Usage: ./test.sh [stage...]

Stages (default: all three, in order):
  unit         Lint the Dockerfile with hadolint.
  integration  Build the image and verify its structure and runtime behavior.
  e2e          Start a real SQL Server container and run a query through the client.

Environment:
  IMAGE               Image tag to build/test (default: mssql-client:test)
  MSSQL_SERVER_IMAGE  Server image for e2e (default: mcr.microsoft.com/mssql/server:2022-latest)

Examples:
  ./test.sh                # full suite
  ./test.sh unit           # lint only
  ./test.sh integration e2e
EOF
}

PASS=0
FAIL=0
declare -a FAILURES=()

check() {
    local desc="$1" out
    shift
    if out="$("$@" 2>&1)"; then
        echo "  ok: ${desc}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${desc}"
        echo "        command: $*"
        tail -n 20 <<<"${out}" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
        FAILURES+=("${desc}")
    fi
}

check_output() {
    local desc="$1" pattern="$2" out
    shift 2
    if out="$("$@" 2>&1)" && grep -q "${pattern}" <<<"${out}"; then
        echo "  ok: ${desc}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${desc}"
        echo "        command: $*"
        echo "        expected output matching: ${pattern}"
        echo "        got: $(head -c 500 <<<"${out}")"
        FAIL=$((FAIL + 1))
        FAILURES+=("${desc}")
    fi
}

stage_unit() {
    echo "== unit: hadolint =="
    check "Dockerfile passes hadolint" \
        bash -c "docker run --rm -i '${HADOLINT_IMAGE}' hadolint - <'${SCRIPT_DIR}/Dockerfile'"
}

stage_integration() {
    echo "== integration: build + structure =="
    check "image builds" docker build -t "${IMAGE}" "${SCRIPT_DIR}"

    check_output "runs as non-root uid 65532" '^65532:65532$' \
        docker inspect --format '{{.Config.User}}' "${IMAGE}"
    check_output "entrypoint is sqlcmd" "sqlcmd" \
        docker inspect --format '{{json .Config.Entrypoint}}' "${IMAGE}"

    check_output "sqlcmd reports pinned version" "${SQLCMD_VERSION//./\\.}" \
        docker run --rm "${IMAGE}" --version
    check "works with read-only rootfs" \
        docker run --rm --read-only "${IMAGE}" --version

    # A full filesystem listing proves the minimality claims positively,
    # instead of probing a few hardcoded paths.
    local cid listing
    listing="$(mktemp)"
    if cid=$(docker create "${IMAGE}" 2>/dev/null); then
        docker export "${cid}" | tar -tf - | sort >"${listing}"
        docker rm "${cid}" >/dev/null
    fi
    check "image contains the sqlcmd binary" \
        grep -qx 'usr/local/bin/sqlcmd' "${listing}"
    check "upstream NOTICE.md is shipped" \
        grep -qx 'usr/share/doc/sqlcmd/NOTICE.md' "${listing}"
    check "no shell or package manager anywhere in the filesystem" \
        bash -c "! grep -E '(^|/)(sh|bash|ash|dash|busybox|apk|apt|apt-get|dpkg)\$' '${listing}'"
    rm -f "${listing}"

    local size
    size=$(docker inspect --format '{{.Size}}' "${IMAGE}" 2>/dev/null || echo 0)
    check "image size sane (actual: $((size / 1024 / 1024))MB)" \
        bash -c "[ '${size}' -gt 0 ] && [ '${size}' -lt $((50 * 1024 * 1024)) ]"
}

E2E_NET="mssql-e2e-net"
E2E_SERVER="mssql-e2e-server"

cleanup_e2e() {
    docker rm -f "${E2E_SERVER}" >/dev/null 2>&1 || true
    docker network rm "${E2E_NET}" >/dev/null 2>&1 || true
}

stage_e2e() {
    echo "== e2e: live query against SQL Server =="
    local net="${E2E_NET}" server="${E2E_SERVER}"
    # "E2e!" prefix guarantees the upper/lower/digit/symbol classes SQL Server
    # requires; openssl avoids the tr|head SIGPIPE that trips set -o pipefail.
    local sa_password
    sa_password="E2e!$(openssl rand -hex 12)"

    trap cleanup_e2e EXIT
    cleanup_e2e

    docker network create "${net}" >/dev/null
    echo "  starting SQL Server (${MSSQL_SERVER_IMAGE})..."
    docker run -d --name "${server}" --network "${net}" \
        --platform linux/amd64 \
        -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=${sa_password}" \
        "${MSSQL_SERVER_IMAGE}" >/dev/null

    echo "  waiting for SQL Server to accept connections (up to 180s)..."
    local ready=false
    for _ in $(seq 1 60); do
        if docker run --rm --network "${net}" -e "SQLCMDPASSWORD=${sa_password}" "${IMAGE}" \
            -S "${server}" -U sa -C -b -Q "SELECT 1" >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 3
    done

    if [[ "${ready}" != true ]]; then
        echo "  FAIL: SQL Server never became reachable"
        echo "        last 20 lines of server log:"
        docker logs --tail 20 "${server}" 2>&1 | sed 's/^/        /'
        FAIL=$((FAIL + 1))
        FAILURES+=("SQL Server reachable")
        return
    fi
    PASS=$((PASS + 1))
    echo "  ok: SQL Server reachable via client image"

    # -b makes sqlcmd exit nonzero on SQL errors, so these checks cannot
    # pass on error text that happens to contain the expected pattern.
    check_output "query returns server version" "Microsoft SQL Server" \
        docker run --rm --network "${net}" -e "SQLCMDPASSWORD=${sa_password}" "${IMAGE}" \
        -S "${server}" -U sa -C -b -Q "SELECT @@VERSION"

    check_output "query works with read-only rootfs" '^ *3 *$' \
        docker run --rm --read-only --network "${net}" -e "SQLCMDPASSWORD=${sa_password}" "${IMAGE}" \
        -S "${server}" -U sa -C -b -h -1 -Q "SET NOCOUNT ON; SELECT 1+2"
}

main() {
    for s in "$@"; do
        case "${s}" in
            unit|integration|e2e) ;;
            -h|--help) usage; exit 0 ;;
            *) echo "unknown stage: ${s}" >&2; usage >&2; exit 2 ;;
        esac
    done

    local stages=("$@")
    [[ ${#stages[@]} -eq 0 ]] && stages=(unit integration e2e)

    for s in "${stages[@]}"; do
        "stage_${s}"
    done

    echo
    echo "results: ${PASS} passed, ${FAIL} failed"
    if [[ ${FAIL} -gt 0 ]]; then
        printf 'failed: %s\n' "${FAILURES[@]}"
        exit 1
    fi
}

main "$@"
