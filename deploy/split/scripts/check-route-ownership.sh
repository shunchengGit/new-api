#!/bin/sh
# Statically review root Gin route groups before changing split proxy ownership.
set -eu

fail() { printf '%s\n' "check-route-ownership: $*" >&2; exit 1; }
root=${1:-}
if [ -z "$root" ]; then
  root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
fi
router_dir=$root/router
contract=$root/deploy/split/nginx/route-contract.inc.template
[ -d "$router_dir" ] || fail "router directory not found: $router_dir"
[ -f "$contract" ] || fail "shared route contract not found: $contract"
command -v python3 >/dev/null 2>&1 || fail "requires python3 for conservative Go source analysis"

python3 - "$router_dir" "$contract" <<'PY'
import pathlib, re, sys
router = pathlib.Path(sys.argv[1])
contract = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
# Public paths deliberately owned by the backend rather than the frontend.
approved = ('/api', '/v1', '/v1beta', '/mj', '/pg', '/suno', '/kling', '/jimeng', 'jimeng')
# These deliberate root exceptions are part of the relay contract. Keep this list
# narrow: any new exception must have a corresponding proxy route-contract case.
exceptions = ('/', '/:mode/mj')
# Dynamic root registrations are forbidden unless their exact source location is listed here.
approved_dynamic = frozenset()
# A root group is allowed only for this legacy dashboard compatibility adapter.
root_group_files = {'dashboard.go'}
root_group_routes = frozenset({
    '/dashboard/billing/subscription',
    '/dashboard/billing/usage',
    '/v1/dashboard/billing/subscription',
    '/v1/dashboard/billing/usage',
})
root_group_route = re.compile(r'\b\w+\.(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|Any)\(\s*"([^"]+)"')

def matches_namespace(value):
    return any(value == namespace or value.startswith(namespace + '/') for namespace in approved)
required_contract = (
    'location = /api {', 'location ^~ /api/ {',
    'location = /v1 {', 'location ^~ /v1/ {',
    'location = /v1beta {', 'location ^~ /v1beta/ {',
    'location = /pg {', 'location ^~ /pg/ {',
    'location = /mj {', 'location ^~ /mj/ {',
    'location = /suno {', 'location ^~ /suno/ {',
    'location = /kling {', 'location ^~ /kling/ {',
    'location = /jimeng {', 'location ^~ /jimeng/ {',
    'location ~ ^/(?:v1/)?dashboard/billing/(?:subscription|usage)/?$',
    'location ~ ^/[^/]+/mj/(?:image|submit|task|insight-face)(?:/|$)',
    'location ^~ /assets/', 'location ^~ /static/', 'try_files $uri $uri/ /index.html =404;',
)
problems = [f'shared route contract is missing {item!r}' for item in required_contract if item not in contract]
for path in sorted(router.glob('*.go')):
    text = path.read_text(encoding='utf-8')
    if 'router.Group("/")' in text and path.name in root_group_files:
        for route in root_group_route.findall(text):
            if route not in root_group_routes:
                problems.append(f'{path.name}: legacy root group route {route!r} is not an approved compatibility route')
    elif 'router.Group("/")' in text:
        problems.append(f'{path.name}: unapproved root group requires explicit review')
# Remaining root groups are inspected conservatively: literal declarations are enforceable;
# computed values fail unless their source location is explicitly allowlisted above.
group = re.compile(r'\b(?:\w+\s*:=\s*)?(\w+)\s*:=\s*router\.Group\(\s*([^,)]+)')
for path in sorted(router.glob('*.go')):
    text = path.read_text(encoding='utf-8')
    for match in group.finditer(text):
        line = text[:match.start()].count('\n') + 1
        literal = match.group(2).strip()
        if literal.startswith('"') and literal.endswith('"'):
            value = literal[1:-1]
            if value == '/' and path.name in root_group_files:
                continue
            if not matches_namespace(value) and value not in exceptions:
                problems.append(f'{path.name}:{line}: root group {value!r} is outside approved backend namespaces')
        elif f'{path.name}:{line}' not in approved_dynamic:
            problems.append(f'{path.name}:{line}: dynamic router.Group({literal}) is not explicitly allowlisted')
# Direct Engine route registrations can bypass groups.
direct = re.compile(r'\brouter\.(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|Any|Handle)\(\s*([^,)]+)')
for path in sorted(router.glob('*.go')):
    text = path.read_text(encoding='utf-8')
    for match in direct.finditer(text):
        arg = match.group(1).strip()
        line = text[:match.start()].count('\n') + 1
        if not (arg.startswith('"') and arg.endswith('"')):
            if f'{path.name}:{line}' not in approved_dynamic:
                problems.append(f'{path.name}:{line}: dynamic direct router registration {arg} is not explicitly allowlisted')
            continue
        value = arg[1:-1]
        if not matches_namespace(value):
            problems.append(f'{path.name}:{line}: direct root route {value!r} is outside approved backend namespaces')
if problems:
    print('check-route-ownership: FAILED:', file=sys.stderr)
    print(*problems, sep='\n', file=sys.stderr)
    print('Move the route beneath an approved namespace or add a deliberate, documented exception to this script and shared route contract.', file=sys.stderr)
    raise SystemExit(1)
print('check-route-ownership: root backend routes match the shared contract')
print('check-route-ownership: no unallowlisted dynamic root registrations found')
PY
