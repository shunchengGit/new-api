#!/bin/sh
set -eu

compose_file=${1:?rendered Compose YAML path is required}
fail() { printf '%s\n' "verify-compose-images: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "requires python3"
[ ! -L "$compose_file" ] || fail "Compose file must not be a symbolic link"
[ -f "$compose_file" ] || fail "missing Compose file: $compose_file"

python3 - "$compose_file" <<'PY'
import re
import sys

path = sys.argv[1]
services = {"frontend", "backend", "database", "redis"}
images = {}
current = None
in_services = False
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.rstrip("\n")
        if line == "services:":
            in_services = True
            current = None
            continue
        if not in_services:
            continue
        match = re.fullmatch(r"  ([A-Za-z0-9_-]+):", line)
        if match:
            current = match.group(1)
            continue
        if line and not line.startswith(" "):
            break
        match = re.fullmatch(r"    image: (.+)", line)
        if match and current in services:
            images[current] = match.group(1).strip().strip("'\"")

missing = sorted(services - images.keys())
if missing:
    raise SystemExit(f"verify-compose-images: missing image for services: {', '.join(missing)}")
pattern = re.compile(r"^[^\s@]+@sha256:[0-9a-fA-F]{64}$")
invalid = [f"{service}={images[service]}" for service in sorted(services) if not pattern.fullmatch(images[service])]
if invalid:
    raise SystemExit("verify-compose-images: images must use immutable name@sha256:digest references: " + ", ".join(invalid))
print("verify-compose-images: PASS")
PY
