#!/bin/sh
set -eu

fail() { printf '%s\n' "verify-deployment: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "requires $1"; }
need curl
need python3

if [ -n "${PUBLIC_URL:-}" ]; then
  base=${PUBLIC_URL%/}
else
  scheme=${PUBLIC_SCHEME:-https}
  host=${PUBLIC_HOST:-}
  port=${PUBLIC_PORT:-}
  [ -n "$host" ] || fail "set PUBLIC_URL or PUBLIC_HOST"
  base="$scheme://$host"
  case "$scheme:$port" in http:|http:80|https:|https:443) ;; *:) ;; *) base="$base:$port" ;; esac
fi

expected_version=${EXPECTED_VERSION:-${APP_VERSION:-}}
expected_theme=${EXPECTED_THEME:-${THEME:-}}
[ -n "$expected_version" ] || fail "set EXPECTED_VERSION or APP_VERSION"
case $expected_theme in default|classic) ;; *) fail "set EXPECTED_THEME or THEME to default or classic" ;; esac

tmp=${TMPDIR:-/tmp}/split-verify-$$
trap 'rm -f "$tmp.build" "$tmp.status" "$tmp.spa"' EXIT HUP INT TERM
curl --fail --silent --show-error "$base/build-info.json" -o "$tmp.build" || fail "cannot fetch $base/build-info.json"
curl --fail --silent --show-error "$base/api/status" -o "$tmp.status" || fail "cannot fetch $base/api/status"
curl --fail --silent --show-error "$base/dashboard" -o "$tmp.spa" || fail "cannot fetch SPA route $base/dashboard"

python3 - "$tmp.build" "$tmp.status" "$tmp.spa" "$expected_version" "$expected_theme" <<'PY'
import json, os, sys
build_path, status_path, spa_path, expected_version, expected_theme = sys.argv[1:]

def read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"verify-deployment: invalid JSON in {path}: {error}")

def scalar(document, name, label):
    value = document.get(name)
    if not isinstance(value, (str, int, float)) or isinstance(value, bool):
        raise SystemExit(f"verify-deployment: {label} is missing or invalid")
    return str(value)

build = read(build_path)
status_envelope = read(status_path)
if status_envelope.get("success") is not True or not isinstance(status_envelope.get("data"), dict):
    raise SystemExit("verify-deployment: /api/status is not a successful API response")
status = status_envelope["data"]

values = (
    ("frontend version", scalar(build, "version", "build-info version"), expected_version),
    ("backend version", scalar(status, "version", "backend version"), expected_version),
    ("frontend theme", scalar(build, "theme", "build-info theme"), expected_theme),
    ("backend theme", scalar(status, "theme", "backend theme"), expected_theme),
)
for label, actual, expected in values:
    if actual != expected:
        raise SystemExit(f"verify-deployment: {label} is {actual!r}, expected {expected!r}")

with open(spa_path, encoding="utf-8", errors="replace") as handle:
    spa = handle.read(4096).lower()
if "<html" not in spa and "<!doctype html" not in spa:
    raise SystemExit("verify-deployment: /dashboard did not return the frontend SPA")

if status.get("linuxdo_oauth") is True:
    if os.environ.get("ACKNOWLEDGE_LINUXDO_OAUTH_INCOMPATIBILITY") != "true":
        raise SystemExit(
            "verify-deployment: LinuxDO OAuth is enabled. Its current callback URI handling may break "
            "LinuxDO login, registration, and account binding behind TLS-terminating Nginx. Disable it, "
            "apply the separate upstream correction, or explicitly set "
            "ACKNOWLEDGE_LINUXDO_OAUTH_INCOMPATIBILITY=true after accepting the impact."
        )
    print(
        "verify-deployment: WARNING: LinuxDO incompatibility acknowledged; acknowledgement does not repair login, registration, or binding.",
        file=sys.stderr,
    )
print("verify-deployment: frontend/backend version, theme, SPA, and API status agree")
PY
