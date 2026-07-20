#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
split=$(CDPATH= cd -- "$here/.." && pwd)

skip() { printf '%s\n' "route-contract: SKIP: $*"; exit 0; }
fail() { printf '%s\n' "route-contract: FAIL: $*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || skip "Docker is unavailable"
docker info >/dev/null 2>&1 || skip "Docker daemon is unavailable"
command -v curl >/dev/null 2>&1 || fail "requires curl"
command -v python3 >/dev/null 2>&1 || fail "requires python3"

for file in nginx/nginx.conf.template nginx/backend-proxy.inc.template nginx/real-ip.conf.template scripts/render-index.sh tests/marker-backend.py; do
  [ -f "$split/$file" ] || fail "missing $split/$file"
done

grep -F 'proxy_cache off;' "$split/nginx/backend-proxy.inc.template" >/dev/null || fail "backend proxy caching must be disabled"
grep -F 'proxy_buffering off;' "$split/nginx/backend-proxy.inc.template" >/dev/null || fail "backend response buffering must be disabled"
grep -F 'proxy_request_buffering off;' "$split/nginx/backend-proxy.inc.template" >/dev/null || fail "backend request buffering must be disabled"
if grep -F 'X-Forwarded-For $http_x_forwarded_for' "$split/nginx/backend-proxy.inc.template" >/dev/null; then
  fail "client-supplied X-Forwarded-For must not be forwarded"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/split-route-contract.XXXXXX")
network="split-contract-$$"
marker="split-marker-$$"
nginx="split-nginx-$$"
cleanup() {
  docker rm -f "$nginx" "$marker" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$work/source/assets" "$work/source/static" "$work/runtime" "$work/config"
printf '%s\n' '<!doctype html><html><head><!--umami--><!--Google Analytics--></head><body>split fixture</body></html>' > "$work/source/index.html"
printf '%s\n' 'fixture' > "$work/source/assets/app.123.js"
printf '%s\n' 'fixture' > "$work/source/static/app.123.js"
printf '%s\n' '{"version":"contract","theme":"default"}' > "$work/source/build-info.json"

env SOURCE_ROOT="$work/source" RUNTIME_ROOT="$work/runtime" NGINX_CONFIG_DIR="$work/config" \
  NGINX_TEMPLATE_DIR="$split/nginx" PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https \
  BACKEND_SERVICE="$marker:8080" CLIENT_MAX_BODY_SIZE=2m LISTEN_PORT=8080 \
  UMAMI_WEBSITE_ID=test-site UMAMI_SCRIPT_URL=https://analytics.example/script.js \
  GOOGLE_ANALYTICS_ID=G-TEST123 \
  "$split/scripts/render-index.sh" true

grep -F 'analytics.example/script.js' "$work/runtime/index.html" >/dev/null || fail "Umami injection missing"
grep -F 'G-TEST123' "$work/runtime/index.html" >/dev/null || fail "Google Analytics injection missing"

env SOURCE_ROOT="$work/source" RUNTIME_ROOT="$work/runtime-unset" NGINX_CONFIG_DIR="$work/config-unset" \
  NGINX_TEMPLATE_DIR="$split/nginx" PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https \
  BACKEND_SERVICE="$marker:8080" CLIENT_MAX_BODY_SIZE=2m LISTEN_PORT=8080 \
  "$split/scripts/render-index.sh" true
if grep -F '<script' "$work/runtime-unset/index.html" >/dev/null; then
  fail "analytics scripts must be absent when analytics is unset"
fi

docker network create "$network" >/dev/null
docker run -d --name "$marker" --network "$network" \
  -v "$split/tests/marker-backend.py:/marker.py:ro" \
  python:3.12-alpine python3 /marker.py 8080 >/dev/null

docker run --rm --network "$network" \
  -v "$work/config:/config:ro" \
  -v "$work/runtime:/usr/share/nginx/html:ro" \
  --tmpfs /tmp:rw,uid=101,gid=101 \
  nginxinc/nginx-unprivileged:1.27.5-alpine \
  sh -c 'mkdir -p /tmp/nginx/conf.d && cp /config/* /tmp/nginx/conf.d/ && nginx -c /tmp/nginx/conf.d/nginx.conf -t' >/dev/null

docker run -d --name "$nginx" --network "$network" -p 127.0.0.1::8080 \
  -v "$work/config:/config:ro" \
  -v "$work/runtime:/usr/share/nginx/html:ro" \
  --tmpfs /tmp:rw,uid=101,gid=101 \
  nginxinc/nginx-unprivileged:1.27.5-alpine \
  sh -c 'mkdir -p /tmp/nginx/conf.d && cp /config/* /tmp/nginx/conf.d/ && exec nginx -c /tmp/nginx/conf.d/nginx.conf -g "daemon off;"' >/dev/null

port=$(docker port "$nginx" 8080/tcp | python3 -c 'import sys; print(sys.stdin.read().strip().rsplit(":", 1)[1])')
base="http://127.0.0.1:$port"
request() { curl --silent --show-error --max-time 5 -H 'Host: contract.test' "$@"; }
status() { curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 -H 'Host: contract.test' "$@"; }
contains() { printf '%s' "$1" | grep -F "$2" >/dev/null || fail "expected $2 in response: $1"; }

body=$(request -X POST -H 'X-Signature: signed' --data 'payload' "$base/api/echo?x=1")
contains "$body" '"path": "/api/echo?x=1"'
contains "$body" '"body": "payload"'
contains "$body" '"signature": "signed"'
for path in v1/echo v1beta/echo pg/echo mj/echo suno/echo kling/v1/echo jimeng/echo; do
  contains "$(request "$base/$path?x=1")" "\"path\": \"/$path?x=1\""
done
contains "$(request "$base/dashboard/billing/usage")" '"path": "/dashboard/billing/usage"'
contains "$(request "$base/fast/mj/submit/imagine")" '"path": "/fast/mj/submit/imagine"'

for path in dashboard dashboard/overview dashboard/billing oauth/linuxdo user/reset anything/mj api-not-a-namespace; do
  [ "$(status "$base/$path")" = 200 ] || fail "/$path must remain SPA-owned"
done
[ "$(status "$base/anything/mj/echo")" = 200 ] || fail "unregistered mode-MJ action must remain SPA-owned"
[ "$(status "$base/assets/missing.js")" = 404 ] || fail "missing /assets files must return 404"
[ "$(status "$base/static/missing.js")" = 404 ] || fail "missing /static files must return 404"
for asset in assets/app.123.js static/app.123.js; do
  asset_headers=$(curl --silent --show-error --head -H 'Host: contract.test' "$base/$asset")
  printf '%s' "$asset_headers" | grep -Eqi '^Cache-Control:.*immutable' || fail "$asset needs immutable caching"
done
index_headers=$(curl --silent --show-error --head -H 'Host: contract.test' "$base/index.html")
printf '%s' "$index_headers" | grep -Eqi '^Cache-Control:.*no-(store|cache)' || fail "index must not be persistently cached"

xff=$(request -H 'X-Forwarded-For: forged' "$base/api/xff")
printf '%s' "$xff" | grep -F 'forged' >/dev/null && fail "forged X-Forwarded-For reached backend"
contains "$xff" '"xff": "'
unknown=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 -H 'Host: attacker.invalid' "$base/dashboard" || true)
case $unknown in 000|444) ;; *) fail "unknown Host was not rejected: $unknown" ;; esac

