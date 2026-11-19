const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.RIFFLOOP_PLAYWRIGHT || 'playwright');

async function main() {
  const browser = await chromium.launch({headless: true, executablePath: process.env.RIFFLOOP_BROWSER});
  try {
    const page = await browser.newPage();
    const editor = path.resolve(__dirname, '../RiffLoop/Resources/ScoreEditor');
    await page.goto(pathToFileURL(path.join(editor, 'editor.html')).href);
    const result = await page.evaluate(schema => {
      const settings = new alphaTab.Settings();
      const note = GuitarEdit.note(1, 7);
      note.effects.harmonicType = 1;
      function draft(notes) {
        const b = GuitarEdit.beat(1);
        b.notes = notes;
        return {version:3, title:'Roundtrip', tempo:80, numerator:4, denominator:4,
          tuning:[40,45,50,55,59,64], capo:0, program:27, bars:[{...GuitarEdit.bar(), beats:[b]}]};
      }
      const encode = d => GuitarDraftCore.exportDraft(alphaTab, d, schema);
      function open(bytes,index=0) {
        const f = GuitarGP.open(bytes, schema);
        const s = GuitarGP.select(f, f.options[index]);
        const editor = new GuitarEdit.Session(s.draft, d => GuitarGP.check(s,d));
        return {s, editor, save:()=>GuitarGP.save(s,editor.draft)};
      }
      const xml = bytes => new DOMParser().parseFromString(GuitarArchive.xml(bytes),'text/xml');
      const score = bytes => alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes,settings);
      function counts(bytes) {
        const doc = xml(bytes);
        return ['Bar','Voice','Beat','Note','Rhythm'].map(type=>doc.querySelectorAll(type+'[id]').length);
      }

      const original = encode(draft([note]));
      const natural = open(original);
      const noop = natural.save() === original;
      natural.editor.setFret(12);
      const at12 = natural.save();
      const pitch = score(at12).tracks[0].staves[0].bars[0].voices[0].beats[0].notes[0].realValue;
      const pair = draft([note]);
      pair.bars[0].beats[0].duration = 2;
      pair.bars[0].beats.push(structuredClone(pair.bars[0].beats[0]));
      const selection = open(encode(pair));
      selection.editor.selectNotes({bar:0,beat:0,string:1},{bar:0,beat:1,string:1});
      selection.editor.setFret(12);
      const pitches = score(selection.save()).tracks[0].staves[0].bars[0].voices[0].beats.map(b=>b.notes[0].realValue);
      const custom = structuredClone(note);
      custom.effects.harmonicValue=5;
      const explicit = open(encode(draft([custom])));
      explicit.editor.setFret(12);
      const customNode = score(explicit.save()).tracks[0].staves[0].bars[0].voices[0].beats[0].notes[0].harmonicValue;

      const silent = open(encode(draft([])));
      silent.editor.setFret(8);
      const firstNote = score(silent.save()).tracks[0].staves[0].bars[0].voices[0].beats[0].notes[0].fret;
      let repeated = at12;
      for (const fret of [7,12,7,12,7,12]) {
        const edit = open(repeated);
        edit.editor.setFret(fret);
        repeated=edit.save();
      }

      // Two tracks can share a beat. The reference and foreign annotations of
      // the unedited track must survive an edit to the first track.
      const model = GuitarDraftCore.makeScore(alphaTab,draft([note]),schema);
      model.addTrack(GuitarDraftCore.makeScore(alphaTab,draft([note]),schema).tracks[0]);
      model.finish(settings);
      const two = new alphaTab.exporter.Gp7Exporter().export(model,settings);
      const doc = xml(two);
      const beatRefs = [...doc.querySelectorAll('Voice > Beats')];
      const sharedId = beatRefs[0].textContent;
      beatRefs[1].textContent = sharedId;
      const attached = doc.querySelector('Note[id]');
      const extra = doc.createElement('CustomNotation');
      extra.textContent = 'keep';
      attached.append(extra);
      const shared = GuitarArchive.replace(two,new XMLSerializer().serializeToString(doc));
      const editing = open(shared);
      editing.editor.setFret(12);
      const saved = editing.save();
      const final = xml(saved);
      const finalRefs = [...final.querySelectorAll('Voice > Beats')].map(n=>n.textContent);
      const otherOriginal = finalRefs[1] === sharedId && finalRefs[0] !== finalRefs[1] &&
        doc.querySelector('Beat[id="'+sharedId+'"]').isEqualNode(final.querySelector('Beat[id="'+sharedId+'"]'));
      const frets = score(saved).tracks.map(t=>t.staves[0].bars[0].voices[0].beats[0].notes[0].fret);
      return {noop, pitch, pitches, customNode, firstNote, originalCounts:counts(original), repeatedCounts:counts(repeated),
        otherOriginal, frets, customNotation:[...final.querySelectorAll('CustomNotation')].map(n=>n.textContent)};
    }, require(path.join(editor, 'techniques.json')));
    assert.equal(result.noop, true);
    assert.equal(result.pitch, 76);
    assert.deepEqual(result.pitches, [76,76]);
    assert.equal(result.customNode, 5);
    assert.equal(result.firstNote, 8);
    assert.deepEqual(result.repeatedCounts, result.originalCounts);
    assert.equal(result.otherOriginal, true);
    assert.deepEqual(result.frets, [12,7]);
    assert.deepEqual(result.customNotation, ['keep','keep']);
    console.log('Existing GP roundtrips passed: harmonic nodes, rest-only guitar, shared records and repeated saves.');
  } finally {
    await browser.close();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
