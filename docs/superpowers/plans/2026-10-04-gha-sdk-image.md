# GHA SDK Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish `ghcr.io/mb-dot-dev/gha-sdk-images`, an Ubuntu 24.04 job-container image with uv/uvx, AWS SAM CLI and .NET 10 + 11 preinstalled.

**Architecture:** One `Dockerfile` (ported from the Gitea runner image, base swapped to `ubuntu:24.04`), one shared smoke-test script used both locally and in CI, and one GitHub Actions workflow that smoke-tests an amd64 build, then builds `linux/amd64,linux/arm64` and pushes to GHCR (push only outside pull requests).

**Tech Stack:** Docker / Buildx / QEMU, GitHub Actions (`docker/*` actions), GHCR, bash.

**Spec:** `docs/superpowers/specs/2026-10-04-gha-sdk-image-design.md`

## Global Constraints

- Base image: `ubuntu:24.04` (official). Not catthehacker.
- Image name: `ghcr.io/mb-dot-dev/gha-sdk-images`.
- Usage: job container only; no runner agent in the image. Image runs as root.
- Platforms: `linux/amd64`, `linux/arm64`.
- apt packages: `git`, `curl`, `ca-certificates`, `unzip`, `jq`, `libicu74`, `sudo`, `tar`, `gzip`, `xz-utils`, `openssh-client` (no recommends, apt lists cleaned).
- uv/uvx: `COPY --from=ghcr.io/astral-sh/uv:0.12.22 /uv /uvx /bin/`.
- Python 3.14 as system Python: `ARG PYTHON_VERSION=3.14`, `uv python install "${PYTHON_VERSION}" --default`, with `UV_PYTHON_INSTALL_DIR=/opt/uv/python` and `UV_PYTHON_BIN_DIR=/usr/local/bin` set as image `ENV` (so `python`, `python3` resolve to `/usr/local/bin` and non-root users can read the interpreter).
- AWS SAM CLI `1.166.2`; zip chosen by `dpkg --print-architecture` (amd64 -> x86_64, arm64 -> arm64).
- .NET SDKs `10.0.401` and `11.0.100-rc.1.26425.128` side by side in `/usr/share/dotnet`; `DOTNET_ROOT=/usr/share/dotnet`, `DOTNET_CLI_TELEMETRY_OPTOUT=1`, `DOTNET_NOLOGO=1`; symlink `/usr/bin/dotnet`.
- Workflow triggers: push to `main`, tags `v*`, `workflow_dispatch`, `pull_request` (build and test only, no push).
- Workflow permissions: `contents: read`, `packages: write`.
- Tags: `latest` on main, `sha-<short>`, semver from `v*` tags. OCI source label links the package to the repo.
- Smoke test runs `dotnet --list-sdks`, `sam --version`, `uv --version`, `python --version`, `git --version` and blocks the push on failure.

## Review Focus

- arm64 build breaks (SAM zip name, .NET install under QEMU): the workflow builds both platforms on every run, including PRs, so a broken arm64 build fails the PR (Task 2).
- Only one .NET SDK ends up installed (second install overwrites the first): the smoke test asserts both `10.` and `11.` appear in `dotnet --list-sdks` (Task 1).
- `uvx` missing even though `uv` works: smoke test checks both (Task 1).
- Fork PRs have no `packages: write`: login and push are skipped for `pull_request`, so they still build and test (Task 2).
- Python installed under `/root` and unusable by a non-root user (job containers can run with `--user`): the Python lives in `/opt/uv/python`, and the smoke test runs a second time as `nobody` to prove `python` works without root (Task 1).
- `python`/`python3` missing or resolving to something other than uv's 3.14 (`--default` not taking effect): the smoke test asserts `python --version`, `python3 --version` and the path of `python` (Task 1).
- Interactive apt prompt hangs the build (tzdata etc.): `DEBIAN_FRONTEND=noninteractive` is set for the apt layer, so the build fails fast instead of hanging (Task 1).

Known gap: the smoke test runs on amd64 only; the arm64 image is built but not executed.

---

### Task 1: Dockerfile and smoke test

**Files:**
- Create: `scripts/smoke-test.sh`
- Create: `Dockerfile`

**Interfaces:**
- Produces: `scripts/smoke-test.sh`, run inside the image as `bash /scripts/smoke-test.sh` (mount `./scripts` at `/scripts`); exits non-zero on any failure. Task 2 calls it exactly like this.
- Produces: `Dockerfile` at the repo root, buildable with no build context requirements and no required build args.

