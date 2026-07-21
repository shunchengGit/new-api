#!/bin/sh
set -eu

artifact_root=${ARTIFACT_ROOT:-/usr/share/nginx/artifact}
runtime_root=${RUNTIME_ROOT:-/usr/share/nginx/html}
: "${RELEASE_SIDECAR:=/tmp/frontend-release.sha256}"
export RELEASE_SIDECAR
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

"$script_dir/render-release.sh" "$artifact_root" "$runtime_root"
"$script_dir/render-nginx.sh"
exec "$@"
