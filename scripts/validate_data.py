#!/usr/bin/env python3
"""Validate the new shipped plan and references; never infer exercise prescriptions."""
from pathlib import Path
import json
from datetime import date, timedelta

BASE = Path(__file__).resolve().parents[1] / 'SportFit/Resources/Data'

def validate(catalog, plan):
    ids = [e['id'] for e in catalog['exercises']]
    active = {e['id'] for e in catalog['exercises'] if not e.get('retired')}
    assert catalog['schema_version'] == '1.0.0'
    assert catalog['exercise_count'] == len(ids) == len(set(ids))
    assert len(active) == 36
    assert plan['program_id'] == 'sportfit_12w_2026q4' and plan['schema_version'] == '2.0.0'
    assert plan['exercise_count'] == 36 and plan['session_count'] == len(plan['sessions']) == 48
    assert sum(len(s['items']) for s in plan['sessions']) == 624
    start = date.fromisoformat(plan['start_date']); end = date.fromisoformat(plan['end_date'])
    assert (end - start).days == plan['duration_weeks'] * 7 - 1 == 83
    assert len({s['session_id'] for s in plan['sessions']}) == len({s['date'] for s in plan['sessions']}) == 48
    item_ids = []
    for session in plan['sessions']:
        when = date.fromisoformat(session['date']); assert start <= when <= end
        assert session['week'] == (when - start).days // 7 + 1
        assert session['day'] == ['Пн','Вт','Ср','Чт','Пт','Сб','Вс'][when.weekday()]
        assert [i['order'] for i in session['items']] == list(range(1, len(session['items']) + 1))
        for item in session['items']:
            assert item['exercise_id'] in active
            assert item['stage'] in ['warmup','main','cooldown']
            assert 1 <= item['sets'] <= 100 and 0 <= item['rest_seconds'] <= 3600
            mode = item['mode']
            if mode in ['duration','duration_per_side']:
                assert 1 <= item['target_seconds'] <= 3600 and 'target_reps' not in item
            else:
                assert mode in ['repetitions','repetitions_per_side','repetitions_total']
                assert 1 <= item['target_reps'] <= 300 and 'target_seconds' not in item
            item_ids.append(item['source_item_id'])
    assert len(item_ids) == len(set(item_ids))
    for entry in catalog['exercises']:
        photo = entry.get('media', {}).get('photo')
        if photo:
            assert '/' not in photo['asset'] and '..' not in photo['asset']
            assert 0 <= photo['index'] < photo['rows'] * photo['columns']
    return active

if __name__ == '__main__':
    library = json.loads((BASE/'exercises.v1.json').read_text())
    plan = json.loads((BASE/'program_12w_with_sets.v2.json').read_text())
    validate(library, plan)
    assert json.loads((BASE/'program_12w.v1.json').read_text()) == plan
    print('OK: 36 current exercises, 48 workouts, 624 exact assignments, old selectable plan removed')
