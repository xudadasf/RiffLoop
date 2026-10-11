"""Check playback diagnostics against scores with known timing differences."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE=Path(__file__).parent


class PlaybackTests(unittest.TestCase):
    def test_real_midi_generation_detects_order_tempo_attack_and_release_changes(self):
        script=r'''
const alpha=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
function score(mode) {
 const s=new alpha.model.Score(),t=new alpha.model.Track(),st=new alpha.model.Staff();
 s.addTrack(t);t.addStaff(st);st.stringTuning.tunings=[64,59,55,50,45,40];
 for(let i=0;i<2;i++) {
  const m=new alpha.model.MasterBar();s.addMasterBar(m);
  if(i===0) m.tempoAutomations.push(alpha.model.Automation.buildTempoAutomation(false,0,90,2));
  if(mode==='tempo' && i===1) m.tempoAutomations.push(alpha.model.Automation.buildTempoAutomation(false,0,120,2));
  if(mode==='repeat') {m.isRepeatStart=i===0;m.repeatCount=i===1?2:0;}
  const b=new alpha.model.Bar(),v=new alpha.model.Voice();st.addBar(b);b.addVoice(v);
  for(let j=0;j<4;j++) {
   const beat=new alpha.model.Beat();v.addBeat(beat);beat.duration=4;
   if(mode==='shift' && i===0) {if(j===0)beat.duration=8;if(j===1)beat.dots=1;}
   if(mode==='rest' && i===0 && j===0)continue;
   const n=new alpha.model.Note();n.string=3;n.fret=mode==='pitch'?9:7;
   if(mode==='ornament' && i===0 && j===0)n.ornament=alpha.model.NoteOrnament.UpperMordent;
   if(mode==='tie' && i===1 && j===0)n.isTieDestination=true;
   if(mode==='staccato' && i===0 && j===0)n.isStaccato=true;
   beat.addNote(n);
  }
 }
 s.finish(new alpha.Settings());
 // Exercise the same GP write/read boundary as actual verification.
 const bytes=new alpha.exporter.Gp7Exporter().export(s,new alpha.Settings());
 return alpha.importer.ScoreLoader.loadScoreFromBytes(bytes,new alpha.Settings());
}
const modes=['same','pitch','repeat','tempo','shift','tie','rest','staccato','ornament'];
require('assert').throws(()=>comparePlayback(score('same'),score('same'),1));
console.log(JSON.stringify(Object.fromEntries(modes.map(m=>[m,comparePlayback(score('same'),score(m),0)]))));
'''
        run=subprocess.run(['node','-e',script],cwd=HERE.parent.parent,capture_output=True,text=True,encoding='utf-8')
        self.assertEqual(run.returncode,0,run.stderr)
        results=json.loads(run.stdout)
        self.assertTrue(results['same']['passed'])
        self.assertTrue(results['pitch']['passed'])  # Pitch is checked separately by verify_export.py.
        for mode in ('repeat','tempo','shift','tie','rest','staccato','ornament'):
            self.assertFalse(results[mode]['passed'],mode)
        self.assertFalse(results['repeat']['checks']['bar_sequence'])
        self.assertFalse(results['tempo']['checks']['tempo_timeline'])
        self.assertFalse(results['shift']['checks']['note_attacks'])
        self.assertFalse(results['tie']['checks']['note_attacks'])
        self.assertFalse(results['rest']['checks']['note_attacks'])
        self.assertTrue(results['staccato']['checks']['note_attacks'])
        self.assertFalse(results['staccato']['checks']['note_releases'])

    def test_failed_input_invalidates_previous_playback_report(self):
        with tempfile.TemporaryDirectory() as folder:
            report=Path(folder)/'report.json';report.write_text('{"passed":true}',encoding='utf-8')
            missing=Path(folder)/'missing.gp'
            run=subprocess.run(['node',str(HERE/'verify-playback.cjs'),str(missing),str(missing),'0',str(report)],capture_output=True)
            self.assertNotEqual(run.returncode,0)
            self.assertFalse(report.exists())
            source=Path(folder)/'source.gp';source.write_bytes(b'keep original input')
            run=subprocess.run(['node',str(HERE/'verify-playback.cjs'),str(source),str(missing),'0',str(source)],capture_output=True)
            self.assertNotEqual(run.returncode,0)
            self.assertEqual(source.read_bytes(),b'keep original input')


if __name__=='__main__':unittest.main()
