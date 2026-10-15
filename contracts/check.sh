#!/usr/bin/env bash
# contracts/check.sh — validates everything under contracts/. Runs in CI and
# locally from the repository root: ./contracts/check.sh
#
#   (a) every .proto under contracts/proto compiles (python grpc_tools.protoc)
#   (b) the OpenAPI document validates (openapi-spec-validator)
#   (c) contracts/reasons.yaml loads and its reason names match the
#       LifecycleReason enum in session.proto exactly (both directions)
#   (d) prints OK
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROTO_DIR=contracts/proto
OPENAPI=contracts/openapi/steward-v1.yaml
REASONS=contracts/reasons.yaml
SESSION_PROTO=contracts/proto/steward/plane/v1/session.proto
OUT=/tmp/steward-proto-check

# ---- (a) protobuf --------------------------------------------------------
echo "[contracts] compiling protos"
rm -rf "$OUT"
mkdir -p "$OUT"
mapfile -t PROTOS < <(find "$PROTO_DIR" -name '*.proto' | sort)
if [ "${#PROTOS[@]}" -eq 0 ]; then
  echo "no .proto files under $PROTO_DIR" >&2
  exit 1
fi
python3 -m grpc_tools.protoc -I "$PROTO_DIR" \
  --python_out="$OUT" --grpc_python_out="$OUT" "${PROTOS[@]}"
for p in "${PROTOS[@]}"; do echo "  ok  $p"; done

# ---- (b) OpenAPI ---------------------------------------------------------
echo "[contracts] validating $OPENAPI"
python3 -c "from openapi_spec_validator import validate; import yaml; validate(yaml.safe_load(open('$OPENAPI')))"
echo "  ok  $OPENAPI"

# ---- (c) reasons.yaml <-> LifecycleReason --------------------------------
echo "[contracts] checking $REASONS against LifecycleReason in $SESSION_PROTO"
python3 - "$REASONS" "$SESSION_PROTO" "$OPENAPI" <<'PY'
import re, sys, yaml

reasons_path, proto_path, openapi_path = sys.argv[1:4]

doc = yaml.safe_load(open(reasons_path))
for key in ("reasons", "events", "sqlstates"):
    if not isinstance(doc.get(key), list) or not doc[key]:
        sys.exit(f"{reasons_path}: missing or empty '{key}' list")

yaml_names = []
for r in doc["reasons"]:
    for field in ("name", "description", "terminal", "states_from"):
        if field not in r:
            sys.exit(f"{reasons_path}: reason {r.get('name')!r} lacks '{field}'")
    if not isinstance(r["terminal"], bool):
        sys.exit(f"{reasons_path}: reason {r['name']!r}: terminal must be bool")
    yaml_names.append(r["name"])
if len(set(yaml_names)) != len(yaml_names):
    sys.exit(f"{reasons_path}: duplicate reason names")

src = open(proto_path).read()
m = re.search(r"enum\s+LifecycleReason\s*\{(.*?)\}", src, re.S)
if not m:
    sys.exit(f"{proto_path}: enum LifecycleReason not found")
proto_names = []
for line in m.group(1).splitlines():
    line = line.split("//", 1)[0].strip()
    mm = re.match(r"LIFECYCLE_REASON_([A-Z0-9_]+)\s*=\s*(\d+)\s*;", line)
    if mm and mm.group(1) != "UNSPECIFIED":
        proto_names.append(mm.group(1).lower())
    elif line and not line.startswith("LIFECYCLE_REASON_UNSPECIFIED"):
        sys.exit(f"{proto_path}: unexpected line in LifecycleReason: {line!r}")

missing_in_proto = sorted(set(yaml_names) - set(proto_names))
missing_in_yaml = sorted(set(proto_names) - set(yaml_names))
if missing_in_proto or missing_in_yaml:
    if missing_in_proto:
        print(f"  reasons in {reasons_path} but not in LifecycleReason: {missing_in_proto}", file=sys.stderr)
    if missing_in_yaml:
        print(f"  values in LifecycleReason but not in {reasons_path}: {missing_in_yaml}", file=sys.stderr)
    sys.exit(1)

# The OpenAPI LifecycleReason and EventType enums must match reasons.yaml too.
api = yaml.safe_load(open(openapi_path))
schemas = api["components"]["schemas"]
api_reasons = schemas["LifecycleReason"]["enum"]
if sorted(api_reasons) != sorted(yaml_names):
    sys.exit(f"{openapi_path}: LifecycleReason enum differs from {reasons_path}: "
             f"{sorted(set(api_reasons) ^ set(yaml_names))}")
api_events = schemas["EventType"]["enum"]
if sorted(api_events) != sorted(doc["events"]):
    sys.exit(f"{openapi_path}: EventType enum differs from {reasons_path}: "
             f"{sorted(set(api_events) ^ set(doc['events']))}")

codes = [s["code"] for s in doc["sqlstates"]]
if any(not re.fullmatch(r"SD00[0-9A-F]", c) for c in codes) or len(set(codes)) != len(codes):
    sys.exit(f"{reasons_path}: bad or duplicate SQLSTATE codes: {codes}")

print(f"  ok  {len(yaml_names)} reasons, {len(doc['events'])} events, {len(codes)} sqlstates")
PY

# ---- (d) ----------------------------------------------------------------
echo "OK"
