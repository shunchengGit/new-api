#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
split=$(CDPATH= cd -- "$here/.." && pwd)
template_dir=${NGINX_TEMPLATE_DIR:-$split/nginx}
config_dir=${HOST_NGINX_CONFIG_DIR:?HOST_NGINX_CONFIG_DIR is required}

case $template_dir in
  /*) ;;
  *) echo 'NGINX_TEMPLATE_DIR must be an absolute path' >&2; exit 1 ;;
esac
case $template_dir in *[!A-Za-z0-9._/-]* | *'//'*) echo 'invalid NGINX_TEMPLATE_DIR' >&2; exit 1 ;; esac
case $config_dir in
  /*) ;;
  *) echo 'HOST_NGINX_CONFIG_DIR must be an absolute path' >&2; exit 1 ;;
esac
case $config_dir in *[!A-Za-z0-9._/-]* | *'//'*) echo 'invalid HOST_NGINX_CONFIG_DIR' >&2; exit 1 ;; esac

: "${PUBLIC_HOST:?PUBLIC_HOST is required}"
: "${EXTERNAL_SCHEME:?EXTERNAL_SCHEME is required}"
: "${STATIC_RELEASE_ROOT:?STATIC_RELEASE_ROOT is required}"
: "${BACKEND_ENDPOINT:?BACKEND_ENDPOINT is required}"
: "${CLIENT_MAX_BODY_SIZE:=128m}"
: "${HOST_REAL_IP_INCLUDE:?HOST_REAL_IP_INCLUDE is required}"
: "${DEPLOYMENT_CHALLENGE:?DEPLOYMENT_CHALLENGE is required}"

case $PUBLIC_HOST in
  *[!A-Za-z0-9.-]* | '' | .* | *..* | *.) echo 'invalid PUBLIC_HOST' >&2; exit 1 ;;
esac
case $EXTERNAL_SCHEME in http|https) ;; *) echo 'EXTERNAL_SCHEME must be http or https' >&2; exit 1 ;; esac
case $STATIC_RELEASE_ROOT in
  /*) ;;
  *) echo 'STATIC_RELEASE_ROOT must be an absolute path' >&2; exit 1 ;;
esac
case $STATIC_RELEASE_ROOT in *[!A-Za-z0-9._/-]* | *'//'*) echo 'invalid STATIC_RELEASE_ROOT' >&2; exit 1 ;; esac
case $BACKEND_ENDPOINT in
  http://*|https://*) ;;
  *) echo 'BACKEND_ENDPOINT must be an http or https endpoint' >&2; exit 1 ;;
esac
backend_authority=${BACKEND_ENDPOINT#*://}
case $backend_authority in *[!A-Za-z0-9.:-]* | '' | *..* | :* | *:) echo 'invalid BACKEND_ENDPOINT' >&2; exit 1 ;; esac
backend_host=${backend_authority%:*}
backend_port=${backend_authority##*:}
[ "$backend_host" != "$backend_authority" ] || { echo 'BACKEND_ENDPOINT must include an explicit port' >&2; exit 1; }
case $backend_port in *[!0-9]*|'') echo 'invalid BACKEND_ENDPOINT port' >&2; exit 1 ;; esac
[ "$backend_port" -ge 1 ] && [ "$backend_port" -le 65535 ] || { echo 'BACKEND_ENDPOINT port must be between 1 and 65535' >&2; exit 1; }
if [ "$backend_host" != localhost ]; then
  old_ifs=$IFS
  IFS=.
  set -- $backend_host
  IFS=$old_ifs
  [ "$#" -eq 4 ] || { echo 'BACKEND_ENDPOINT must use localhost or a loopback/RFC1918 IPv4 address' >&2; exit 1; }
  for octet in "$@"; do
    case $octet in *[!0-9]*|'') echo 'invalid BACKEND_ENDPOINT IPv4 address' >&2; exit 1 ;; esac
    [ "$octet" -le 255 ] || { echo 'invalid BACKEND_ENDPOINT IPv4 address' >&2; exit 1; }
  done
  first_octet=$1
  second_octet=$2
  case $first_octet in
    10|127) ;;
    192) [ "$second_octet" -eq 168 ] || { echo 'BACKEND_ENDPOINT must use a loopback or RFC1918 IPv4 address' >&2; exit 1; } ;;
    172) [ "$second_octet" -ge 16 ] && [ "$second_octet" -le 31 ] || { echo 'BACKEND_ENDPOINT must use a loopback or RFC1918 IPv4 address' >&2; exit 1; } ;;
    *) echo 'BACKEND_ENDPOINT must use a loopback or RFC1918 IPv4 address' >&2; exit 1 ;;
  esac
fi
case $DEPLOYMENT_CHALLENGE in *[!0-9A-Fa-f]*|'') echo 'DEPLOYMENT_CHALLENGE must be 64 hexadecimal characters' >&2; exit 1 ;; esac
[ "${#DEPLOYMENT_CHALLENGE}" -eq 64 ] || { echo 'DEPLOYMENT_CHALLENGE must be 64 hexadecimal characters' >&2; exit 1; }
case $CLIENT_MAX_BODY_SIZE in *[!0-9kKmMgG]* | '') echo 'invalid CLIENT_MAX_BODY_SIZE' >&2; exit 1 ;; esac
case $HOST_REAL_IP_INCLUDE in
  /*) ;;
  *) echo 'HOST_REAL_IP_INCLUDE must be an absolute path' >&2; exit 1 ;;
esac
case $HOST_REAL_IP_INCLUDE in *[!A-Za-z0-9._/-]* | *'//'*) echo 'invalid HOST_REAL_IP_INCLUDE' >&2; exit 1 ;; esac

[ -d "$template_dir" ] || { echo "missing $template_dir" >&2; exit 1; }
[ -f "$template_dir/host-nginx.conf.template" ] || { echo "missing host Nginx template" >&2; exit 1; }
[ -f "$template_dir/host-http-prerequisites.conf" ] || { echo "missing host HTTP prerequisites" >&2; exit 1; }
[ -f "$template_dir/backend-proxy.inc.template" ] || { echo "missing backend proxy template" >&2; exit 1; }
[ -f "$template_dir/route-contract.inc.template" ] || { echo "missing route contract template" >&2; exit 1; }
[ -f "$STATIC_RELEASE_ROOT/index.html" ] || { echo "missing $STATIC_RELEASE_ROOT/index.html" >&2; exit 1; }
[ -f "$HOST_REAL_IP_INCLUDE" ] || { echo "missing $HOST_REAL_IP_INCLUDE" >&2; exit 1; }

[ ! -e "$config_dir" ] || { echo "HOST_NGINX_CONFIG_DIR must not already exist: $config_dir" >&2; exit 1; }
config_parent=$(dirname "$config_dir")
config_name=$(basename "$config_dir")
[ -d "$config_parent" ] || { echo "missing HOST_NGINX_CONFIG_DIR parent: $config_parent" >&2; exit 1; }
lock_dir=$config_parent/.${config_name}.render-lock
mkdir "$lock_dir" 2>/dev/null || { echo "another renderer owns $lock_dir" >&2; exit 1; }
[ ! -e "$config_dir" ] || { rmdir "$lock_dir"; echo "HOST_NGINX_CONFIG_DIR must not already exist: $config_dir" >&2; exit 1; }
staging_dir=
cleanup_staging() { [ -z "$staging_dir" ] || rm -rf "$staging_dir"; rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup_staging EXIT HUP INT TERM
staging_dir=$(mktemp -d "$config_parent/.${config_name}.XXXXXX")

render_template() {
  input=$1
  output=$2
  sed \
    -e "s|@PUBLIC_HOST@|$PUBLIC_HOST|g" \
    -e "s|@EXTERNAL_SCHEME@|$EXTERNAL_SCHEME|g" \
    -e "s|@STATIC_RELEASE_ROOT@|$STATIC_RELEASE_ROOT|g" \
    -e "s|@BACKEND_UPSTREAM@|$BACKEND_ENDPOINT|g" \
    -e "s|@CLIENT_MAX_BODY_SIZE@|$CLIENT_MAX_BODY_SIZE|g" \
    -e "s|@BACKEND_PROXY_INCLUDE@|$config_dir/backend-proxy.inc|g" \
    -e "s|@ROUTE_CONTRACT_INCLUDE@|$config_dir/route-contract.inc|g" \
    -e "s|@REAL_IP_INCLUDE@|$HOST_REAL_IP_INCLUDE|g" \
    -e "s|@DEPLOYMENT_CHALLENGE@|$DEPLOYMENT_CHALLENGE|g" \
    "$input" > "$output"
  chmod 0644 "$output"
}

render_template "$template_dir/host-nginx.conf.template" "$staging_dir/host-server.inc"
render_template "$template_dir/backend-proxy.inc.template" "$staging_dir/backend-proxy.inc"
render_template "$template_dir/route-contract.inc.template" "$staging_dir/route-contract.inc"
cp "$template_dir/host-http-prerequisites.conf" "$staging_dir/host-http-prerequisites.conf"
chmod 0644 "$staging_dir/host-http-prerequisites.conf"
chmod 0755 "$staging_dir"
mv "$staging_dir" "$config_dir"
rmdir "$lock_dir"
trap - EXIT HUP INT TERM
