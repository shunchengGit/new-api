#!/bin/sh
set -eu

artifact_root=${1:?artifact root is required}
release_root=${2:?release root is required}
scripts_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
verify_artifact=${VERIFY_ARTIFACT:-$scripts_dir/verify-artifact.sh}
verify_release=${VERIFY_RELEASE:-$scripts_dir/verify-release.sh}
release_sidecar=${RELEASE_SIDECAR:-${release_root}.sha256}
: "${UMAMI_WEBSITE_ID:=}"
: "${UMAMI_SCRIPT_URL:=https://analytics.umami.is/script.js}"
: "${GOOGLE_ANALYTICS_ID:=}"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

case $UMAMI_WEBSITE_ID in *[!A-Za-z0-9_-]*|'') [ -z "$UMAMI_WEBSITE_ID" ] || fail 'invalid UMAMI_WEBSITE_ID' ;; esac
if [ -n "$UMAMI_WEBSITE_ID" ]; then
  case $UMAMI_SCRIPT_URL in https://*) ;; *) fail 'UMAMI_SCRIPT_URL must use https' ;; esac
  case $UMAMI_SCRIPT_URL in *[\"\'\<\>\ ]*) fail 'invalid UMAMI_SCRIPT_URL' ;; esac
fi
if [ -n "$GOOGLE_ANALYTICS_ID" ]; then
  case $GOOGLE_ANALYTICS_ID in G-[A-Z0-9]*) ;; *) fail 'invalid GOOGLE_ANALYTICS_ID' ;; esac
  case ${GOOGLE_ANALYTICS_ID#G-} in *[!A-Z0-9]*|'') fail 'invalid GOOGLE_ANALYTICS_ID' ;; esac
fi

"$verify_artifact" "$artifact_root"
[ ! -e "$release_sidecar" ] && [ ! -L "$release_sidecar" ] || fail "release sidecar already exists: $release_sidecar"
if [ -e "$release_root" ]; then
  [ ! -L "$release_root" ] || fail "release destination must not be a symbolic link: $release_root"
  [ -d "$release_root" ] || fail "release destination is not a directory: $release_root"
  [ -z "$(find "$release_root" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "release destination is not empty: $release_root"
else
  mkdir -p "$release_root"
fi

cp -R "$artifact_root/site"/. "$release_root"/
analytics_file=$(mktemp "${TMPDIR:-/tmp}/release-analytics.XXXXXX")
index_tmp=$(mktemp "$release_root/.index.XXXXXX")
trap 'rm -f "$analytics_file" "$index_tmp"' EXIT HUP INT TERM
{
  printf '%s\n' '<!--Umami QuantumNous-->'
  if [ -n "$UMAMI_WEBSITE_ID" ]; then
    printf '<script defer src="%s" data-website-id="%s"></script>\n' "$UMAMI_SCRIPT_URL" "$UMAMI_WEBSITE_ID"
  fi
  printf '%s\n' '<!--Google Analytics QuantumNous-->'
  if [ -n "$GOOGLE_ANALYTICS_ID" ]; then
    printf '<script async src="https://www.googletagmanager.com/gtag/js?id=%s"></script>\n' "$GOOGLE_ANALYTICS_ID"
    printf '<script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments)}gtag("js",new Date());gtag("config","%s");</script>\n' "$GOOGLE_ANALYTICS_ID"
  fi
} > "$analytics_file"

awk -v analytics_file="$analytics_file" '
  { gsub(/<!--umami-->/, ""); gsub(/<!--Google Analytics-->/, "") }
  /<\/head>/ && !injected { while ((getline line < analytics_file) > 0) print line; close(analytics_file); injected=1 }
  { print }
  END { if (!injected) exit 1 }
' "$release_root/index.html" > "$index_tmp" || fail 'index.html is missing </head>'
mv "$index_tmp" "$release_root/index.html"
cmp -s "$artifact_root/site/build-info.json" "$release_root/build-info.json" || fail 'rendered build info does not match artifact'
"$verify_artifact" "$artifact_root"
sidecar_tmp=$(mktemp "${release_sidecar}.XXXXXX")
trap 'rm -f "$analytics_file" "$index_tmp" "$sidecar_tmp"' EXIT HUP INT TERM
(
  cd "$release_root"
  find . \( -type d -o -type f \) -print | LC_ALL=C sort
) | while IFS= read -r path; do
  path=${path#./}
  if [ -d "$release_root/$path" ]; then
    printf 'd  ./%s\n' "$path"
  else
    if command -v sha256sum >/dev/null 2>&1; then
      digest=$(sha256sum "$release_root/$path" | awk '{print $1}')
    else
      digest=$(shasum -a 256 "$release_root/$path" | awk '{print $1}')
    fi
    printf 'f %s  ./%s\n' "$digest" "$path"
  fi
done > "$sidecar_tmp"
mv "$sidecar_tmp" "$release_sidecar"
"$verify_release" "$release_root" "$release_sidecar"
