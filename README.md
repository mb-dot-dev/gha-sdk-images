# gha-sdk-images

Container image with preinstalled SDKs for use as a GitHub Actions job container.

Image: `ghcr.io/mb-dot-dev/gha-sdk-images`

## Contents

- Ubuntu 26.04, with git, curl, jq, unzip, sudo and other common tools
- uv / uvx
- Python 3.15 as the system Python (`python`, `python3`), installed with uv
- AWS SAM CLI
- AWS CLI v2
- Bun (canary build, needed for `bun lint`)
- .NET SDK 10 and 11 (side by side)
- SonarScanner for .NET (`dotnet sonarscanner`)

Exact versions are pinned in the [`Dockerfile`](Dockerfile), except Bun, which tracks the latest canary build at image build time. Platforms: `linux/amd64`, `linux/arm64`.

Note: without a `global.json`, `dotnet` uses the highest installed SDK, which is the .NET 11 release candidate.
Add a `global.json` (or use `actions/setup-dotnet`) to select .NET 10.

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    container: ghcr.io/mb-dot-dev/gha-sdk-images:latest
    steps:
      - uses: actions/checkout@v7
      - run: dotnet --list-sdks
```

## Tags

- `latest`: current `main`
- `sha-<short>`: a specific commit
- `<version>`, `<major>.<minor>`: from `v*` git tags

The image is rebuilt on every push to `main`, on `v*` tags, and on manual dispatch. Layers are cached, so to pick up new base image, apt or Python patch releases, bump a pinned `ARG` in the `Dockerfile` or clear the Actions cache (this also refreshes the Bun canary).
Pull requests build and test the image without pushing.
