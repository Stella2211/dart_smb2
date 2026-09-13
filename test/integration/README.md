# dart_smb2 — integration tests

Spins up a real Samba 4 server in Docker and exercises the full `Smb2Client` + `Smb2Pool` API against it. Mirrors the pattern used by the other libraries (dart_jellyfin, dart_plex).

## Prerequisites

- **Docker Desktop** (or any Docker engine).
- **macOS / Linux** dev host. The bootstrap script picks the right native libsmb2 binary from the platform-specific bundle.
- **Native libsmb2 binary** present on disk. Run once after a fresh clone:
  ```bash
  cd ../../../libsmb2-scripts
  make checksums
  ```
  This pulls (or extracts) `libsmb2.framework` / `libsmb2.so` into the dart_smb2 platform folders.

## First-time setup

```bash
# From the dart_smb2 repo root:
cp test/integration/.env.test.example test/integration/.env.test
# (optional) edit .env.test to bump SMB2_HOST_PORT if 445 is taken.

dart run test/integration/bootstrap.dart
```

To run the suite on the dedicated non-default port used by the local Docker
SMB service, copy the 1445 profile and select it explicitly:

```bash
cp test/integration/.env.test.1445.example test/integration/.env.test.1445
SMB2_ENV_FILE=.env.test.1445 dart run test/integration/bootstrap.dart
```

When another test stack already owns the 1445 container, set
`SMB2_SKIP_DOCKER=1` and provide that server's credentials in the selected
environment file. The bootstrap still performs the real connection and seed
write, but leaves the running container untouched.

The bootstrap is idempotent — re-running it just re-checks the seed file. It:

1. Reads the selected environment file (`.env.test` by default).
2. Brings up the Samba container via `docker compose up -d --wait`.
3. Connects through `Smb2Pool` and drops a known 1 MiB seed file (`dart_smb2_seed.bin`) on the share.
4. Persists everything (`host`, `share`, `user`, `password`, `libPath`, `testFile`) to `.bootstrap-cache.json`.

## Running the tests

```bash
# Just the integration suite (serial, per dart_test.yaml preset):
dart test -P integration --tags integration

# Or everything:
dart test
```

If the bootstrap cache is missing, the integration groups skip with a clear message and `dart test` stays green.

## Port 445 conflict

The container binds `127.0.0.1:445` by default. macOS users who have **System Settings → General → Sharing → File Sharing** enabled will hit a conflict. Either turn File Sharing off temporarily or select `.env.test.1445`:

```env
SMB2_ENV_FILE=.env.test.1445
```

libsmb2 accepts the `host:port` form used by the bootstrap cache, so the
non-default profile exercises the same connection path as port 445.

## Teardown

```bash
# From test/integration/, with .env.test in place:
docker compose down            # stop container, keep ./volumes/share
docker compose down -v         # also wipe the share data
```

`volumes/share/` is the persistent storage backing the SMB share. Gitignored.

## What ships with the package

Nothing in `test/integration/` ships to pub.dev — the entire `test/` directory is excluded by `.pubignore`. Contributors clone the GitHub repo and run the steps above.
