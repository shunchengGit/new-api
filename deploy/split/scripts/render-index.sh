#!/bin/sh
set -eu

source_root=${SOURCE_ROOT:-/usr/share/nginx/html-source}
runtime_root=${RUNTIME_ROOT:-/usr/share/nginx/html}
template_dir=${NGINX_TEMPLATE_DIR:-/etc/nginx/templates}
config_dir=${NGINX_CONFIG_DIR:-/tmp/nginx/conf.d}

: "${PUBLIC_HOST:?PUBLIC_HOST is required}"
: "${EXTERNAL_SCHEME:?EXTERNAL_SCHEME is required}"
: "${BACKEND_SERVICE:?BACKEND_SERVICE is required}"
: "${CLIENT_MAX_BODY_SIZE:=128m}"
: "${LISTEN_PORT:=8080}"
: "${UMAMI_WEBSITE_ID:=}"
: "${UMAMI_SCRIPT_URL:=https://analytics.umami.is/script.js}"
: "${GOOGLE_ANALYTICS_ID:=}"

case $PUBLIC_HOST in
  *[!A-Za-z0-9.-]* | '' | .* | *..* | *.) echo 'invalid PUBLIC_HOST' >&2; exit 1 ;;
esac
case $EXTERNAL_SCHEME in http|https) ;; *) echo 'EXTERNAL_SCHEME must be http or https' >&2; exit 1 ;; esac
case $BACKEND_SERVICE in *[!A-Za-z0-9._:-]* | '' | :* | *:) echo 'invalid BACKEND_SERVICE' >&2; exit 1 ;; esac
case $CLIENT_MAX_BODY_SIZE in *[!0-9kKmMgG]* | '') echo 'invalid CLIENT_MAX_BODY_SIZE' >&2; exit 1 ;; esac
case $LISTEN_PORT in *[!0-9]* | '') echo 'invalid LISTEN_PORT' >&2; exit 1 ;; esac

if [ -n "$UMAMI_WEBSITE_ID" ]; then
  case $UMAMI_WEBSITE_ID in *[!A-Za-z0-9_-]* | '') echo 'invalid UMAMI_WEBSITE_ID' >&2; exit 1 ;; esac
  case $UMAMI_SCRIPT_URL in https://*) ;; *) echo 'UMAMI_SCRIPT_URL must use https' >&2; exit 1 ;; esac
  case $UMAMI_SCRIPT_URL in *[\"\'\<\>\ ]*) echo 'invalid UMAMI_SCRIPT_URL' >&2; exit 1 ;; esac
fi
if [ -n "$GOOGLE_ANALYTICS_ID" ]; then
  case $GOOGLE_ANALYTICS_ID in G-[A-Z0-9]*) ;; *) echo 'invalid GOOGLE_ANALYTICS_ID' >&2; exit 1 ;; esac
  case ${GOOGLE_ANALYTICS_ID#G-} in *[!A-Z0-9]* | '') echo 'invalid GOOGLE_ANALYTICS_ID' >&2; exit 1 ;; esac
fi

[ -f "$source_root/index.html" ] || { echo "missing $source_root/index.html" >&2; exit 1; }
[ -d "$template_dir" ] || { echo "missing $template_dir" >&2; exit 1; }

mkdir -p "$runtime_root" "$config_dir" /tmp/nginx/client_temp /tmp/nginx/proxy_temp /tmp/nginx/fastcgi_temp /tmp/nginx/uwsgi_temp /tmp/nginx/scgi_temp
rm -rf "$runtime_root"/*
cp -R "$source_root"/. "$runtime_root"/

analytics_file=$(mktemp)
trap 'rm -f "$analytics_file"' EXIT HUP INT TERM
{
  echo '<!--Umami QuantumNous-->'
  if [ -n "$UMAMI_WEBSITE_ID" ]; then
    printf '<script defer src="%s" data-website-id="%s"></script>\n' "$UMAMI_SCRIPT_URL" "$UMAMI_WEBSITE_ID"
  fi
  echo '<!--Google Analytics QuantumNous-->'
  if [ -n "$GOOGLE_ANALYTICS_ID" ]; then
    printf '<script async src="https://www.googletagmanager.com/gtag/js?id=%s"></script>\n' "$GOOGLE_ANALYTICS_ID"
    printf '<script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments)}gtag("js",new Date());gtag("config","%s");</script>\n' "$GOOGLE_ANALYTICS_ID"
  fi
} > "$analytics_file"

index_tmp=$(mktemp "$runtime_root/.index.XXXXXX")
awk -v analytics_file="$analytics_file" '
  { gsub(/<!--umami-->/, ""); gsub(/<!--Google Analytics-->/, "") }
  /<\/head>/ && !injected { while ((getline line < analytics_file) > 0) print line; close(analytics_file); injected=1 }
  { print }
  END { if (!injected) exit 1 }
' "$source_root/index.html" > "$index_tmp" || { rm -f "$index_tmp"; echo 'index.html is missing </head>' >&2; exit 1; }
mv "$index_tmp" "$runtime_root/index.html"

render_template() {
  input=$1
  output=$2
  tmp=$(mktemp "${output}.XXXXXX")
  sed \
    -e "s|@PUBLIC_HOST@|$PUBLIC_HOST|g" \
    -e "s|@EXTERNAL_SCHEME@|$EXTERNAL_SCHEME|g" \
    -e "s|@BACKEND_SERVICE@|$BACKEND_SERVICE|g" \
    -e "s|@CLIENT_MAX_BODY_SIZE@|$CLIENT_MAX_BODY_SIZE|g" \
    -e "s|@LISTEN_PORT@|$LISTEN_PORT|g" \
    "$input" > "$tmp"
  mv "$tmp" "$output"
}

render_template "$template_dir/nginx.conf.template" "$config_dir/nginx.conf"
render_template "$template_dir/backend-proxy.inc.template" "$config_dir/backend-proxy.inc"
render_template "$template_dir/real-ip.conf.template" "$config_dir/real-ip.conf"

exec "$@"
