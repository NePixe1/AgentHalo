#!/usr/bin/env python3
"""Validate the shared contract with its checked-in JSON Schema."""

import json
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "src" / "shared" / "spec" / "agent-halo.v2.json"
SCHEMA = ROOT / "src" / "shared" / "spec" / "agent-halo.v2.schema.json"

schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
document = json.loads(SPEC.read_text(encoding="utf-8"))
Draft202012Validator.check_schema(schema)
Draft202012Validator(schema).validate(document)
print("PASS shared contract JSON Schema")
