#!/bin/sh
set -eu

artifact_root=${1:?artifact root is required}
: "${THEME:?THEME is required}"
: "${APP_VERSION:?APP_VERSION is required}"
: "${VCS_REF:?VCS_REF is required}"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

case $THEME in default|classic) ;; *) fail 'THEME must be default or classic' ;; esac
case $APP_VERSION in *[!A-Za-z0-9._+-]*|'') fail 'invalid APP_VERSION' ;; esac
case $VCS_REF in *[!0-9A-Fa-f]*|'') fail 'invalid VCS_REF' ;; esac
[ "${#VCS_REF}" -eq 40 ] || fail 'VCS_REF must be exactly 40 hexadecimal characters'

validate_artifact_types() {
  [ ! -L "$artifact_root" ] || fail "artifact root must not be a symbolic link: $artifact_root"
  [ -d "$artifact_root" ] || fail "missing artifact root: $artifact_root"
  invalid=$(find "$artifact_root" ! -type d ! -type f -print -quit)
  [ -z "$invalid" ] || fail "artifact contains non-regular entry: $invalid"
}

validate_artifact_types
[ -d "$artifact_root/site" ] || fail "missing $artifact_root/site"
[ -d "$artifact_root/licenses" ] || fail "missing $artifact_root/licenses"
[ -f "$artifact_root/site/index.html" ] || fail "missing $artifact_root/site/index.html"

mkdir -p "$artifact_root/licenses/frontend"
find "$artifact_root/site" -type f \( -iname '*license*' -o -iname '*notice*' \) -exec cp -p {} "$artifact_root/licenses/frontend" \;

lockfile_sha256=$(sha256_file "${FRONTEND_LOCKFILE:?FRONTEND_LOCKFILE is required}")
printf '{"schema":1,"version":"%s","theme":"%s","revision":"%s"}\n' \
  "$APP_VERSION" "$THEME" "$VCS_REF" > "$artifact_root/site/build-info.json"
printf '{"schema":1,"application":"new-api","version":"%s","theme":"%s","revision":"%s","compatibleBackendVersion":"%s","frontendLockfileSha256":"%s"}\n' \
  "$APP_VERSION" "$THEME" "$VCS_REF" "$APP_VERSION" "$lockfile_sha256" > "$artifact_root/artifact-manifest.json"

checksums_tmp=$(mktemp "${artifact_root}/.checksums.XXXXXX")
trap 'rm -f "$checksums_tmp"' EXIT HUP INT TERM
(
  cd "$artifact_root"
  find . \( -type d -o -type f \) ! -path './checksums.sha256' ! -path './.checksums.*' -print | LC_ALL=C sort
) | while IFS= read -r path; do
  path=${path#./}
  if [ -d "$artifact_root/$path" ]; then
    printf 'd  ./%s\n' "$path"
  else
    printf 'f %s  ./%s\n' "$(sha256_file "$artifact_root/$path")" "$path"
  fi
done > "$checksums_tmp"
mv "$checksums_tmp" "$artifact_root/checksums.sha256"
chmod 0444 "$artifact_root/checksums.sha256" "$artifact_root/artifact-manifest.json" "$artifact_root/site/build-info.json"
