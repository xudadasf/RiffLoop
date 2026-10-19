import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from regression import (AUDITS,compare_queues,export_case,find_regressions,problem_queue,
                        read,run_round,save)
from test_mixed_slides import mixed_fixture
from recognize import recognize


def snapshot():
    checks={'note_attacks':True,'note_releases':False,'end_tick':True}
    result={'cases':[{'case':'case-000','pdf':'a.pdf','status':'evaluated'},
                     {'case':'case-001','pdf':'b.pdf','status':'evaluated'}],
            'diagnostics':{'cases':[{'case':f'case-{i:03}','group':'consistent','bars':2,
                                    'differences':[{'bar':2,'reason':'notes'}],
                                    'rhythm_differences':[]} for i in range(2)]},
            'full_score_exports':[{'case':'case-000','checks':checks,'experimental':{'checks':checks.copy()}}]}
    for key in AUDITS:result[key+'_audit']={'cases':[],'regressions':[]}
    return result


class RegressionTests(unittest.TestCase):
    def test_older_baselines_can_add_the_harmonic_audit_without_losing_guards(self):
        old=snapshot();old.pop('harmonic_audit');new=snapshot()
        self.assertEqual(problem_queue(old),problem_queue(new));self.assertEqual(find_regressions(old,new),[])
        new['harmonic_audit']['regressions']=[{'case':'case-000','event':{'bar':1,'harmonic':'natural'}}]
        self.assertTrue(any(f['layer']=='harmonic' for f in find_regressions(old,new)))

    def test_unchanged_failures_are_not_regressions_but_swapped_passes_are(self):
        old=snapshot();self.assertEqual(find_regressions(old,old),[])
        new=copy.deepcopy(old)
        new['diagnostics']['cases'][0]['differences']=[{'bar':1,'reason':'notes'}]
        new['full_score_exports'][0]['checks']['note_attacks']=False
        new['full_score_exports'][0]['experimental']['checks']['end_tick']=False
        new['slide_audit']['regressions']=[{'case':'case-001','event':{'bar':2}}]
        failures=find_regressions(old,new)
        self.assertIn({'case':'case-000','layer':'differences','bar':1},failures)
        self.assertIn({'case':'case-000','layer':'app','check':'note_attacks'},failures)
        self.assertIn({'case':'case-000','layer':'experimental','check':'end_tick'},failures)
        self.assertTrue(any(f['reason']=='verified-event-lost' for f in failures if 'reason' in f))

    def test_lost_case_export_and_mismatch_cannot_disappear(self):
        old=snapshot();new=copy.deepcopy(old)
        new['cases'][0]['status']='error';new['diagnostics']['cases'].pop(0)
        new['full_score_exports']=[]
        new['slide_audit']['cases']=[{'case':'case-001','mismatched':[{'bar':2}]}]
        failures=find_regressions(old,new)
        self.assertEqual({f['reason'] for f in failures},{'previously-evaluated-case-lost','previous-export-lost','mismatched'})

    def test_cross_score_queue_keeps_uncertain_samples_and_stable_ids(self):
        old=snapshot();queue=problem_queue(old)
        group=next(g for g in queue if g['category']=='core/notes')
        self.assertEqual((group['case_count'],group['issue_count']),(2,2))
        new=copy.deepcopy(old)
        new['diagnostics']['cases'][0]['differences']=[]
        new['diagnostics']['cases'][1]['group']='uncertain'
        new['diagnostics']['cases'][1]['rhythm_differences']=[{'bar':1,'reason':'timing_attack_rest'}]
        new['full_score_exports'][0]['differences']={'note_releases':{'count':17,'examples':[]}}
        changes=compare_queues(queue,problem_queue(new))
        self.assertEqual(len(changes['resolved']),1)
        self.assertEqual(len(changes['new']),1)
        self.assertTrue(any(g['pairing']=='uncertain' for g in problem_queue(new)))
        self.assertEqual(changes['new'][0]['detail']['bar'],1)

    def test_failed_run_is_saved_and_existing_round_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);materials=root/'materials';materials.mkdir();pairing=root/'pairing';pairing.mkdir()
            pdf=materials/'a.pdf';gp=materials/'a.gp';pdf.write_bytes(b'pdf');gp.write_bytes(b'gp')
            baseline=root/'baseline.json';save(baseline,{'cases':[{'case':'case-000'}]})
            save(pairing/'results.json',[{'case':'case-000','pdf':str(pdf),'gp':str(gp)}])
            with patch('regression.run_command',side_effect=RuntimeError('tests failed')):
                with self.assertRaises(RuntimeError):run_round(materials,baseline,pairing,root/'round')
            self.assertEqual(read(root/'round/state.json')['status'],'failed')
            self.assertFalse((root/'round/summary.json').exists())
            with self.assertRaises(FileExistsError):run_round(materials,baseline,pairing,root/'round')
            with self.assertRaises(ValueError):run_round(materials,baseline,pairing,materials/'round')

    def test_real_export_and_both_playback_reports(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);batch=root/'batch';case=batch/'case-000';case.mkdir(parents=True)
            out=root/'out';out.mkdir();pdf=root/'source.pdf';mixed_fixture(pdf)
            save(case/'recognized.json',recognize(pdf))
            # Build a reference from the synthetic PDF to exercise orchestration,
            # not to claim independent recognition accuracy.
            import subprocess
            from regression import HERE
            gp=root/'source.gp';reference=case/'reference.json'
            subprocess.run(['node',str(HERE/'gp-export.cjs'),str(case/'recognized.json'),str(gp)],check=True,capture_output=True)
            subprocess.run(['node',str(HERE/'gp-reference.cjs'),str(gp),str(reference)],check=True,capture_output=True)
            track=read(reference)['tracks'][0]['name']
            result=export_case({'case':'case-000','pdf':str(pdf),'gp':str(gp),'track':track},batch,out,{'full_score_exports':[]})
            self.assertTrue(result['passed']);self.assertTrue(result['experimental']['passed'])
            self.assertEqual(result['engine'],'app-unmodified')
            self.assertEqual(result['experimental']['engine'],'experiment-complete-tremolos')
            self.assertEqual(result['actual']['note_attacks'],6)
            with self.assertRaises(FileExistsError):
                export_case({'case':'case-000'},batch,out,{'full_score_exports':[]})


if __name__=='__main__':unittest.main()
