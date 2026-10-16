FROM ubuntu:26.04

# Base tooling that GitHub Actions steps commonly expect in a job container
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        dirmngr \
        git \
        gpg \
        gzip \
        jq \
        libffi-dev \
        libicu78 \
        make \
        openssh-client \
        sudo \
        tar \
        unzip \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

# Install uv / uvx from the official Astral image
COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /uvx /bin/

# Install Python as the system Python via uv.
# Interpreters go to a world-readable dir (not /root) and the python/python3
# executables to /usr/local/bin; both env vars stay set so uv finds them at runtime.
ARG PYTHON_VERSION=3.15
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_PYTHON_BIN_DIR=/usr/local/bin
RUN uv python install "${PYTHON_VERSION}" --default \
    && chmod -R a+rX "${UV_PYTHON_INSTALL_DIR}" \
    && python --version

# Install AWS SAM CLI (pinned), arch-matched
ARG SAM_CLI_VERSION=1.169.0
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

# Install .NET SDKs 10 and 11 (pinned), side by side, using dotnetup into a system-wide root
ARG DOTNET_10_SDK_VERSION=10.0.402
ARG DOTNET_11_SDK_VERSION=11.0.100-rc.2.26504.105
ENV DOTNET_ROOT=/usr/local/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1
RUN curl -fsSL https://aka.ms/dotnetup/get-dotnetup.sh | bash \
    && ~/.dotnetup/dotnetup install "${DOTNET_10_SDK_VERSION}" "${DOTNET_11_SDK_VERSION}" \
        --install-path "${DOTNET_ROOT}" --interactive false --no-progress \
    && rm -rf ~/.dotnetup \
    && chmod -R a+rX "${DOTNET_ROOT}" \
    && ln -sf "${DOTNET_ROOT}/dotnet" /usr/bin/dotnet \
    && dotnet --list-sdks

# Install SonarScanner for .NET (pinned) as a dotnet tool in a world-readable dir on PATH,
# so `dotnet sonarscanner` works for any user without `dotnet tool install` in the job
ARG DOTNET_SONARSCANNER_VERSION=11.3.0
ENV DOTNET_TOOLS_DIR=/opt/dotnet-tools
ENV PATH="${DOTNET_TOOLS_DIR}:${PATH}"
RUN dotnet tool install dotnet-sonarscanner --version "${DOTNET_SONARSCANNER_VERSION}" --tool-path "${DOTNET_TOOLS_DIR}" \
    && chmod -R a+rX "${DOTNET_TOOLS_DIR}" \
    && (dotnet sonarscanner 2>&1 || true) | grep -q "SonarScanner for .NET"
