# ABOUTME: Minimal, hardened MSSQL client image: Microsoft's statically linked
# ABOUTME: go-sqlcmd on distroless/static — no shell, no package manager, non-root.
# syntax=docker/dockerfile:1

# Renovate/dependabot-friendly single source of truth for the upstream release.
ARG SQLCMD_VERSION=v1.10.0

# --- fetch stage: download, checksum-verify, and extract the release binary ---
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS fetch

ARG SQLCMD_VERSION
ARG TARGETARCH
# Upstream publishes no checksum file, so these are pinned from a verified
# download of each release artifact. Both must be updated on version bumps.
ARG SQLCMD_SHA256_AMD64=92516d98c63d99b0994de5b61350c91f6915f9b76f139a59039fbcb225c2e987
ARG SQLCMD_SHA256_ARM64=9faaa981f9c374f319ac796dedb4678499b8596c87d5b6c512e9b0e7a3b74f8e

# Busybox wget (TLS with the bundled CA store) and tar (seamless bzip2) cover
# the whole fetch — no packages installed, nothing to version-pin or trust.
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) sha256="${SQLCMD_SHA256_AMD64}" ;; \
        arm64) sha256="${SQLCMD_SHA256_ARM64}" ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -q -O /tmp/sqlcmd.tar.bz2 \
        "https://github.com/microsoft/go-sqlcmd/releases/download/${SQLCMD_VERSION}/sqlcmd-linux-${TARGETARCH}.tar.bz2"; \
    echo "${sha256}  /tmp/sqlcmd.tar.bz2" | sha256sum -c -; \
    mkdir -p /out; \
    tar -xjf /tmp/sqlcmd.tar.bz2 -C /out sqlcmd NOTICE.md; \
    chmod 0755 /out/sqlcmd; \
    /out/sqlcmd --version

# --- runtime stage: distroless static, non-root, nothing but the binary ------
FROM gcr.io/distroless/static-debian12:nonroot@sha256:d093aa3e30dbadd3efe1310db061a14da60299baff8450a17fe0ccc514a16639

ARG SQLCMD_VERSION
LABEL org.opencontainers.image.title="mssql-client" \
      org.opencontainers.image.description="Minimal non-root MSSQL client (go-sqlcmd) on distroless/static" \
      org.opencontainers.image.version="${SQLCMD_VERSION}" \
      org.opencontainers.image.source="https://github.com/microsoft/go-sqlcmd" \
      org.opencontainers.image.licenses="MIT"

COPY --from=fetch /out/sqlcmd /usr/local/bin/sqlcmd
COPY --from=fetch /out/NOTICE.md /usr/share/doc/sqlcmd/NOTICE.md

# The base is already non-root (uid 65532); restated so scanners and humans
# can verify it without inspecting the base image.
USER 65532:65532
WORKDIR /home/nonroot

ENTRYPOINT ["/usr/local/bin/sqlcmd"]
CMD ["--help"]