- [ ] **Step 1: Create a feature branch and commit the docs**

```bash
cd /Users/bence/repos/github.com/mb-dot-dev/gha-sdk-images
git switch -c initial-image
git add docs
git commit -m "docs: add GHA SDK image spec and plan"
```

- [ ] **Step 2: Write the smoke test (the failing test)**

Create `scripts/smoke-test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

sdks="$(dotnet --list-sdks)"
echo "${sdks}"
grep -q '^10\.' <<<"${sdks}" || { echo "missing .NET 10 SDK" >&2; exit 1; }
grep -q '^11\.' <<<"${sdks}" || { echo "missing .NET 11 SDK" >&2; exit 1; }

sam --version
uv --version
uvx --version
git --version
jq --version

# uv-managed Python is the system Python
[[ "$(command -v python)" == /usr/local/bin/python ]] || { echo "python is not /usr/local/bin/python" >&2; exit 1; }
[[ "$(python --version)" == "Python 3.14."* ]] || { echo "python is not 3.14" >&2; exit 1; }
[[ "$(python3 --version)" == "Python 3.14."* ]] || { echo "python3 is not 3.14" >&2; exit 1; }
python -c 'import ssl, sqlite3, zlib'
```

- [ ] **Step 3: Run it against the bare base image to verify it fails**

Run: `docker run --rm -v "$PWD/scripts:/scripts:ro" ubuntu:24.04 bash /scripts/smoke-test.sh`
Expected: FAIL with `dotnet: command not found` (exit code 127).

- [ ] **Step 4: Write the Dockerfile**

Create `Dockerfile`:

```dockerfile
FROM ubuntu:24.04

# Base tooling that GitHub Actions steps commonly expect in a job container
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gzip \
        jq \
        openssh-client \
        sudo \
        tar \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install uv / uvx from the official Astral image
COPY --from=ghcr.io/astral-sh/uv:0.12.22 /uv /uvx /bin/

# Install Python as the system Python via uv.
# Interpreters go to a world-readable dir (not /root) and the python/python3
# executables to /usr/local/bin; both env vars stay set so uv finds them at runtime.
ARG PYTHON_VERSION=3.14
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_PYTHON_BIN_DIR=/usr/local/bin
RUN uv python install "${PYTHON_VERSION}" --default \
    && chmod -R a+rX "${UV_PYTHON_INSTALL_DIR}" \
    && python --version

# Install AWS SAM CLI (pinned), arch-matched
ARG SAM_CLI_VERSION=1.166.2
RUN case "$(dpkg --print-architecture)" in \
        amd64) sam_arch=x86_64 ;; \
        arm64) sam_arch=arm64 ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/aws/aws-sam-cli/releases/download/v${SAM_CLI_VERSION}/aws-sam-cli-linux-${sam_arch}.zip" -o /tmp/sam.zip \
    && unzip -q /tmp/sam.zip -d /tmp/sam-installation \
    && /tmp/sam-installation/install \
    && rm -rf /tmp/sam.zip /tmp/sam-installation \
    && sam --version

# Install .NET SDKs 10 and 11 (pinned), side by side
ARG DOTNET_10_SDK_VERSION=10.0.401
ARG DOTNET_11_SDK_VERSION=11.0.100-rc.1.26425.128
ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --version "${DOTNET_10_SDK_VERSION}" --install-dir "${DOTNET_ROOT}" \
    && /tmp/dotnet-install.sh --version "${DOTNET_11_SDK_VERSION}" --install-dir "${DOTNET_ROOT}" \
    && rm /tmp/dotnet-install.sh \
    && ln -sf "${DOTNET_ROOT}/dotnet" /usr/bin/dotnet \
    && dotnet --list-sdks
```

- [ ] **Step 5: Build the image locally**

Run: `docker build -t gha-sdk-images:local .`
Expected: build succeeds; the build log shows the `sam --version` output and a `dotnet --list-sdks` listing with both `10.0.401` and `11.0.100-rc.1...`.

- [ ] **Step 6: Run the smoke test against the built image**

Run: `docker run --rm -v "$PWD/scripts:/scripts:ro" gha-sdk-images:local bash /scripts/smoke-test.sh`
Expected: PASS (exit 0), printing both SDK versions and the sam, uv, uvx, git and jq versions.

