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

# Keep dated assignments exactly as supplied, including unload weeks and per-side units.
from datetime import date
v2 = json.loads((base / 'program_12w_with_sets.v2.json').read_text(encoding='utf-8'))
assert v2['schema_version'] == '2.0.0'
sessions = v2['sessions']
assert v2['session_count'] == len(sessions) == 48
assert len({s['date'] for s in sessions}) == 48
assert len({s['session_id'] for s in sessions}) == 48
for session in sessions:
    when = date.fromisoformat(session['date'])
    assert date.fromisoformat(v2['start_date']) <= when <= date.fromisoformat(v2['end_date'])
    assert session['week'] == (when - date.fromisoformat(v2['start_date'])).days // 7 + 1
    assert session['day'] == ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'][when.weekday()]
    assert [i['order'] for i in session['items']] == list(range(1, len(session['items']) + 1))
    for item in session['items']:
        assert item['exercise_id'] in ids
        assert 1 <= item['sets'] <= 100 and 0 <= item['rest_seconds'] <= 3600
        assert item['mode'] in {'duration', 'repetitions', 'repetitions_per_side', 'breath_cycles'}
        assert 1 <= item['target_seconds' if item['mode'] == 'duration' else 'target_reps'] <= (3600 if item['mode'] == 'duration' else 300)
print(f"OK: v2, {len(sessions)} dated sessions, {sum(len(s['items']) for s in sessions)} precise assignments")
