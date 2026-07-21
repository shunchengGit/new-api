#!/bin/sh
set -eu

template_dir=${NGINX_TEMPLATE_DIR:-/etc/nginx/templates}
config_dir=${NGINX_CONFIG_DIR:-/tmp/nginx/conf.d}

: "${PUBLIC_HOST:?PUBLIC_HOST is required}"
: "${EXTERNAL_SCHEME:?EXTERNAL_SCHEME is required}"
: "${BACKEND_SERVICE:?BACKEND_SERVICE is required}"
: "${CLIENT_MAX_BODY_SIZE:=128m}"
: "${LISTEN_PORT:=8080}"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

case $PUBLIC_HOST in *[!A-Za-z0-9.-]*|''|.*|*..*|*.) fail 'invalid PUBLIC_HOST' ;; esac
case $EXTERNAL_SCHEME in http|https) ;; *) fail 'EXTERNAL_SCHEME must be http or https' ;; esac
case $BACKEND_SERVICE in *[!A-Za-z0-9._:-]*|''|:*|*:) fail 'invalid BACKEND_SERVICE' ;; esac
case $CLIENT_MAX_BODY_SIZE in *[!0-9kKmMgG]*|'') fail 'invalid CLIENT_MAX_BODY_SIZE' ;; esac
case $LISTEN_PORT in *[!0-9]*|'') fail 'invalid LISTEN_PORT' ;; esac
[ -d "$template_dir" ] || fail "missing $template_dir"

mkdir -p "$config_dir" /tmp/nginx/client_temp /tmp/nginx/proxy_temp /tmp/nginx/fastcgi_temp /tmp/nginx/uwsgi_temp /tmp/nginx/scgi_temp
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
    -e 's|@BACKEND_PROXY_INCLUDE@|/tmp/nginx/conf.d/backend-proxy.inc|g' \
    -e 's|@BACKEND_UPSTREAM@|http://backend_upstream|g' \
    "$input" > "$tmp"
  mv "$tmp" "$output"
}

render_template "$template_dir/nginx.conf.template" "$config_dir/nginx.conf"
render_template "$template_dir/backend-proxy.inc.template" "$config_dir/backend-proxy.inc"
render_template "$template_dir/route-contract.inc.template" "$config_dir/route-contract.inc"
render_template "$template_dir/real-ip.conf.template" "$config_dir/real-ip.conf"