If the `python` assertions fail (for example `--default` needs `--preview` in the pinned uv version, or the executables land somewhere else), fix the Dockerfile `RUN uv python install` step; do not loosen the smoke test.

Then run it again as a non-root user:

Run: `docker run --rm --user nobody -v "$PWD/scripts:/scripts:ro" gha-sdk-images:local bash /scripts/smoke-test.sh`
Expected: PASS. A failure here means the Python install isn't readable or runnable by non-root users.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile scripts/smoke-test.sh
git commit -m "feat: add Ubuntu 24.04 SDK image and smoke test"
```

---

### Task 2: Build and publish workflow

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `Dockerfile` (repo root) and `scripts/smoke-test.sh` run as `bash /scripts/smoke-test.sh` with `./scripts` mounted at `/scripts` (from Task 1).
- Produces: image `ghcr.io/mb-dot-dev/gha-sdk-images` with tags per Global Constraints.

Before writing, check the current major versions of the actions below (`actions/checkout`, `docker/setup-qemu-action`, `docker/setup-buildx-action`, `docker/login-action`, `docker/metadata-action`, `docker/build-push-action`) and use the latest majors if newer than the ones shown.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/build.yml`:

```yaml
name: Build and publish image

on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read
  packages: write

env:
  IMAGE: ghcr.io/mb-dot-dev/gha-sdk-images

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-qemu-action@v3

      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Image metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.IMAGE }}
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=sha,prefix=sha-
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
          labels: |
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}

      - name: Build amd64 image for smoke test
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          load: true
          tags: smoke:test
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Smoke test
        run: docker run --rm -v "$PWD/scripts:/scripts:ro" smoke:test bash /scripts/smoke-test.sh

      - name: Build and push (amd64 + arm64)
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Lint the workflow**

Run: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color`
Expected: no output, exit 0. Fix anything it reports.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build, smoke-test and publish image to GHCR"
```

---

### Task 3: README and first real CI run

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: workflow and image name from Task 2.

- [ ] **Step 1: Write the README**

Replace `README.md` with:

````markdown
# gha-sdk-images

Container image with preinstalled SDKs for use as a GitHub Actions job container.

Image: `ghcr.io/mb-dot-dev/gha-sdk-images`

## Contents

- Ubuntu 24.04, with git, curl, jq, unzip, sudo and other common tools
- uv / uvx
- Python 3.14 as the system Python (`python`, `python3`), installed with uv
- AWS SAM CLI
- .NET SDK 10 and 11 (side by side)

Exact versions are pinned in the [`Dockerfile`](Dockerfile). Platforms: `linux/amd64`, `linux/arm64`.

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    container: ghcr.io/mb-dot-dev/gha-sdk-images:latest
    steps:
      - uses: actions/checkout@v4
      - run: dotnet --list-sdks
```

## Tags

- `latest`: current `main`
- `sha-<short>`: a specific commit
- `<version>`, `<major>.<minor>`: from `v*` git tags

The image is rebuilt on every push to `main`, on `v*` tags, and on manual dispatch. Layers are cached, so to pick up new base image, apt or Python patch releases, bump a pinned `ARG` in the `Dockerfile` or clear the Actions cache.
Pull requests build and test the image without pushing.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: describe image contents and usage"
```

- [ ] **Step 3: Push the branch and open a PR (ask the user first; this publishes to GitHub)**

```bash
git push -u origin initial-image
gh pr create --fill
```

- [ ] **Step 4: Verify the PR run**

Run: `gh pr checks --watch`
Expected: the `build` job passes: smoke test passes and both platforms build, with no push (no GHCR login step ran).

- [ ] **Step 5: Merge and verify the publish run (ask the user first)**

Merge the PR, then run `gh run watch` on the `main` run.
Expected: the job passes and pushes `latest` and `sha-<short>` to GHCR.

- [ ] **Step 6: Verify the published image**

Run: `docker pull ghcr.io/mb-dot-dev/gha-sdk-images:latest` and `docker run --rm -v "$PWD/scripts:/scripts:ro" ghcr.io/mb-dot-dev/gha-sdk-images:latest bash /scripts/smoke-test.sh`
Expected: pull succeeds (after `docker login ghcr.io` while the package is private) and the smoke test passes.

- [ ] **Step 7: Make the package public (manual, user only)**

In GitHub: Packages -> `gha-sdk-images` -> Package settings -> Change visibility -> Public. Also confirm the package is linked to the repo (the OCI source label should do this automatically).
