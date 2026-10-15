import json
from pathlib import Path
import subprocess
import unittest

HERE=Path(__file__).parent


class ExperimentalMidiTests(unittest.TestCase):
    def run_node(self,script):
        run=subprocess.run(['node','-e',script],cwd=HERE.parent.parent,capture_output=True,text=True,encoding='utf-8')
        self.assertEqual(run.returncode,0,run.stderr[-1800:])
        return json.loads(run.stdout)

    def test_gp_triplet_emits_all_eight_repetitions_without_changing_app_engine(self):
        result=self.run_node(r'''
const a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {createCompleteTremoloGenerator}=require('./experiments/pdf-tab-prototype/experimental-midi.cjs');
const score=new a.model.Score(),track=new a.model.Track(),staff=new a.model.Staff();
score.addTrack(track);track.addStaff(staff);staff.stringTuning.tunings=[64,59,55,50,45,40];
score.addMasterBar(new a.model.MasterBar());const bar=new a.model.Bar(),voice=new a.model.Voice();staff.addBar(bar);bar.addVoice(voice);
for(let i=0;i<9;i++){
 const b=new a.model.Beat();voice.addBeat(b);b.duration=i<3?32:i<6?16:4;
 if(i<3){b.tupletNumerator=3;b.tupletDenominator=2;}
 if(i===0){b.tremoloPicking=new a.model.TremoloPickingEffect();b.tremoloPicking.marks=3;}
 const n=new a.model.Note();n.string=3;n.fret=7;b.addNote(n);
}
score.finish(new a.Settings());
const gp=new a.exporter.Gp7Exporter().export(score,new a.Settings());
const s=a.importer.ScoreLoader.loadScoreFromBytes(gp,new a.Settings());
const original=a.midi.MidiFileGenerator.prototype.Ig;
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
function render(experiment){
 const file=new a.midi.MidiFile(),notes=[];
 class Handler extends a.midi.AlphaSynthMidiFileHandler{
  addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
 }
 const h=new Handler(file,true),g=experiment?createCompleteTremoloGenerator(s,new a.Settings(),h):new a.midi.MidiFileGenerator(s,new a.Settings(),h);
 g.generate();const bytes=file.toBinary();
 return {notes,midi_header:Buffer.from(bytes.slice(0,4)).toString('ascii'),end:g.tickLookup.masterBars.at(-1).end};
}
const before=render(false),fixed=render(true),after=render(false),b=s.tracks[0].staves[0].bars[0].voices[0].beats[0];
console.log(JSON.stringify({before,fixed,after,app_report:comparePlayback(s,s,0),experimental_report:comparePlayback(s,s,0,true),
 prototype_unchanged:original===a.midi.MidiFileGenerator.prototype.Ig,
 duration:b.duration,tuplet:[b.tupletNumerator,b.tupletDenominator],strokes:b.tremoloPicking.marks}));
''')
        self.assertEqual(result['fixed']['notes'][:8],[[i*10,10] for i in range(8)])
        self.assertEqual(result['fixed']['notes'][8],[80,80])
        self.assertEqual(result['before']['notes'][:7],[[i*10,10] for i in range(7)])
        self.assertEqual(result['before']['notes'][7],[80,80])
        self.assertEqual(result['before'],result['after'])
        self.assertTrue(result['prototype_unchanged'])
        self.assertEqual(result['fixed']['end'],3840)
        self.assertEqual(result['fixed']['midi_header'],'MThd')
        self.assertEqual((result['duration'],result['tuplet'],result['strokes']),(32,[3,2],3))
        self.assertEqual(result['app_report']['actual']['note_attacks'],15)
        self.assertEqual(result['experimental_report']['actual']['note_attacks'],16)
        self.assertTrue(result['experimental_report']['passed'])
        self.assertEqual(result['app_report']['engine'],'app-unmodified')
        self.assertEqual(result['experimental_report']['engine'],'experiment-complete-tremolos')

    def test_repetition_boundaries_and_fractional_ticks(self):
        result=self.run_node(r'''
const a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {createCompleteTremoloGenerator}=require('./experiments/pdf-tab-prototype/experimental-midi.cjs');
function run(span,step,marks=3){
 const events=[],handler={addNote:(track,tick,duration,key,velocity,channel)=>events.push([tick,duration,key,velocity,channel])};
 const g=createCompleteTremoloGenerator(new a.model.Score(),new a.Settings(),handler);
 const note={beat:{voice:{bar:{staff:{track:{index:0}}}},duration:32,tremoloPicking:{marks,getDurationAsTicks:()=>step}}};
 g.Ig(note,100,{beatDurationFactor:1,untilTieOrSlideEnd:span},62,90,2);return events;
}
console.log(JSON.stringify({exact:run(80,10),short:run(5,10),tail:run(25,10),empty:run(0,10),disabled:run(80,10,0),
 fractional:run(80,80/7),ordinary:run(960,120)}));
''')
        for name,expected in {
            'exact':[[100+i*10,10] for i in range(8)],
            'short':[[100,5]],'tail':[[100,10],[110,10],[120,5]],
            'empty':[],'disabled':[],
            'ordinary':[[100+i*120,120] for i in range(8)],
        }.items():
            with self.subTest(name=name):
                self.assertEqual(result[name],[v+[62,90,2] for v in expected])
        events=result['fractional'];self.assertEqual(len(events),7)
        for i,event in enumerate(events):
            self.assertAlmostEqual(event[0],100+i*80/7)
            self.assertAlmostEqual(event[1],80/7)
        self.assertAlmostEqual(events[-1][0]+events[-1][1],180)

    def test_private_engine_change_is_rejected(self):
        result=self.run_node(r'''
const a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {createCompleteTremoloGenerator}=require('./experiments/pdf-tab-prototype/experimental-midi.cjs');
const original=a.midi.MidiFileGenerator.prototype.Ig;let error='';
try{
 a.midi.MidiFileGenerator.prototype.Ig=function changed(){};
 try{createCompleteTremoloGenerator(new a.model.Score(),new a.Settings(),{});}catch(e){error=e.message;}
}finally{a.midi.MidiFileGenerator.prototype.Ig=original;}
console.log(JSON.stringify({error}));
''')
        self.assertIn('Unsupported alphaTab tremolo implementation',result['error'])


if __name__=='__main__':unittest.main()
