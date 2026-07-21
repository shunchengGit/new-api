#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
split=$(CDPATH= cd -- "$here/.." && pwd)
checker=$split/scripts/check-route-ownership.sh

fail() { printf '%s\n' "check-route-ownership-fixture: FAIL: $*" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/check-route-ownership.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

make_fixture() {
  root=$1
  mkdir -p "$root/router" "$root/deploy/split/nginx"
  for route in \
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
    printf '%s\n' "$route" >> "$root/deploy/split/nginx/route-contract.inc.template"
  done
}

write_routes() {
  root=$1
  group=$2
  dashboard=$3
  printf 'package router\nfunc routes(router Engine) {\n  api := router.Group("%s")\n  _ = api\n}\n' "$group" > "$root/router/api-router.go"
  printf 'package router\nfunc dashboard(router Engine) {\n  api := router.Group("/")\n  api.GET("%s", handler)\n}\n' "$dashboard" > "$root/router/dashboard.go"
}

for namespace in /api /v1 /v1beta /mj /pg /suno /kling /jimeng jimeng; do
  accepted=$work/accepted-$(printf '%s' "$namespace" | tr '/' '_')
  make_fixture "$accepted"
  write_routes "$accepted" "$namespace" /dashboard/billing/usage
  "$checker" "$accepted" >/dev/null
done

for case_name in api-evil v1evil dashboard-billing-evil; do
  root=$work/$case_name
  make_fixture "$root"
  case $case_name in
    api-evil) write_routes "$root" /api-evil /dashboard/billing/usage ;;
    v1evil) write_routes "$root" /v1evil /dashboard/billing/usage ;;
    dashboard-billing-evil) write_routes "$root" /api /dashboard/billing/usage-evil ;;
  esac
  if "$checker" "$root" >/dev/null 2>&1; then
    fail "$case_name was accepted"
  fi
done

printf '%s\n' 'check-route-ownership-fixture: PASS'
