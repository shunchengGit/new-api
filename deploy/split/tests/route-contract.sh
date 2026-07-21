#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
split=$(CDPATH= cd -- "$here/.." && pwd)

fail() { printf '%s\n' "route-contract: FAIL: $*" >&2; exit 1; }
runtime_unavailable() {
  message=$1
  if [ "${REQUIRE_RUNTIME:-false}" = true ]; then
    fail "$message (REQUIRE_RUNTIME=true)"
  fi
  printf '%s\n' "route-contract: SKIP: $message"
  exit 0
}
command -v docker >/dev/null 2>&1 || runtime_unavailable "Docker is unavailable"
docker info >/dev/null 2>&1 || runtime_unavailable "Docker daemon is unavailable"
command -v curl >/dev/null 2>&1 || fail "requires curl"
command -v python3 >/dev/null 2>&1 || fail "requires python3"

for file in \
  nginx/nginx.conf.template \
  nginx/host-nginx.conf.template \
  nginx/route-contract.inc.template \
  nginx/backend-proxy.inc.template \
  nginx/real-ip.conf.template \
  scripts/generate-artifact-integrity.sh \
  scripts/render-release.sh \
  scripts/render-nginx.sh \
  scripts/render-host-nginx.sh \
  scripts/verify-artifact.sh \
  tests/marker-backend.py; do
  [ -f "$split/$file" ] || fail "missing $split/$file"
done

assert_contract_files() {
  contract=$1
  proxy=$2
  for required in \
    'location = /api {' \
    'location ^~ /api/ {' \
    'location = /v1 {' \
    'location ^~ /v1/ {' \
    'location = /v1beta {' \
    'location ^~ /v1beta/ {' \
    'location = /pg {' \
    'location ^~ /pg/ {' \
    'location = /mj {' \
    'location ^~ /mj/ {' \
    'location = /suno {' \
    'location ^~ /suno/ {' \
    'location = /kling {' \
    'location ^~ /kling/ {' \
    'location = /jimeng {' \
    'location ^~ /jimeng/ {' \
    'location ~ ^/(?:v1/)?dashboard/billing/(?:subscription|usage)/?$' \
    'location ~ ^/[^/]+/mj/(?:image|submit|task|insight-face)(?:/|$)' \
    'location ^~ /assets/' \
    'location ^~ /static/' \
    'try_files $uri $uri/ /index.html =404;'; do
    grep -F "$required" "$contract" >/dev/null || return 1
  done
  grep -F 'proxy_cache off;' "$proxy" >/dev/null || return 1
  grep -F 'proxy_buffering off;' "$proxy" >/dev/null || return 1
  grep -F 'proxy_request_buffering off;' "$proxy" >/dev/null || return 1
  grep -F 'proxy_set_header X-Forwarded-For $remote_addr;' "$proxy" >/dev/null || return 1
  ! grep -F 'X-Forwarded-For $http_x_forwarded_for' "$proxy" >/dev/null
}

assert_contract_files "$split/nginx/route-contract.inc.template" "$split/nginx/backend-proxy.inc.template" || fail "shared route contract is unsafe or incomplete"

