#!/bin/sh
set -eu

release_root=${1:?release root is required}
release_sidecar=${2:-${release_root}.sha256}

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

[ ! -L "$release_root" ] || fail "release root must not be a symbolic link: $release_root"
[ -d "$release_root" ] || fail "missing release root: $release_root"
[ ! -L "$release_sidecar" ] || fail "release sidecar must not be a symbolic link: $release_sidecar"
[ -f "$release_sidecar" ] || fail "missing release sidecar: $release_sidecar"
invalid=$(find "$release_root" ! -type d ! -type f -print -quit)
[ -z "$invalid" ] || fail "release contains non-regular entry: $invalid"

expected=$(mktemp "${TMPDIR:-/tmp}/release-expected.XXXXXX")
actual=$(mktemp "${TMPDIR:-/tmp}/release-actual.XXXXXX")
trap 'rm -f "$expected" "$actual"' EXIT HUP INT TERM
LC_ALL=C sort "$release_sidecar" > "$expected"
(
  cd "$release_root"
  find . \( -type d -o -type f \) -print | LC_ALL=C sort
) | while IFS= read -r path; do
  path=${path#./}
  if [ -d "$release_root/$path" ]; then
    printf 'd  ./%s\n' "$path"
  else
    printf 'f %s  ./%s\n' "$(sha256_file "$release_root/$path")" "$path"
  fi
done | LC_ALL=C sort > "$actual"

cmp -s "$expected" "$actual" || fail 'release sidecar does not match exact release entry set'
