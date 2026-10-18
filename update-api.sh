#!/bin/sh
# Copies the API contract from the API repo; the client is generated from it at build time.
# swift-openapi-generator 1.10 skips `oneOf: [$ref, null]` (a nullable object); as an optional
# property a plain $ref means the same, so those are rewritten.
python3 - "$(dirname "$0")/../api/openapi.json" "$(dirname "$0")/Packages/AssistantAPI/Sources/AssistantAPI/openapi.json" <<'PY'
import json, sys
def fix(node):
    if isinstance(node, dict):
        one = node.get("oneOf")
        if isinstance(one, list) and len(one) == 2 and {"type": "null"} in one:
            ref = next(x for x in one if x != {"type": "null"})
            return fix(ref)
        return {k: fix(v) for k, v in node.items()}
    if isinstance(node, list):
        return [fix(x) for x in node]
    return node
spec = fix(json.load(open(sys.argv[1])))
json.dump(spec, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
