#!/bin/sh
# Statically review root Gin route groups before changing split proxy ownership.
set -eu

fail() { printf '%s\n' "check-route-ownership: $*" >&2; exit 1; }
root=${1:-}
if [ -z "$root" ]; then
  root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
fi
router_dir=$root/router
[ -d "$router_dir" ] || fail "router directory not found: $router_dir"
command -v python3 >/dev/null 2>&1 || fail "requires python3 for conservative Go source analysis"

python3 - "$router_dir" <<'PY'
import pathlib, re, sys
router = pathlib.Path(sys.argv[1])
# Public paths deliberately owned by the backend rather than the frontend.
approved = ('/api', '/v1', '/v1beta', '/mj', '/pg', '/suno', '/kling', '/jimeng', 'jimeng')
# These deliberate root exceptions are part of the relay contract. Keep this list
# narrow: any new exception must have a corresponding proxy route-contract case.
exceptions = ('/', '/:mode/mj')
# A root group is allowed only for this legacy dashboard compatibility adapter.
root_group_files = {'dashboard.go'}
root_group_routes = ('/dashboard/billing/', '/v1/dashboard/billing/')
root_group_route = re.compile(r'\b\w+\.(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|Any)\(\s*"([^"]+)"')
problems, dynamic = [], []
for path in sorted(router.glob('*.go')):
    text = path.read_text(encoding='utf-8')
    if 'router.Group("/")' in text and path.name in root_group_files:
        for route in root_group_route.findall(text):
            if not route.startswith(root_group_routes):
                problems.append(f'{path.name}: legacy root group route {route!r} is not an approved compatibility route')
    elif 'router.Group("/")' in text:
        problems.append(f'{path.name}: unapproved root group requires explicit review')
# Remaining root groups are inspected conservatively: literal declarations are enforceable;
# computed values require review because static source cannot prove their values.
group = re.compile(r'\b(?:\w+\s*:=\s*)?(\w+)\s*:=\s*router\.Group\(\s*([^,)]+)')
root_group_pattern = re.compile(r'router\.Group\(\s*"/"\s*\)')
root_group_counted = False
for path in sorted(router.glob('*.go')):
    text = path.read_text(encoding='utf-8')
    for line, match in enumerate(group.finditer(text), 1):
        literal = match.group(2).strip()
        if literal.startswith('"') and literal.endswith('"'):
            value = literal[1:-1]
            if value == '/' and path.name in root_group_files:
                continue
            if not value.startswith(approved) and value not in exceptions:
                problems.append(f'{path.name}:{text[:match.start()].count(chr(10))+1}: root group {value!r} is outside approved backend namespaces')
        else:
            dynamic.append(f'{path.name}:{text[:match.start()].count(chr(10))+1}: router.Group({literal}) is dynamic; manually verify proxy ownership')
# Direct Engine route registrations can bypass groups.
direct = re.compile(r'\brouter\.(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|Any|Handle)\(\s*([^,)]+)')
for path in sorted(router.glob('*.go')):
    text = path.read_text(encoding='utf-8')
    for match in direct.finditer(text):
        arg = match.group(1).strip()
        line = text[:match.start()].count('\n') + 1
        if not (arg.startswith('"') and arg.endswith('"')):
            dynamic.append(f'{path.name}:{line}: direct router registration with dynamic path {arg}; manually verify ownership')
            continue
        value = arg[1:-1]
        if not value.startswith(approved):
            problems.append(f'{path.name}:{line}: direct root route {value!r} is outside approved backend namespaces')
if dynamic:
    print('check-route-ownership: REVIEW HINTS (dynamic registration is not proof of safety):', file=sys.stderr)
    print(*dynamic, sep='\n', file=sys.stderr)
if problems:
    print('check-route-ownership: FAILED:', file=sys.stderr)
    print(*problems, sep='\n', file=sys.stderr)
    print('Move the route beneath an approved namespace or add a deliberate, documented exception to this script.', file=sys.stderr)
    raise SystemExit(1)
print('check-route-ownership: literal root backend groups use approved namespaces')
if not dynamic:
    print('check-route-ownership: no dynamic root registrations found')
PY
