#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
split=$(CDPATH= cd -- "$here/.." && pwd)
fail() { printf '%s\n' "verify-host-release-contract: FAIL: $*" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || fail "requires curl"
command -v docker >/dev/null 2>&1 || fail "requires Docker"
docker info >/dev/null 2>&1 || fail "requires a running Docker daemon"

nginx_image='nginxinc/nginx-unprivileged:1.27.5-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0'
python_image='python:3.12-alpine@sha256:6d43704baacd1bfbe7c295d7f13079d5d8104ed33568873133f8fc69980419df'
work=$(mktemp -d "/tmp/verify-host-release.XXXXXX")
chmod 0755 "$work"
revision=037710ec037710ec037710ec037710ec037710ec
network="verify-host-release-$$"
marker="verify-host-marker-$$"
nginx="verify-host-nginx-$$"
cleanup() {
  docker rm -f "$nginx" "$marker" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

artifact=$work/artifact
release=$work/release
mkdir -p "$artifact/site/assets" "$artifact/licenses/frontend"
printf '%s\n' '<!doctype html><html><head><!--umami--><!--Google Analytics--></head><body>fixture</body></html>' > "$artifact/site/index.html"
printf '%s\n' fixture > "$artifact/site/assets/app.123.js"
printf '%s\n' license > "$artifact/licenses/LICENSE"
printf '%s\n' notice > "$artifact/licenses/NOTICE"
printf '%s\n' third-party > "$artifact/licenses/THIRD-PARTY-LICENSES.md"
printf '%s\n' frontend-license > "$artifact/licenses/frontend/LICENSE.txt"
printf '%s\n' lockfile > "$work/bun.lock"
THEME=default APP_VERSION=v1.0.0-rc.21 VCS_REF=$revision FRONTEND_LOCKFILE="$work/bun.lock" \
  "$split/scripts/generate-artifact-integrity.sh" "$artifact"
"$split/scripts/render-release.sh" "$artifact" "$release"

printf '%s\n' '# direct client connection; no trusted upstream proxy' > "$work/real-ip.conf"
docker network create "$network" >/dev/null
docker run -d --name "$marker" --network "$network" \
  -e FIXTURE_VERSION=v1.0.0-rc.21 -e FIXTURE_THEME=default \
  -v "$split/tests/marker-backend.py:/marker.py:ro" \
  "$python_image" python3 /marker.py 8080 >/dev/null
marker_ip=$(docker inspect "$marker" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
challenge=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

HOST_NGINX_CONFIG_DIR="$work/nginx" PUBLIC_HOST=contract.test EXTERNAL_SCHEME=https \
  STATIC_RELEASE_ROOT="$release" BACKEND_ENDPOINT="http://$marker_ip:8080" \
  CLIENT_MAX_BODY_SIZE=2m HOST_REAL_IP_INCLUDE="$work/real-ip.conf" \
  DEPLOYMENT_CHALLENGE=$challenge "$split/scripts/render-host-nginx.sh"
cat > "$work/nginx.conf" <<EOF
worker_processes 1;
pid /tmp/nginx.pid;
events { worker_connections 64; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include $work/nginx/host-http-prerequisites.conf;
    server {
        listen 8080;
        server_name contract.test;
        include $work/nginx/host-server.inc;
    }
}
EOF
cat > "$work/nginx-test" <<EOF
#!/bin/sh
set -eu
docker run --rm --network "$network" \\
  -v "$work:$work:ro" \\
  --tmpfs /tmp:rw,uid=101,gid=101 \\
  "$nginx_image" nginx -c "\$1" -T
EOF
chmod 0555 "$work/nginx-test"
"$work/nginx-test" "$work/nginx.conf" >/dev/null

docker run -d --name "$nginx" --network "$network" -p 127.0.0.1::8080 \
  -v "$work:$work:ro" --tmpfs /tmp:rw,uid=101,gid=101 \
  "$nginx_image" nginx -c "$work/nginx.conf" -g 'daemon off;' >/dev/null
port=$(docker port "$nginx" 8080/tcp | python3 -c 'import sys; print(sys.stdin.read().strip().rsplit(":", 1)[1])')
candidate_url="http://127.0.0.1:$port"
attempt=0
until curl --fail --silent --output /dev/null -H 'Host: contract.test' "$candidate_url/api/status"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 50 ] || fail "candidate Nginx did not become ready"
  sleep 0.05
done

ARTIFACT_ROOT=$artifact RELEASE_ROOT=$release HOST_NGINX_CONFIG="$work/nginx.conf" \
HOST_NGINX_BINDING_FILE="$work/nginx/host-server.inc" NGINX_TEST_COMMAND="$work/nginx-test" \
CANDIDATE_URL=$candidate_url PUBLIC_HOST=contract.test DEPLOYMENT_CHALLENGE=$challenge \
EXPECTED_VERSION=v1.0.0-rc.21 EXPECTED_THEME=default EXPECTED_REVISION=$revision \
  "$split/scripts/verify-host-release.sh" >/dev/null

if ARTIFACT_ROOT=$artifact RELEASE_ROOT=$release HOST_NGINX_CONFIG="$work/nginx.conf" \
  HOST_NGINX_BINDING_FILE="$work/nginx/host-server.inc" NGINX_TEST_COMMAND=/usr/bin/true \
  CANDIDATE_URL=$candidate_url PUBLIC_HOST=contract.test \
  DEPLOYMENT_CHALLENGE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  EXPECTED_VERSION=v1.0.0-rc.21 EXPECTED_THEME=default EXPECTED_REVISION=$revision \
  "$split/scripts/verify-host-release.sh" >/dev/null 2>&1; then
  fail "healthy candidate passed with the wrong deployment challenge"
fi

cat > "$work/unrelated-nginx.conf" <<EOF
events {}
http {
    # include $work/nginx/host-server.inc;
}
EOF
if ARTIFACT_ROOT=$artifact RELEASE_ROOT=$release HOST_NGINX_CONFIG="$work/unrelated-nginx.conf" \
  HOST_NGINX_BINDING_FILE="$work/nginx/host-server.inc" NGINX_TEST_COMMAND=/usr/bin/true \
  CANDIDATE_URL=$candidate_url PUBLIC_HOST=contract.test DEPLOYMENT_CHALLENGE=$challenge \
  EXPECTED_VERSION=v1.0.0-rc.21 EXPECTED_THEME=default EXPECTED_REVISION=$revision \
  "$split/scripts/verify-host-release.sh" >/dev/null 2>&1; then
  fail "commented binding, no-op syntax command, and healthy candidate passed binding verification"
fi

printf '%s\n' changed >> "$release/assets/app.123.js"
if ARTIFACT_ROOT=$artifact RELEASE_ROOT=$release HOST_NGINX_CONFIG="$work/nginx.conf" \
  HOST_NGINX_BINDING_FILE="$work/nginx/host-server.inc" NGINX_TEST_COMMAND="$work/nginx-test" \
  CANDIDATE_URL=$candidate_url PUBLIC_HOST=contract.test DEPLOYMENT_CHALLENGE=$challenge \
  EXPECTED_VERSION=v1.0.0-rc.21 EXPECTED_THEME=default EXPECTED_REVISION=$revision \
  "$split/scripts/verify-host-release.sh" >/dev/null 2>&1; then
  fail "release asset provenance mismatch passed"
fi

printf '%s\n' 'verify-host-release-contract: PASS'
