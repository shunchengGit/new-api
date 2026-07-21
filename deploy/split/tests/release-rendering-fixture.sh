#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
split=$(CDPATH= cd -- "$here/.." && pwd)

fail() {
  printf '%s\n' "release-rendering-fixture: FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/split-release-rendering.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

artifact="$work/artifact"
mkdir -p "$artifact/site/assets" "$artifact/licenses/frontend"
printf '%s\n' '<!doctype html><html><head><!--umami--><!--Google Analytics--></head><body>fixture</body></html>' > "$artifact/site/index.html"
printf '%s\n' 'asset' > "$artifact/site/assets/app.123.js"
printf '%s\n' 'frontend license' > "$artifact/licenses/frontend/LICENSE.txt"
printf '%s\n' 'license' > "$artifact/licenses/LICENSE"
printf '%s\n' 'notice' > "$artifact/licenses/NOTICE"
printf '%s\n' 'third-party' > "$artifact/licenses/THIRD-PARTY-LICENSES.md"
printf '%s\n' 'lockfile' > "$work/bun.lock"
THEME=default APP_VERSION=v1.2.3 VCS_REF=0123456789abcdef0123456789abcdef01234567 FRONTEND_LOCKFILE="$work/bun.lock" \
  "$split/scripts/generate-artifact-integrity.sh" "$artifact"

before=$(find "$artifact" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort)
"$split/scripts/verify-artifact.sh" "$artifact"
[ -r "$artifact/checksums.sha256" ] || fail 'artifact checksum manifest is not readable'
[ "$(stat -f '%Lp' "$artifact/checksums.sha256" 2>/dev/null || stat -c '%a' "$artifact/checksums.sha256")" = 444 ] || fail 'artifact checksum manifest is not read-only for runtime users'
UMAMI_WEBSITE_ID=site_1 UMAMI_SCRIPT_URL=https://analytics.example/script.js GOOGLE_ANALYTICS_ID=G-TEST123 \
  "$split/scripts/render-release.sh" "$artifact" "$work/release"
grep -F 'analytics.example/script.js' "$work/release/index.html" >/dev/null || fail 'Umami script was not rendered'
grep -F 'G-TEST123' "$work/release/index.html" >/dev/null || fail 'Google Analytics script was not rendered'
cmp -s "$artifact/site/build-info.json" "$work/release/build-info.json" || fail 'rendered build info does not match artifact'
[ -f "$work/release.sha256" ] || fail 'release sidecar was not written outside the release root'
"$split/scripts/verify-release.sh" "$work/release"
cp "$work/release/index.html" "$work/index.html.original"
printf '%s\n' tampered >> "$work/release/index.html"
if "$split/scripts/verify-release.sh" "$work/release" >/dev/null 2>&1; then
  fail 'modified release passed sidecar verification'
fi
mv "$work/index.html.original" "$work/release/index.html"
printf '%s\n' unexpected > "$work/release/unexpected"
if "$split/scripts/verify-release.sh" "$work/release" >/dev/null 2>&1; then
  fail 'release with an unexpected file passed sidecar verification'
fi
rm "$work/release/unexpected"
ln -s /etc/passwd "$work/release/absolute-link"
if "$split/scripts/verify-release.sh" "$work/release" >/dev/null 2>&1; then
  fail 'release with a symbolic link passed sidecar verification'
fi
rm "$work/release/absolute-link"
"$split/scripts/verify-release.sh" "$work/release"
after=$(find "$artifact" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort)
[ "$before" = "$after" ] || fail 'release rendering modified source artifact'

printf '%s\n' existing-sidecar > "$work/release-existing.sha256"
if "$split/scripts/render-release.sh" "$artifact" "$work/release-existing" >/dev/null 2>&1; then
  fail 'existing release sidecar was overwritten'
fi

"$split/scripts/render-release.sh" "$artifact" "$work/release-unset"
if grep -F '<script' "$work/release-unset/index.html" >/dev/null; then
  fail 'analytics script was rendered without configuration'
fi

if UMAMI_WEBSITE_ID='unsafe value' "$split/scripts/render-release.sh" "$artifact" "$work/invalid-analytics" >/dev/null 2>&1; then
  fail 'invalid analytics value was accepted'
fi

mkdir -p "$work/non-empty"
printf '%s\n' existing > "$work/non-empty/file"
if "$split/scripts/render-release.sh" "$artifact" "$work/non-empty" >/dev/null 2>&1; then
  fail 'non-empty destination was overwritten'
fi

printf '%s\n' unexpected > "$artifact/unexpected"
if "$split/scripts/render-release.sh" "$artifact" "$work/unexpected-file" >/dev/null 2>&1; then
  fail 'artifact with an unexpected file passed verification'
fi
[ ! -e "$work/unexpected-file" ] && [ ! -L "$work/unexpected-file" ] || fail 'unexpected-file artifact was copied to release'
rm "$artifact/unexpected"

ln -s /etc/passwd "$artifact/site/assets/absolute-link"
if "$split/scripts/render-release.sh" "$artifact" "$work/absolute-link" >/dev/null 2>&1; then
  fail 'artifact with an absolute symbolic link passed verification'
fi
[ ! -e "$work/absolute-link" ] && [ ! -L "$work/absolute-link" ] || fail 'absolute symbolic link artifact was copied to release'
rm "$artifact/site/assets/absolute-link"

ln -s app.123.js "$artifact/site/assets/relative-link"
if "$split/scripts/render-release.sh" "$artifact" "$work/relative-link" >/dev/null 2>&1; then
  fail 'artifact with a relative symbolic link passed verification'
fi
[ ! -e "$work/relative-link" ] && [ ! -L "$work/relative-link" ] || fail 'relative symbolic link artifact was copied to release'
rm "$artifact/site/assets/relative-link"

if command -v mkfifo >/dev/null 2>&1; then
  mkfifo "$artifact/site/assets/stream"
  if "$split/scripts/render-release.sh" "$artifact" "$work/fifo" >/dev/null 2>&1; then
    fail 'artifact with a FIFO passed verification'
  fi
  [ ! -e "$work/fifo" ] && [ ! -L "$work/fifo" ] || fail 'FIFO artifact was copied to release'
  rm "$artifact/site/assets/stream"
fi

mkdir "$artifact/site/extra-empty-directory"
if "$split/scripts/render-release.sh" "$artifact" "$work/extra-directory" >/dev/null 2>&1; then
  fail 'artifact with an extra empty directory passed verification'
fi
[ ! -e "$work/extra-directory" ] && [ ! -L "$work/extra-directory" ] || fail 'extra-directory artifact was copied to release'
rmdir "$artifact/site/extra-empty-directory"

printf '%s\n' changed >> "$artifact/site/assets/app.123.js"
if "$split/scripts/render-release.sh" "$artifact" "$work/checksum-failure" >/dev/null 2>&1; then
  fail 'modified artifact passed verification'
fi

printf '%s\n' 'release-rendering-fixture: PASS'
