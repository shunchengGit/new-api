#!/bin/sh
set -eu

artifact_root=${1:?artifact root is required}

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

[ ! -L "$artifact_root" ] || fail "artifact root must not be a symbolic link: $artifact_root"
[ -d "$artifact_root" ] || fail "missing artifact root: $artifact_root"
invalid=$(find "$artifact_root" ! -type d ! -type f -print -quit)
[ -z "$invalid" ] || fail "artifact contains non-regular entry: $invalid"
[ -f "$artifact_root/artifact-manifest.json" ] || fail 'missing artifact-manifest.json'
[ -f "$artifact_root/checksums.sha256" ] || fail 'missing checksums.sha256'
[ -f "$artifact_root/site/build-info.json" ] || fail 'missing site/build-info.json'
[ -f "$artifact_root/licenses/LICENSE" ] || fail 'missing licenses/LICENSE'
[ -f "$artifact_root/licenses/NOTICE" ] || fail 'missing licenses/NOTICE'
[ -f "$artifact_root/licenses/THIRD-PARTY-LICENSES.md" ] || fail 'missing licenses/THIRD-PARTY-LICENSES.md'

manifest=$(cat "$artifact_root/artifact-manifest.json")
build_info=$(cat "$artifact_root/site/build-info.json")
printf '%s' "$manifest" | grep -Eq '^\{"schema":1,"application":"new-api","version":"[A-Za-z0-9._+-]+","theme":"(default|classic)","revision":"[0-9A-Fa-f]{40}","compatibleBackendVersion":"[A-Za-z0-9._+-]+","frontendLockfileSha256":"[0-9a-f]{64}"\}$' || fail 'invalid artifact manifest'
printf '%s' "$build_info" | grep -Eq '^\{"schema":1,"version":"[A-Za-z0-9._+-]+","theme":"(default|classic)","revision":"[0-9A-Fa-f]{40}"\}$' || fail 'invalid build info'

manifest_version=$(printf '%s' "$manifest" | cut -d '"' -f 10)
manifest_theme=$(printf '%s' "$manifest" | cut -d '"' -f 14)
manifest_revision=$(printf '%s' "$manifest" | cut -d '"' -f 18)
printf '%s' "$build_info" | grep -F "\"version\":\"$manifest_version\"" >/dev/null || fail 'build info version does not match manifest'
printf '%s' "$build_info" | grep -F "\"theme\":\"$manifest_theme\"" >/dev/null || fail 'build info theme does not match manifest'
printf '%s' "$build_info" | grep -F "\"revision\":\"$manifest_revision\"" >/dev/null || fail 'build info revision does not match manifest'

expected=$(mktemp "${TMPDIR:-/tmp}/artifact-expected.XXXXXX")
actual=$(mktemp "${TMPDIR:-/tmp}/artifact-actual.XXXXXX")
trap 'rm -f "$expected" "$actual"' EXIT HUP INT TERM
(
  cd "$artifact_root"
  LC_ALL=C sort checksums.sha256
) > "$expected"
(
  cd "$artifact_root"
  find . \( -type d -o -type f \) ! -path './checksums.sha256' -print | LC_ALL=C sort
) | while IFS= read -r path; do
  path=${path#./}
  if [ -d "$artifact_root/$path" ]; then
    printf 'd  ./%s\n' "$path"
  else
    printf 'f %s  ./%s\n' "$(sha256_file "$artifact_root/$path")" "$path"
  fi
done | LC_ALL=C sort > "$actual"

cmp -s "$expected" "$actual" || fail 'artifact checksum manifest does not match exact artifact entry set'
