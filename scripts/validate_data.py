#!/usr/bin/env python3
"""Verify supplied Block 03 files if present. Does not fabricate exercises."""
import json
from pathlib import Path

base = Path("SportFit/Resources/Data")
exercise_file = base / "exercises.v1.json"
plan_file = base / "program_12w.v1.json"
if not exercise_file.exists() and not plan_file.exists():
    print("SOURCE DATA NOT YET COMMITTED: user can import both JSON files on iPhone.")
    raise SystemExit(0)
if not exercise_file.exists() or not plan_file.exists():
    raise SystemExit("Both Block 03 JSON files are required")
ex = json.loads(exercise_file.read_text(encoding="utf-8"))
plan = json.loads(plan_file.read_text(encoding="utf-8"))
ids = [x["id"] for x in ex["exercises"]]
assert ex["exercise_count"] == 53 and len(ids) == len(set(ids)) == 53
assert plan["duration_weeks"] == 12 and len(plan["phases"]) == 3
all_refs = {
    eid for phase in plan["phases"] for day in phase["days"]
    for eid in day["exercise_ids"]
}
assert all_refs <= set(ids), f"Unknown IDs: {all_refs - set(ids)}"
print(f"OK: {len(ids)} exercises, {len(all_refs)} referenced, 3 phases")
