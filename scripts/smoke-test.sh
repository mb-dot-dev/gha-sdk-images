#!/usr/bin/env bash
set -euo pipefail

sdks="$(dotnet --list-sdks)"
echo "${sdks}"
grep -q '^10\.' <<<"${sdks}" || { echo "missing .NET 10 SDK" >&2; exit 1; }
grep -q '^11\.' <<<"${sdks}" || { echo "missing .NET 11 SDK" >&2; exit 1; }

# --list-sdks only runs the native muxer; these start the runtime (needs ICU) and the compiler
dotnet --version
tmp="$(mktemp -d)"
dotnet new console -o "${tmp}/app" --no-restore >/dev/null
dotnet build "${tmp}/app" --nologo -v q
rm -rf "${tmp}"

# the scanner has no --version flag: it prints its banner and exits 1 without a command
sonar_out="$(dotnet sonarscanner 2>&1 || true)"
grep -q "SonarScanner for .NET" <<<"${sonar_out}" || { echo "dotnet sonarscanner not working" >&2; exit 1; }
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
