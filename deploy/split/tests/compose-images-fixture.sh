#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
split=$(CDPATH= cd -- "$here/.." && pwd)
fail() { printf '%s\n' "compose-images-fixture: FAIL: $*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || fail "requires Docker Compose"

work=$(mktemp -d "${TMPDIR:-/tmp}/compose-images.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

if grep -Eq '^[[:space:]]+build:' "$split/compose.yaml"; then
  fail "production Compose must not contain build blocks"
fi
for variable in FRONTEND_IMAGE BACKEND_IMAGE POSTGRES_IMAGE REDIS_IMAGE; do
  grep -F '${'"$variable"':?set ' "$split/compose.yaml" >/dev/null || fail "$variable is not required by Compose"
done

render() {
  output=$1
  frontend=$2
  backend=$3
  postgres=$4
  redis=$5
  FRONTEND_IMAGE=$frontend BACKEND_IMAGE=$backend POSTGRES_IMAGE=$postgres REDIS_IMAGE=$redis \
  POSTGRES_PASSWORD=test REDIS_PASSWORD=test SESSION_SECRET=test \
    docker compose -f "$split/compose.yaml" config > "$output"
}

render "$work/valid.yaml" \
  "registry.example/frontend@sha256:$digest" \
  "registry.example/backend@sha256:$digest" \
  "postgres@sha256:$digest" \
  "redis@sha256:$digest"
"$split/scripts/verify-compose-images.sh" "$work/valid.yaml" >/dev/null

render "$work/tag.yaml" \
  'registry.example/frontend:latest' \
  "registry.example/backend@sha256:$digest" \
  "postgres@sha256:$digest" \
  "redis@sha256:$digest"
if "$split/scripts/verify-compose-images.sh" "$work/tag.yaml" >/dev/null 2>&1; then
  fail "mutable image tag passed validation"
fi

render "$work/bad-digest.yaml" \
  "registry.example/frontend@sha256:$digest" \
  'registry.example/backend@sha256:short' \
  "postgres@sha256:$digest" \
  "redis@sha256:$digest"
if "$split/scripts/verify-compose-images.sh" "$work/bad-digest.yaml" >/dev/null 2>&1; then
  fail "invalid image digest passed validation"
fi

printf '%s\n' 'compose-images-fixture: PASS'