tmpdir=${TMPDIR:-/tmp}
tmpdir=${tmpdir%/}
work=$(mktemp -d "$tmpdir/split-route-contract.XXXXXX")
chmod 0755 "$work"
network="split-contract-$$"
marker="split-marker-$$"
nginx_containers=""
cleanup() {
  [ -z "$nginx_containers" ] || docker rm -f $nginx_containers >/dev/null 2>&1 || true
  docker rm -f "$marker" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

assert_negative_drift() {
  cp "$split/nginx/route-contract.inc.template" "$work/broken-route-contract.inc"
  cp "$split/nginx/backend-proxy.inc.template" "$work/broken-backend-proxy.inc"
  python3 - "$work/broken-route-contract.inc" "$work/broken-backend-proxy.inc" <<'PY'
import pathlib
route = pathlib.Path(__import__('sys').argv[1])
proxy = pathlib.Path(__import__('sys').argv[2])
route.write_text(route.read_text().replace('location ^~ /api/ {', 'location ^~ /api-disabled/ {', 1), encoding='utf-8')
proxy.write_text(proxy.read_text().replace('proxy_buffering off;', 'proxy_buffering on;', 1), encoding='utf-8')
PY
  if assert_contract_files "$work/broken-route-contract.inc" "$split/nginx/backend-proxy.inc.template"; then
    fail "route contract drift was accepted"
  fi
  if assert_contract_files "$split/nginx/route-contract.inc.template" "$work/broken-backend-proxy.inc"; then
    fail "unsafe backend proxy drift was accepted"
  fi
}
assert_negative_drift

mkdir -p "$work/artifact/site/assets" "$work/artifact/site/static" "$work/artifact/licenses/frontend" "$work/container-runtime" "$work/container-config"
printf '%s\n' '<!doctype html><html><head><!--umami--><!--Google Analytics--></head><body>split fixture</body></html>' > "$work/artifact/site/index.html"
printf '%s\n' 'fixture' > "$work/artifact/site/assets/app.123.js"
printf '%s\n' 'fixture' > "$work/artifact/site/static/app.123.js"
printf '%s\n' 'frontend license' > "$work/artifact/licenses/frontend/LICENSE.txt"
printf '%s\n' 'license' > "$work/artifact/licenses/LICENSE"
printf '%s\n' 'notice' > "$work/artifact/licenses/NOTICE"
printf '%s\n' 'third-party' > "$work/artifact/licenses/THIRD-PARTY-LICENSES.md"
printf '%s\n' 'lockfile' > "$work/bun.lock"
printf '%s\n' 'real_ip_header X-Real-IP;' > "$work/host-real-ip.conf"
THEME=default APP_VERSION=contract VCS_REF=0123456789abcdef0123456789abcdef01234567 FRONTEND_LOCKFILE="$work/bun.lock" \
  "$split/scripts/generate-artifact-integrity.sh" "$work/artifact"

env NGINX_CONFIG_DIR="$work/container-config" NGINX_TEMPLATE_DIR="$split/nginx" \
  PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https BACKEND_SERVICE="$marker:8080" CLIENT_MAX_BODY_SIZE=2m LISTEN_PORT=8080 \
  UMAMI_WEBSITE_ID=test-site UMAMI_SCRIPT_URL=https://analytics.example/script.js GOOGLE_ANALYTICS_ID=G-TEST123 \
  "$split/scripts/render-release.sh" "$work/artifact" "$work/container-runtime"
env NGINX_CONFIG_DIR="$work/container-config" NGINX_TEMPLATE_DIR="$split/nginx" \
  PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https BACKEND_SERVICE="$marker:8080" CLIENT_MAX_BODY_SIZE=2m LISTEN_PORT=8080 \
  "$split/scripts/render-nginx.sh"

grep -F 'analytics.example/script.js' "$work/container-runtime/index.html" >/dev/null || fail "Umami injection missing"
grep -F 'G-TEST123' "$work/container-runtime/index.html" >/dev/null || fail "Google Analytics injection missing"

env NGINX_CONFIG_DIR="$work/container-config-unset" NGINX_TEMPLATE_DIR="$split/nginx" \
  PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https BACKEND_SERVICE="$marker:8080" CLIENT_MAX_BODY_SIZE=2m LISTEN_PORT=8080 \
  "$split/scripts/render-release.sh" "$work/artifact" "$work/container-runtime-unset"
env NGINX_CONFIG_DIR="$work/container-config-unset" NGINX_TEMPLATE_DIR="$split/nginx" \
  PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https BACKEND_SERVICE="$marker:8080" CLIENT_MAX_BODY_SIZE=2m LISTEN_PORT=8080 \
  "$split/scripts/render-nginx.sh"
if grep -F '<script' "$work/container-runtime-unset/index.html" >/dev/null; then
  fail "analytics scripts must be absent when analytics is unset"
fi

challenge=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
if HOST_NGINX_CONFIG_DIR="$work/invalid" PUBLIC_HOST='invalid host' EXTERNAL_SCHEME=https \
  STATIC_RELEASE_ROOT="$work/container-runtime" BACKEND_ENDPOINT=http://127.0.0.1:3000 \
  HOST_REAL_IP_INCLUDE="$work/host-real-ip.conf" DEPLOYMENT_CHALLENGE=$challenge \
  "$split/scripts/render-host-nginx.sh" 2>/dev/null; then
  fail "unsafe host input must be rejected"
fi
if HOST_NGINX_CONFIG_DIR="$work/invalid" PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https \
  STATIC_RELEASE_ROOT="$work/container-runtime" BACKEND_ENDPOINT=backend.internal:3000 \
  HOST_REAL_IP_INCLUDE="$work/host-real-ip.conf" DEPLOYMENT_CHALLENGE=$challenge \
  "$split/scripts/render-host-nginx.sh" 2>/dev/null; then
  fail "unsafe backend endpoint must be rejected"
fi
for public_backend in https://public.example.com:443 http://8.8.8.8:8080; do
  if HOST_NGINX_CONFIG_DIR="$work/invalid" PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https \
    STATIC_RELEASE_ROOT="$work/container-runtime" BACKEND_ENDPOINT=$public_backend \
    HOST_REAL_IP_INCLUDE="$work/host-real-ip.conf" DEPLOYMENT_CHALLENGE=$challenge \
    "$split/scripts/render-host-nginx.sh" 2>/dev/null; then
    fail "public backend endpoint must be rejected: $public_backend"
  fi
done
mkdir "$work/existing-host-config"
printf '%s\n' preserved > "$work/existing-host-config/sentinel"
if HOST_NGINX_CONFIG_DIR="$work/existing-host-config" PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https \
  STATIC_RELEASE_ROOT="$work/container-runtime" BACKEND_ENDPOINT=http://127.0.0.1:3000 \
  HOST_REAL_IP_INCLUDE="$work/host-real-ip.conf" DEPLOYMENT_CHALLENGE=$challenge \
  "$split/scripts/render-host-nginx.sh" 2>/dev/null; then
  fail "existing host candidate directory must be rejected"
fi
grep -Fx preserved "$work/existing-host-config/sentinel" >/dev/null || fail "existing host candidate was modified"

docker network create "$network" >/dev/null
docker run -d --name "$marker" --network "$network" \
  -v "$split/tests/marker-backend.py:/marker.py:ro" \
  python:3.12-alpine@sha256:6d43704baacd1bfbe7c295d7f13079d5d8104ed33568873133f8fc69980419df python3 /marker.py 8080 >/dev/null

contains() { printf '%s' "$1" | grep -F "$2" >/dev/null || fail "$adapter: expected $2 in response: $1"; }

wait_for_adapter() {
  adapter=$1
  base=$2
  attempt=0
  until curl --silent --fail --output /dev/null --max-time 1 -H 'Host: contract.test' "$base/index.html"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || fail "$adapter: Nginx did not become ready"
    sleep 0.05
  done
}

assert_adapter() {
  adapter=$1
  base=$2
  request() { curl --silent --show-error --max-time 5 -H 'Host: contract.test' "$@"; }
  status() { curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 -H 'Host: contract.test' "$@"; }

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
    [ "$(status "$base/$path")" = 200 ] || fail "$adapter: /$path must remain SPA-owned"
  done
  [ "$(status "$base/anything/mj/echo")" = 200 ] || fail "$adapter: unregistered mode-MJ action must remain SPA-owned"
  [ "$(status "$base/assets/missing.js")" = 404 ] || fail "$adapter: missing /assets files must return 404"
  [ "$(status "$base/static/missing.js")" = 404 ] || fail "$adapter: missing /static files must return 404"
  for asset in assets/app.123.js static/app.123.js; do
    asset_headers=$(curl --silent --show-error --head -H 'Host: contract.test' "$base/$asset")
    printf '%s' "$asset_headers" | grep -Eqi '^Cache-Control:.*immutable' || fail "$adapter: $asset needs immutable caching"
  done
  index_headers=$(curl --silent --show-error --head -H 'Host: contract.test' "$base/index.html")
  printf '%s' "$index_headers" | grep -Eqi '^Cache-Control:.*no-(store|cache)' || fail "$adapter: index must not be persistently cached"

  xff=$(request -H 'X-Forwarded-For: forged' "$base/api/xff")
  printf '%s' "$xff" | grep -F 'forged' >/dev/null && fail "$adapter: forged X-Forwarded-For reached backend"
  contains "$xff" '"xff": "'
  unknown=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 -H 'Host: attacker.invalid' "$base/dashboard" || true)
  case $unknown in 000|444) ;; *) fail "$adapter: unknown Host was not rejected: $unknown" ;; esac

  assert_sse_immediate() {
    path=$1
    output="$work/$adapter-sse.out"
    rm -f "$output"
    curl --silent --show-error -N --max-time 4 -H 'Host: contract.test' "$base$path" > "$output" &
    pid=$!
    found=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if grep -F 'data: immediate' "$output" >/dev/null 2>&1; then found=true; break; fi
      sleep 0.1
    done
    [ "$found" = true ] || { kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; fail "$adapter: $path first SSE event was buffered"; }
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  }
  assert_sse_immediate /v1/sse
  assert_sse_immediate /api/sse
  ws=$(curl --silent --show-error --include --max-time 2 --http1.1 \
    -H 'Host: contract.test' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    -H 'Sec-WebSocket-Protocol: openai-realtime' "$base/v1/realtime" || true)
  printf '%s' "$ws" | grep -F '101 Switching Protocols' >/dev/null || fail "$adapter: WebSocket upgrade failed"
  printf '%s' "$ws" | grep -Eqi '^Sec-WebSocket-Protocol: openai-realtime' || fail "$adapter: WebSocket subprotocol missing"

  python3 -c 'import sys; sys.stdout.write("x" * 1048576)' > "$work/upload.bin"
  response=$(request -X POST --data-binary "@$work/upload.bin" "$base/api/upload")
  contains "$response" '"path": "/api/upload"'
  contains "$response" '"body_size": 1048576'
}

