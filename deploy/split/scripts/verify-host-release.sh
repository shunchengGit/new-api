#!/bin/sh
set -eu

fail() { printf '%s\n' "verify-host-release: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "requires $1"; }
need cmp
need python3

artifact_root=${ARTIFACT_ROOT:?ARTIFACT_ROOT is required}
release_root=${RELEASE_ROOT:?RELEASE_ROOT is required}
host_nginx_config=${HOST_NGINX_CONFIG:?HOST_NGINX_CONFIG is required}
host_nginx_binding_file=${HOST_NGINX_BINDING_FILE:?HOST_NGINX_BINDING_FILE is required}
nginx_test_command=${NGINX_TEST_COMMAND:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ ! -L "$release_root" ] || fail "release root must not be a symbolic link: $release_root"
[ -d "$release_root" ] || fail "missing release root: $release_root"
[ -f "$release_root/index.html" ] || fail "missing release index: $release_root/index.html"
[ -f "$release_root/build-info.json" ] || fail "missing release build metadata: $release_root/build-info.json"
[ ! -L "$host_nginx_config" ] || fail "host Nginx configuration must not be a symbolic link: $host_nginx_config"
[ -f "$host_nginx_config" ] || fail "missing host Nginx configuration: $host_nginx_config"
[ ! -L "$host_nginx_binding_file" ] || fail "host Nginx binding include must not be a symbolic link: $host_nginx_binding_file"
[ -f "$host_nginx_binding_file" ] || fail "missing host Nginx binding include: $host_nginx_binding_file"
grep -F "include $host_nginx_binding_file;" "$host_nginx_config" >/dev/null || \
  fail "host Nginx configuration does not include the binding file"

"$script_dir/verify-artifact.sh" "$artifact_root"
"$script_dir/verify-release.sh" "$release_root"
cmp -s "$artifact_root/site/build-info.json" "$release_root/build-info.json" || \
  fail "rendered release build metadata does not match the verified artifact"

nginx_dump=$(mktemp "${TMPDIR:-/tmp}/verify-host-nginx.XXXXXX")
cleanup_nginx_dump() { rm -f "$nginx_dump"; }
trap cleanup_nginx_dump EXIT HUP INT TERM
if [ -n "$nginx_test_command" ]; then
  case $nginx_test_command in /*) ;; *) fail "NGINX_TEST_COMMAND must be an absolute executable path" ;; esac
  [ -x "$nginx_test_command" ] || fail "NGINX_TEST_COMMAND is not executable: $nginx_test_command"
  "$nginx_test_command" "$host_nginx_config" > "$nginx_dump" 2>&1 || {
    sed -n '1,120p' "$nginx_dump" >&2
    fail "Nginx configuration expansion failed"
  }
else
  need nginx
  nginx -T -c "$host_nginx_config" > "$nginx_dump" 2>&1 || {
    sed -n '1,120p' "$nginx_dump" >&2
    fail "Nginx configuration expansion failed"
  }
fi
grep -F "# configuration file $host_nginx_binding_file:" "$nginx_dump" >/dev/null || \
  fail "Nginx expansion did not load the binding file"

expected_version=${EXPECTED_VERSION:-${APP_VERSION:-}}
expected_theme=${EXPECTED_THEME:-${THEME:-}}
expected_revision=${EXPECTED_REVISION:-${VCS_REF:-}}
[ -n "$expected_version" ] || fail "set EXPECTED_VERSION or APP_VERSION"
[ -n "$expected_theme" ] || fail "set EXPECTED_THEME or THEME"
[ -n "$expected_revision" ] || fail "set EXPECTED_REVISION or VCS_REF"

candidate_url=${CANDIDATE_URL:?CANDIDATE_URL is required and must target the running candidate Nginx listener}
public_host=${PUBLIC_HOST:?PUBLIC_HOST is required}
deployment_challenge=${DEPLOYMENT_CHALLENGE:?DEPLOYMENT_CHALLENGE is required}
case $candidate_url in http://*|https://*) ;; *) fail "CANDIDATE_URL must use http or https" ;; esac
case $public_host in *[!A-Za-z0-9.-]*|''|.*|*..*|*.) fail "invalid PUBLIC_HOST" ;; esac
case $deployment_challenge in *[!0-9A-Fa-f]*|'') fail "DEPLOYMENT_CHALLENGE must be 64 hexadecimal characters" ;; esac
[ "${#deployment_challenge}" -eq 64 ] || fail "DEPLOYMENT_CHALLENGE must be 64 hexadecimal characters"
grep -F "return 200 \"$deployment_challenge\\n\";" "$host_nginx_binding_file" >/dev/null || \
  fail "host Nginx binding include does not contain the deployment challenge"
grep -F "return 200 \"$deployment_challenge\\n\";" "$nginx_dump" >/dev/null || \
  fail "Nginx expansion does not contain the deployment challenge"
challenge_response=$(curl --fail --silent --show-error -H "Host: $public_host" "$candidate_url/.__new_api_candidate") || \
  fail "candidate Nginx challenge endpoint is unavailable"
[ "$challenge_response" = "$deployment_challenge" ] || fail "candidate listener is not running the verified host Nginx configuration"

PUBLIC_URL=$candidate_url \
VERIFY_HOST_HEADER=$public_host \
EXPECTED_VERSION=$expected_version \
EXPECTED_THEME=$expected_theme \
EXPECTED_REVISION=$expected_revision \
ACKNOWLEDGE_LINUXDO_OAUTH_INCOMPATIBILITY=${ACKNOWLEDGE_LINUXDO_OAUTH_INCOMPATIBILITY:-false} \
  "$script_dir/verify-deployment.sh"

printf '%s\n' 'verify-host-release: artifact, exact release provenance, Nginx syntax, and candidate deployment checks passed'