assert_sse_immediate() {
  path=$1
  output=$work/sse.out
  rm -f "$output"
  curl --silent --show-error -N --max-time 4 -H 'Host: contract.test' "$base$path" > "$output" &
  pid=$!
  found=false
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -F 'data: immediate' "$output" >/dev/null 2>&1; then found=true; break; fi
    sleep 0.1
  done
  [ "$found" = true ] || { kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; fail "$path first SSE event was buffered"; }
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}
assert_sse_immediate /v1/sse
assert_sse_immediate /api/sse
ws=$(curl --silent --show-error --include --max-time 2 --http1.1 \
  -H 'Host: contract.test' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Sec-WebSocket-Protocol: openai-realtime' "$base/v1/realtime" || true)
printf '%s' "$ws" | grep -F '101 Switching Protocols' >/dev/null || fail "WebSocket upgrade failed"
printf '%s' "$ws" | grep -Eqi '^Sec-WebSocket-Protocol: openai-realtime' || fail "WebSocket subprotocol missing"

python3 -c 'import sys; sys.stdout.write("x" * 1048576)' > "$work/upload.bin"
response=$(request -X POST --data-binary "@$work/upload.bin" "$base/api/upload")
contains "$response" '"path": "/api/upload"'
contains "$response" '"body_size": 1048576'

printf '%s\n' 'route-contract: PASS'
