#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
split=$(CDPATH= cd -- "$here/.." && pwd)
fail() { printf '%s\n' "verify-deployment-contract: FAIL: $*" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || fail "requires curl"
command -v python3 >/dev/null 2>&1 || fail "requires python3"

port=$((20000 + $$ % 20000))
base="http://127.0.0.1:$port"
revision=037710ec037710ec037710ec037710ec037710ec
FIXTURE_REVISION=$revision python3 "$here/verify-fixture.py" "$port" >"${TMPDIR:-/tmp}/verify-fixture-$$.log" 2>&1 &
pid=$!
cleanup() {
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  rm -f "${TMPDIR:-/tmp}/verify-fixture-$$.log"
}
trap cleanup EXIT HUP INT TERM

attempt=0
until curl --fail --silent --output /dev/null "$base/api/status"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 50 ] || fail "fixture did not become ready"
  sleep 0.05
done

PUBLIC_URL=$base EXPECTED_VERSION=v1.0.0-rc.21 EXPECTED_THEME=default EXPECTED_REVISION=$revision \
  "$split/scripts/verify-deployment.sh" >/dev/null

if PUBLIC_URL=$base EXPECTED_VERSION=wrong EXPECTED_THEME=default EXPECTED_REVISION=$revision \
  "$split/scripts/verify-deployment.sh" >/dev/null 2>&1; then
  fail "version mismatch passed"
fi
if PUBLIC_URL=$base EXPECTED_VERSION=v1.0.0-rc.21 EXPECTED_THEME=classic EXPECTED_REVISION=$revision \
  "$split/scripts/verify-deployment.sh" >/dev/null 2>&1; then
  fail "theme mismatch passed"
fi
if PUBLIC_URL=$base EXPECTED_VERSION=v1.0.0-rc.21 EXPECTED_THEME=default \
  EXPECTED_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$split/scripts/verify-deployment.sh" >/dev/null 2>&1; then
  fail "revision mismatch passed"
fi
if PUBLIC_URL=$base EXPECTED_VERSION=v1.0.0-rc.21 EXPECTED_THEME=default EXPECTED_REVISION=short \
  "$split/scripts/verify-deployment.sh" >/dev/null 2>&1; then
  fail "invalid expected revision passed"
fi

printf '%s\n' 'verify-deployment-contract: PASS'
