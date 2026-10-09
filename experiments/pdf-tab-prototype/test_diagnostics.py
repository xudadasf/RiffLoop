"""Keep error categories distinct; pairing uncertainty never erases samples."""
import copy
import json
import tempfile
import unittest
from pathlib import Path

from diagnostics import diagnose,failure_reason,write_report


def bar():
    return {'number':1,'meter':[4,4],'meter_source':'pdf','issues':[],
            'beats':[{'duration':1,'dots':0,'tuplet':[1,1],'grace':False,
                      'notes':[{'string':1,'fret':7,'dead':False,'tie':False}]}]}


class DiagnosticTests(unittest.TestCase):
    def test_uncertain_pair_and_read_failure_remain_visible(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);rows=[]
            for i,group in enumerate(('consistent','uncertain')):
                folder=root/f'case-{i:03}';folder.mkdir()
                original=bar()
                if i:original['beats'][0]['notes'][0]['fret']=8
                reference={'tracks':[{'name':'Guitar','tuning':[64,59,55,50,45,40],'bars':[original]}]}
                for name,data in [('recognized.json',{'systems':[{'bars':[bar()]}]}),('reference.json',reference)]:
                    (folder/name).write_text(json.dumps(data),encoding='utf-8')
                rows.append({'case':folder.name,'pdf':'<score>.pdf','status':'evaluated','track':'Guitar',
                             'pairing_checks':{'status':group},'metrics':{'core_exact_bars':1-i}})
            rows.append({'case':'case-002','status':'error'})
            (root/'results.json').write_text(json.dumps(rows),encoding='utf-8')
            result=diagnose(root);write_report(result,root)
            self.assertEqual(result['candidate_count'],3)
            self.assertEqual(result['statuses']['error'],1)
            self.assertEqual(result['groups']['consistent']['counts']['pass'],1)
            self.assertEqual(result['groups']['uncertain']['counts']['notes'],1)
            self.assertEqual(len(result['cases']),2)
            self.assertIn('&lt;score&gt;.pdf',(root/'diagnostics.html').read_text(encoding='utf-8'))
            baseline=root/'baseline';baseline.mkdir()
            (baseline/'results.json').write_text(json.dumps(rows),encoding='utf-8')
            rows[1]['pairing_checks']['status']='consistent'
            (root/'results.json').write_text(json.dumps(rows),encoding='utf-8')
            fixed=diagnose(root,baseline)
            self.assertEqual(fixed['groups']['uncertain']['cases'],1)
            self.assertEqual(fixed['cases'][1]['current_pairing_status'],'consistent')
            rows[1]['pdf']='different.pdf'
            (root/'results.json').write_text(json.dumps(rows),encoding='utf-8')
            with self.assertRaises(ValueError):diagnose(root,baseline)

    def test_first_differing_layer(self):
        reference=bar()
        self.assertEqual(failure_reason(None,reference),'missing_bar')
        self.assertEqual(failure_reason(bar(),reference),'pass')
        for expected,change in [
            ('meter',lambda b:b.update(meter_source='assumed-4/4')),
            ('unknown_duration',lambda b:b['beats'][0].update(duration=None)),
            ('notes',lambda b:b['beats'][0]['notes'][0].update(fret=8)),
            ('rhythm_rests',lambda b:b['beats'][0].update(duration=2)),
            ('ties_only',lambda b:b['beats'][0]['notes'][0].update(tie=True)),
            ('validation',lambda b:b['issues'].append('blocked')),
        ]:
            with self.subTest(reason=expected):
                actual=bar();change(actual)
                self.assertEqual(failure_reason(actual,reference),expected)

    def test_rest_sequence_matters_even_when_total_duration_matches(self):
        reference=bar();reference['beats'][0]['duration']=2
        rest=copy.deepcopy(reference['beats'][0]);rest['notes']=[]
        reference['beats'].append(rest)
        self.assertEqual(failure_reason(bar(),reference),'rhythm_rests')

    def test_secondary_voice_notes_cannot_pass_primary_voice_comparison(self):
        reference=bar();extra=copy.deepcopy(reference['beats'][0]);extra['voice']=1
        reference['beats'].append(extra)
        self.assertEqual(failure_reason(bar(),reference),'multiple_voices')
        extra['notes']=[]
        self.assertEqual(failure_reason(bar(),reference),'pass')


if __name__=='__main__':unittest.main()