run_container_adapter() {
  adapter=container
  nginx_name="split-container-nginx-$$"
  nginx_containers="$nginx_containers $nginx_name"
  docker run --rm --network "$network" \
    -v "$work/container-config:/config:ro" \
    -v "$work/container-runtime:/usr/share/nginx/html:ro" \
    --tmpfs /tmp:rw,uid=101,gid=101 \
    nginxinc/nginx-unprivileged:1.27.5-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0 \
    sh -c 'mkdir -p /tmp/nginx/conf.d && cp /config/* /tmp/nginx/conf.d/ && nginx -c /tmp/nginx/conf.d/nginx.conf -t' >/dev/null
  docker run -d --name "$nginx_name" --network "$network" -p 127.0.0.1::8080 \
    -v "$work/container-config:/config:ro" \
    -v "$work/container-runtime:/usr/share/nginx/html:ro" \
    --tmpfs /tmp:rw,uid=101,gid=101 \
    nginxinc/nginx-unprivileged:1.27.5-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0 \
    sh -c 'mkdir -p /tmp/nginx/conf.d && cp /config/* /tmp/nginx/conf.d/ && exec nginx -c /tmp/nginx/conf.d/nginx.conf -g "daemon off;"' >/dev/null
  port=$(docker port "$nginx_name" 8080/tcp | python3 -c 'import sys; print(sys.stdin.read().strip().rsplit(":", 1)[1])')
  wait_for_adapter "$adapter" "http://127.0.0.1:$port"
  assert_adapter "$adapter" "http://127.0.0.1:$port"
  docker rm -f "$nginx_name" >/dev/null
  nginx_containers=$(printf '%s' "$nginx_containers" | tr ' ' '\n' | grep -Fvx "$nginx_name" | tr '\n' ' ' || true)
  printf '%s\n' 'route-contract: container PASS'
}

