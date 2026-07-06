<!-- ABOUTME: Documentation for the minimal, hardened MSSQL client Docker image:
     what it contains, how to build, run, test, and upgrade it. -->

# mssql-client

A minimal, hardened Docker image for connecting to SQL Server / Azure SQL,
built on Microsoft's statically linked [go-sqlcmd](https://github.com/microsoft/go-sqlcmd).

**~9 MB. No shell. No package manager. No libc. Non-root. Read-only-rootfs compatible.**

## Security properties

| Property | How |
|---|---|
| Minimal attack surface | `gcr.io/distroless/static-debian12` runtime: the image contains the `sqlcmd` binary, CA certificates, tzdata, and nothing else — no shell, no package manager, no coreutils |
| Non-root | Runs as `nonroot` (uid/gid 65532), stated explicitly in the Dockerfile |
| Supply-chain pinning | Both base images pinned by digest; the upstream release tarball is verified against a per-architecture SHA-256 before extraction |
| Verified at build time | The extracted binary must execute and report its version or the build fails |
| Encrypted by default | go-sqlcmd negotiates TLS with the server; use `-N strict` (TDS 8.0) where supported |
| Immutable runtime | Works under `docker run --read-only` (add `--tmpfs /home/nonroot` only if you use `sqlcmd config`) |
| License compliance | Upstream `NOTICE.md` shipped at `/usr/share/doc/sqlcmd/NOTICE.md` |

## Build

```sh
docker build -t mssql-client .

# multi-arch (amd64 + arm64):
docker buildx build --platform linux/amd64,linux/arm64 -t mssql-client .
```

## Usage

Pass the password via `SQLCMDPASSWORD` — never `-P` on the command line, where
it leaks into shell history and `docker inspect`:

```sh
# interactive session
docker run --rm -it --read-only -e SQLCMDPASSWORD \
  mssql-client -S myserver.example.com -U myuser

# one-shot query
docker run --rm --read-only -e SQLCMDPASSWORD \
  mssql-client -S myserver.example.com -U myuser -Q "SELECT @@VERSION"

# run a script from the host (mount read-only)
docker run --rm --read-only -e SQLCMDPASSWORD \
  -v "$PWD/migrate.sql:/sql/migrate.sql:ro" \
  mssql-client -S myserver.example.com -U myuser -i /sql/migrate.sql
```

Server certificate trust: the image trusts the standard public CA bundle. For
servers with private-CA or self-signed certificates, prefer mounting the CA
certificate and pointing sqlcmd at it; `-C` (trust server certificate)
disables verification and belongs in test environments only.

## Test

```sh
./test.sh                  # full suite: unit, integration, e2e
./test.sh unit             # hadolint only
./test.sh integration      # build + image structure/behavior checks
./test.sh e2e              # live queries against a real SQL Server container
```

The e2e stage starts `mcr.microsoft.com/mssql/server:2022-latest` (amd64; runs
under Rosetta/QEMU on arm64 hosts) with a random SA password and exercises the
client image against it, including with a read-only root filesystem.

## Upgrading sqlcmd

1. Pick the new tag from [go-sqlcmd releases](https://github.com/microsoft/go-sqlcmd/releases).
2. Download `sqlcmd-linux-amd64.tar.bz2` and `sqlcmd-linux-arm64.tar.bz2`,
   compute `sha256sum` for each (upstream publishes no checksum file).
3. Update `SQLCMD_VERSION`, `SQLCMD_SHA256_AMD64`, and `SQLCMD_SHA256_ARM64`
   in the Dockerfile, and the version assertion in `test.sh`.
4. `./test.sh`
