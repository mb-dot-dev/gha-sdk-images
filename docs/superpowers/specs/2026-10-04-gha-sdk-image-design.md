# GHA SDK image: design

## Goal
A container image with preinstalled SDKs for use as a GitHub Actions job container
(`container: ghcr.io/mb-dot-dev/gha-sdk-images:latest`), published to GHCR.
It mirrors the SDK set of the Gitea runner image (`gitea-action-runner/Dockerfile`).

## Decisions
- **Base:** `ubuntu:24.04` (official). Same OS as `ubuntu-latest`. Not catthehacker: that
  image targets `act`, and GitHub's runner mounts its own Node into job containers.
- **Image name:** `ghcr.io/mb-dot-dev/gha-sdk-images`.
- **Usage:** job container only (no runner agent in the image).
- **Platforms:** `linux/amd64`, `linux/arm64`.

## Image contents
Base packages via apt (no recommends, apt lists cleaned): `git`, `curl`, `ca-certificates`,
`unzip`, `jq`, `libicu74` (required by .NET), `sudo`, `tar`, `gzip`, `xz-utils`, `openssh-client`.
(`git` is needed so `actions/checkout` does a real clone; the rest are commonly expected by actions and scripts.)

SDKs, all pinned via `ARG`, same as the Gitea image:
- uv / uvx: `COPY --from=ghcr.io/astral-sh/uv:<version> /uv /uvx /bin/`
- Python 3.14 as the system Python, installed with `uv python install 3.14 --default`
  (`python`, `python3`, `python3.14` in `/usr/local/bin`). Interpreters live in a world-readable
  `UV_PYTHON_INSTALL_DIR=/opt/uv/python` (not under `/root`), and `UV_PYTHON_BIN_DIR=/usr/local/bin`.
  Both env vars stay set in the image so uv finds the install at runtime. The pin is the minor
  version (`3.14`), so the weekly rebuild picks up patch releases.
- AWS SAM CLI `1.166.2`, zip chosen by `dpkg --print-architecture` (amd64 -> x86_64, arm64 -> arm64)
- .NET SDK `10.0.401` and `11.0.100-rc.1.26425.128` side by side in `/usr/share/dotnet`,
  `DOTNET_ROOT`, `DOTNET_CLI_TELEMETRY_OPTOUT=1`, `DOTNET_NOLOGO=1`, symlink at `/usr/bin/dotnet`

The image runs as root (GitHub job containers expect this; the runner handles the workspace mount).

## Repo layout
```
Dockerfile
.github/workflows/build.yml
README.md
docs/superpowers/specs/...
```

## Build and publish workflow
- Triggers: push to `main`, tags `v*`, weekly schedule (base image updates), `workflow_dispatch`,
  and `pull_request` (build and test only, no push).
- Permissions: `contents: read`, `packages: write`.
- Steps: checkout, QEMU, Buildx, login to GHCR with `GITHUB_TOKEN` (skipped on PRs),
  `docker/metadata-action` (tags: `latest` on main, `sha-<short>`, semver from `v*` tags;
  OCI `source` label links the package to the repo), smoke test, `build-push-action`
  for both platforms with GHA cache.
- Smoke test: build the amd64 image locally into the Docker daemon and run
  `dotnet --list-sdks`, `sam --version`, `uv --version`, `git --version`.
  A failure blocks the push.

## Out of scope
- Runner-agent image, Dependabot/Renovate for pinned versions, Gitea parity beyond the SDK set.

## Notes
- The package is created private on first push. Making it public is a one-time manual step
  in the GitHub UI (Package settings).
- The .NET 11 SDK is a release candidate, carried over from the Gitea image.
