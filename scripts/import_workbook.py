#!/usr/bin/env python3
"""Import data cells from the three plan tables; document prose is not executed."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import posixpath
import xml.etree.ElementTree as ET
import zipfile

NS = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
      'r': 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'}
MODES = {'time': 'duration', 'time_side': 'duration_per_side', 'reps': 'repetitions',
         'reps_side': 'repetitions_per_side', 'reps_total': 'repetitions_total'}
UNITS = {'time': 'сек', 'time_side': 'сек/сторона', 'reps': 'повт',
         'reps_side': 'повт/сторона', 'reps_total': 'повт всего'}
# Only movement matches. Different or absent variants retain workbook instructions.
PHOTOS = {
    **{code: {'asset': 'technique_coded.jpg', 'columns': 3, 'rows': 3, 'index': index}
       for index, code in enumerate(['W01', 'W02', 'W03', 'W04', 'C01', 'C02', 'C03', 'S01', 'S02'])},
    **{code: {'asset': 'technique_numbered.jpg', 'columns': 8, 'rows': 6, 'index': number - 1}
       for code, number in {'S03': 11, 'S04': 12, 'S06': 7, 'S09': 9, 'L01': 18,
           'L03': 14, 'L04': 13, 'L05': 25, 'L06': 22, 'L07': 16, 'K01': 31,
           'K03': 28, 'K04': 29, 'K05': 27, 'K06': 35, 'K07': 36, 'A02': 38}.items()},
}

def table_cells(path):
    with zipfile.ZipFile(path) as archive:
        workbook = ET.fromstring(archive.read('xl/workbook.xml'))
        rels = ET.fromstring(archive.read('xl/_rels/workbook.xml.rels'))
        targets = {r.attrib['Id']: r.attrib['Target'] for r in rels}
        strings = []
        if 'xl/sharedStrings.xml' in archive.namelist():
            strings = [''.join(s.itertext()) for s in ET.fromstring(archive.read('xl/sharedStrings.xml'))]
        result = {}
        for sheet in workbook.find('m:sheets', NS):
            name = sheet.attrib['name']
            if name not in {'Exercises', 'Schedule', 'Workout_Items'}:
                continue
            target = targets[sheet.attrib['{' + NS['r'] + '}id']]
            file = target.lstrip('/') if target.startswith('/') else posixpath.normpath('xl/' + target)
            rows = []
            for row in ET.fromstring(archive.read(file)).findall('m:sheetData/m:row', NS):
                cells = {}
                for cell in row:
                    column = ''.join(c for c in cell.attrib['r'] if c.isalpha())
                    index = 0
                    for char in column: index = index * 26 + ord(char) - 64
                    raw = cell.find('m:v', NS)
                    kind = cell.attrib.get('t')
                    if kind == 'inlineStr': value = ''.join(t.text or '' for t in cell.findall('.//m:t', NS))
                    elif raw is None: value = None
                    elif kind == 's': value = strings[int(raw.text)]
                    elif kind == 'b': value = raw.text == '1'
                    elif kind in ('str', 'd'): value = raw.text
                    else:
                        number = float(raw.text); value = int(number) if number.is_integer() else number
                    cells[index - 1] = value
                if cells: rows.append([cells.get(i) for i in range(max(cells) + 1)])
            headers = rows[0]
            result[name] = [dict(zip(headers, row + [None] * (len(headers) - len(row)))) for row in rows[1:]]
        if set(result) != {'Exercises', 'Schedule', 'Workout_Items'}:
            raise ValueError('Missing source data tables')
        return result

def convert(path, legacy_catalog):
    source = table_cells(path)
    exercises = source['Exercises']; schedule = source['Schedule']; items = source['Workout_Items']
    by_code = {e['exercise_id']: e for e in exercises}
    assert len(by_code) == len(exercises), 'Duplicate exercise codes'
    by_workout = {}
    for item in items:
        assert item['exercise_id'] in by_code, 'Unknown exercise'
        assert item['exercise_name'] == by_code[item['exercise_id']]['name_ru'], 'Exercise label mismatch'
        assert item['unit'] == UNITS[by_code[item['exercise_id']]['metric_type']], 'Metric/unit mismatch'
        assert isinstance(item['sets'], int) and 1 <= item['sets'] <= 100
        assert isinstance(item['target_per_set'], int) and item['target_per_set'] > 0
        assert isinstance(item['rest_seconds'], int) and 0 <= item['rest_seconds'] <= 3600
        by_workout.setdefault(item['workout_id'], []).append(item)
    assert len({i['item_id'] for i in items}) == len(items)
    assert len({d['date'] for d in schedule}) == len(schedule)
    schedule.sort(key=lambda d: d['date'])
    start = dt.date.fromisoformat(schedule[0]['date'])
    assert [d['date'] for d in schedule] == [(start + dt.timedelta(days=i)).isoformat() for i in range(len(schedule))]
    assert len(schedule) % 7 == 0
    sessions = []
    for offset, day in enumerate(schedule):
        assert day['week'] == offset // 7 + 1
        if day['status'] == 'rest':
            assert not day['workout_id']; continue
        assert day['status'] == 'training' and day['workout_id'] in by_workout
        rows = sorted(by_workout[day['workout_id']], key=lambda i: i['order'])
        assert [r['order'] for r in rows] == list(range(1, len(rows) + 1))
        assigned = []
        for row in rows:
            metric = by_code[row['exercise_id']]['metric_type']
            value = {'order': row['order'], 'exercise_id': row['exercise_id'], 'name': row['exercise_name'],
                     'stage': row['section'], 'mode': MODES[metric], 'sets': row['sets'],
                     'rest_seconds': row['rest_seconds'], 'unit': row['unit'], 'source_item_id': row['item_id'],
                     'optional': row['optional'] == 'Да'}
            value['target_seconds' if metric.startswith('time') else 'target_reps'] = row['target_per_set']
            if row['weight_guidance']: value['load'] = row['weight_guidance']
            if row['notes']: value['notes'] = row['notes']
            assigned.append(value)
        sessions.append({'session_id': day['workout_id'], 'week': day['week'], 'date': day['date'],
                         'day': day['weekday'], 'name': day['focus'], 'phase_id': 'phase_' + str(day['phase']), 'items': assigned})
    assert set(by_workout) == {s['session_id'] for s in sessions}
    catalog = []
    for old in legacy_catalog['exercises']:
        catalog.append(dict(old, retired=True))
    for e in exercises:
        catalog.append({'id': e['exercise_id'], 'title': e['name_ru'], 'primary_group': e['muscle_group'],
                        'equipment': [e['equipment']], 'description': e['technique'], 'instructions': [e['technique']],
                        'safety_flag': 'source', 'safety_note': e['safety_note'], 'metric_type': e['metric_type'], 'retired': False,
                        'media': {'status': 'photo' if e['exercise_id'] in PHOTOS else 'not_available',
                                  **({'photo': PHOTOS[e['exercise_id']]} if e['exercise_id'] in PHOTOS else {})}})
    assert len({e['id'] for e in catalog}) == len(catalog)
    plan = {'schema_version': '2.0.0', 'program_id': 'sportfit_12w_2026q4',
            'start_date': schedule[0]['date'], 'end_date': schedule[-1]['date'], 'duration_weeks': len(schedule) // 7,
            'session_count': len(sessions), 'exercise_count': len(exercises), 'description': 'SportFit — 12 недель',
            'derived_from': 'SportFit_12_weeks_Codex.xlsx / SHA-256 ' + hashlib.sha256(Path(path).read_bytes()).hexdigest(),
            'general_rules': {'dates': 'Даты шаблона определяют порядок дней; календарных сроков прохождения нет.',
                              'weights': 'Текст нагрузки — рекомендация из таблицы. Фактический вес записывается отдельно.'},
            'sessions': sessions}
    return {'schema_version': '1.0.0', 'exercise_count': len(catalog), 'exercises': catalog}, plan, source

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('xlsx', type=Path)
    parser.add_argument('--out', type=Path, default=Path('SportFit/Resources/Data'))
    parser.add_argument('--legacy', type=Path, default=Path('Tests/Fixtures/LegacyData/exercises.v1.json'))
    args = parser.parse_args()
    catalog, plan, source = convert(args.xlsx, json.loads(args.legacy.read_text()))
    args.out.mkdir(parents=True, exist_ok=True)
    for name, data in [('exercises.v1.json', catalog), ('program_12w.v1.json', plan), ('program_12w_with_sets.v2.json', plan)]:
        (args.out / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    print(f"Converted {len(source['Exercises'])} current exercises, {len(plan['sessions'])} workouts, {sum(len(s['items']) for s in plan['sessions'])} assignments")

if __name__ == '__main__': main()
