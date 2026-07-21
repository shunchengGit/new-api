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
expected_revision=${EXPECTED_REVISION:-${VCS_REF:-}}
[ -n "$expected_version" ] || fail "set EXPECTED_VERSION or APP_VERSION"
case $expected_theme in default|classic) ;; *) fail "set EXPECTED_THEME or THEME to default or classic" ;; esac
case $expected_revision in ''|*[!0-9A-Fa-f]* ) [ -z "$expected_revision" ] || fail "EXPECTED_REVISION must be a 40-character hexadecimal revision" ;; esac
if [ -n "$expected_revision" ] && [ "${#expected_revision}" -ne 40 ]; then
  fail "EXPECTED_REVISION must be a 40-character hexadecimal revision"
fi

verify_host_header=${VERIFY_HOST_HEADER:-}
case $verify_host_header in *[!A-Za-z0-9.-]*|.*|*..*|*.) [ -z "$verify_host_header" ] || fail "invalid VERIFY_HOST_HEADER" ;; esac

curl_request() {
  if [ -n "$verify_host_header" ]; then
    curl -H "Host: $verify_host_header" "$@"
  else
    curl "$@"
  fi
}

tmp=${TMPDIR:-/tmp}/split-verify-$$
trap 'rm -f "$tmp.build" "$tmp.build.headers" "$tmp.status" "$tmp.spa" "$tmp.spa.headers"' EXIT HUP INT TERM
curl_request --fail --silent --show-error --dump-header "$tmp.build.headers" "$base/build-info.json" -o "$tmp.build" || fail "cannot fetch $base/build-info.json"
curl_request --fail --silent --show-error "$base/api/status" -o "$tmp.status" || fail "cannot fetch $base/api/status"
curl_request --fail --silent --show-error --dump-header "$tmp.spa.headers" "$base/dashboard" -o "$tmp.spa" || fail "cannot fetch SPA route $base/dashboard"
missing_status=$(curl_request --silent --show-error --output /dev/null --write-out '%{http_code}' "$base/assets/missing.js" || true)
[ "$missing_status" = 404 ] || fail "missing fingerprinted asset returned HTTP $missing_status instead of 404"

python3 - "$tmp.build" "$tmp.status" "$tmp.spa" "$tmp.build.headers" "$tmp.spa.headers" "$expected_version" "$expected_theme" "$expected_revision" <<'PY'
import json, os, re, sys
(
    build_path,
    status_path,
    spa_path,
    build_headers_path,
    spa_headers_path,
    expected_version,
    expected_theme,
    expected_revision,
) = sys.argv[1:]


def read_json(path):
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


def require_mutable_cache(path, label):
    with open(path, encoding="iso-8859-1") as handle:
        headers = handle.read()
    values = re.findall(r"(?im)^cache-control:\s*([^\r\n]+)", headers)
    if not values or not any("no-store" in value.lower() or "no-cache" in value.lower() for value in values):
        raise SystemExit(f"verify-deployment: {label} must use no-store or no-cache semantics")


build = read_json(build_path)
status_envelope = read_json(status_path)
if status_envelope.get("success") is not True or not isinstance(status_envelope.get("data"), dict):
    raise SystemExit("verify-deployment: /api/status is not a successful API response")
status = status_envelope["data"]

if build.get("schema") != 1:
    raise SystemExit("verify-deployment: unsupported or missing build-info schema")
revision = scalar(build, "revision", "build-info revision")
if not re.fullmatch(r"[0-9A-Fa-f]{40}", revision):
    raise SystemExit("verify-deployment: build-info revision must be a 40-character hexadecimal value")
if expected_revision and revision.lower() != expected_revision.lower():
    raise SystemExit(
        f"verify-deployment: frontend revision is {revision!r}, expected {expected_revision!r}"
    )

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

require_mutable_cache(build_headers_path, "build-info.json")
require_mutable_cache(spa_headers_path, "SPA entry")

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
print("verify-deployment: frontend/backend identity, SPA/API ownership, missing assets, and mutable cache policy agree")
PY