run_host_adapter() {
  adapter=host
  nginx_name="split-host-nginx-$$"
  nginx_containers="$nginx_containers $nginx_name"
  marker_ip=$(docker inspect "$marker" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  HOST_NGINX_CONFIG_DIR="$work/host-config" PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https \
    STATIC_RELEASE_ROOT="$work/container-runtime" BACKEND_ENDPOINT="http://$marker_ip:8080" \
    CLIENT_MAX_BODY_SIZE=2m HOST_REAL_IP_INCLUDE="$work/host-real-ip.conf" \
    DEPLOYMENT_CHALLENGE=$challenge "$split/scripts/render-host-nginx.sh"
  cat > "$work/host-nginx.conf" <<EOF
worker_processes 1;
pid /tmp/nginx.pid;
events { worker_connections 64; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include $work/host-config/host-http-prerequisites.conf;
    server {
        listen 8080;
        server_name contract.test;
        include $work/host-config/host-server.inc;
    }
}
EOF
  docker run --rm --network "$network" \
    -v "$work:$work:ro" \
    --tmpfs /tmp:rw,uid=101,gid=101 \
    nginxinc/nginx-unprivileged:1.27.5-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0 \
    nginx -c "$work/host-nginx.conf" -t >/dev/null
  docker run -d --name "$nginx_name" --network "$network" -p 127.0.0.1::8080 \
    -v "$work:$work:ro" \
    --tmpfs /tmp:rw,uid=101,gid=101 \
    nginxinc/nginx-unprivileged:1.27.5-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0 \
    nginx -c "$work/host-nginx.conf" -g 'daemon off;' >/dev/null
  port=$(docker port "$nginx_name" 8080/tcp | python3 -c 'import sys; print(sys.stdin.read().strip().rsplit(":", 1)[1])')
  wait_for_adapter "$adapter" "http://127.0.0.1:$port"
  assert_adapter "$adapter" "http://127.0.0.1:$port"
  docker rm -f "$nginx_name" >/dev/null
  nginx_containers=$(printf '%s' "$nginx_containers" | tr ' ' '\n' | grep -Fvx "$nginx_name" | tr '\n' ' ' || true)
  printf '%s\n' 'route-contract: host PASS'
}

run_container_adapter
run_host_adapter
printf '%s\n' 'route-contract: PASS'
