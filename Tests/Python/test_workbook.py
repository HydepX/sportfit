import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT/'SportFit/Resources/Data'

class WorkbookPlanTests(unittest.TestCase):
    def setUp(self):
        self.source = json.loads((ROOT/'Tests/Fixtures/workbook_rows.json').read_text())
        self.catalog = json.loads((DATA/'exercises.v1.json').read_text())
        self.plan = json.loads((DATA/'program_12w_with_sets.v2.json').read_text())
    def test_all_624_assignments_match_source_cells(self):
        expected={r['item_id']:r for r in self.source['Workout_Items']}
        actual=[(s,i) for s in self.plan['sessions'] for i in s['items']]
        self.assertEqual(len(actual),624)
        for session,item in actual:
            row=expected.pop(item['source_item_id'])
            self.assertEqual((session['session_id'],session['week'],session['day']), (row['workout_id'],row['week'],row['weekday']))
            for key,source_key in [('order','order'),('exercise_id','exercise_id'),('name','exercise_name'),('sets','sets'),('unit','unit'),('rest_seconds','rest_seconds'),('stage','section')]:
                self.assertEqual(item[key],row[source_key])
            self.assertEqual(item.get('target_seconds',item.get('target_reps')),row['target_per_set'])
            self.assertEqual(item.get('load'),row['weight_guidance'])
            self.assertEqual(item.get('notes'),row['notes'])
        self.assertEqual(expected,{})
    def test_36_current_exercises_keep_names_and_instructions(self):
        current={e['id']:e for e in self.catalog['exercises'] if not e.get('retired')}
        self.assertEqual(len(current),36)
        for row in self.source['Exercises']:
            item=current[row['exercise_id']]
            self.assertEqual(item['title'],row['name_ru'])
            self.assertEqual(item['instructions'],[row['technique']])
            self.assertEqual(item['safety_note'],row['safety_note'])
            self.assertEqual(item['metric_type'],row['metric_type'])
    def test_schedule_keeps_48_training_days_and_36_rest_days(self):
        expected={r['date']:r for r in self.source['Schedule'] if r['status']=='training'}
        self.assertEqual(len(expected),48)
        self.assertEqual(len(self.source['Schedule'])-len(expected),36)
        for session in self.plan['sessions']:
            row=expected.pop(session['date']);self.assertEqual(session['name'],row['focus'])
            self.assertEqual(session['phase_id'],'phase_'+str(row['phase']))
        self.assertEqual(expected,{})
    def test_wrong_variants_are_not_substituted_as_photos(self):
        current={e['id']:e for e in self.catalog['exercises'] if not e.get('retired')}
        for code in ['S05','S07','S08','K02','K08','K09']:
            self.assertNotIn('photo',current[code]['media'])
        self.assertEqual(current['S02']['media']['photo']['asset'],'technique_coded.jpg')
    def test_no_old_default_plan_shipped(self):
        for name in ['program_12w.v1.json','program_12w_with_sets.v2.json']:
            p=json.loads((DATA/name).read_text());self.assertEqual(p['program_id'],'sportfit_12w_2026q4')
            self.assertFalse(any(i['exercise_id']=='press_floor' for s in p['sessions'] for i in s['items']))

if __name__=='__main__':unittest.main()
