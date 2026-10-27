// Separate, explicitly unverified notes-first draft. Never reads a reference GP.
const fs = require('fs');
const crypto = require('crypto');
const alpha = require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const [input, output] = process.argv.slice(2);
if (!input || !output?.endsWith('.draft.gp')) throw Error('Usage: node gp-draft-export.cjs recognized.json output.draft.gp');
const targets = [output, output+'.review.json', output+'.review.md'];
if (targets.some(p=>fs.existsSync(p))) throw Error('Draft or review file already exists');
const raw = fs.readFileSync(input);
const data = JSON.parse(raw.toString('utf8'));
if (data.format === 'raster-tab-draft-v1' || data.format === 'raster-digit-review-v1')
    throw Error('Image GP export is disabled: rhythm is unverified. Use the digit review report; do not substitute quarter notes.');
const raster = data.format === 'raster-tab-beamed-v1';
const bars = data.systems.flatMap(s=>s.bars.map(b=>({...b,page:s.page})));
if (!bars.length || data.structure_issues?.length || bars.some((b,i)=>b.number!==i+1))
    throw Error('Resolve missing, duplicated or reordered bars before drafting');
if (!Array.isArray(data.tuning) || data.tuning.length!==6 || data.tuning.some(n=>!Number.isInteger(n) || n<0 || n>127) ||
    !Number.isFinite(data.tempo) || data.tempo<=0) throw Error('PDF tuning and tempo are required');
const score = new alpha.model.Score();
score.title = raster ? 'IMAGE TAB - editable draft' : 'DRAFT - PDF notes for manual correction';
score.instructions = 'Unverified draft. Rhythm may be wrong. Ties and playing techniques are omitted. Review sidecar before playback.';
if (raster) score.instructions += ' Notes from digit OCR; supported rhythms from image beams. Question marks indicate explicit timing defaults; see review file. Meter, tempo and tuning are manual settings.';
const track = new alpha.model.Track(); score.addTrack(track); track.name = 'DRAFT notes'; track.playbackInfo.program = 25;
const staff = new alpha.model.Staff(); track.addStaff(staff); staff.stringTuning.tunings = data.tuning;
const review = {draft:true,playback_verified:false,source_sha256:crypto.createHash('sha256').update(raw).digest('hex'),
    omitted:'ties, harmonics, slides, bends, palm mute, staccato and other playing techniques; repeats',
    tempo_issues:data.tempo_issues??[],note_count:0,bars:[]};
if (raster) {
    review.source_kind = 'image-digits-and-beams';
    review.manual_settings = {tempo:data.tempo,meter:data.meter,tuning:data.tuning};
    review.warnings = data.warnings??[];
    review.model_sha256 = data.model_sha256;
}
const expected = [];
for (const source of bars) {
    if (!Array.isArray(source.meter) || source.meter.length!==2 || source.meter.some(n=>!Number.isInteger(n) || n<=0) ||
        !Array.isArray(source.beats) || !source.beats.length) throw Error('Missing meter or beat content');
    if (raster) {
        if (source.beats.some(b=>![1,2,4,8,16,32,64].includes(b.duration) || ![0,1,2].includes(b.dots) ||
            b.grace || JSON.stringify(b.tuplet)!=='[1,1]' ||
            !['image-beams','manual-default','manual-rest-default'].includes(b.rhythm_source) ||
            (b.rhythm_source!=='image-beams' && b.placeholder!==true)))
            throw Error('Image draft needs explicit durations and placeholder provenance');
        const total=source.beats.reduce((sum,b)=>sum+4/b.duration*(2-Math.pow(2,-b.dots)),0);
        if (Math.abs(total-source.meter[0]*4/source.meter[1])>1e-9)
            throw Error('Image draft timing does not fill its meter; do not overflow or silently pad');
    }
    const master = new alpha.model.MasterBar();
    [master.timeSignatureNumerator,master.timeSignatureDenominator] = source.meter; score.addMasterBar(master);
    const tempo = source.tempo??data.tempo;
    if (!Number.isFinite(tempo) || tempo<=0) throw Error('Invalid tempo');
    if (master.index===0 || tempo!==(bars[master.index-1].tempo??data.tempo))
        master.tempoAutomations.push(alpha.model.Automation.buildTempoAutomation(false,0,tempo,2));
    const bar = new alpha.model.Bar(); staff.addBar(bar); const voice = new alpha.model.Voice(); bar.addVoice(voice);
    const row = {page:source.page,source_bar:source.number,issues:source.issues??[],placeholder_beats:[],review_required:true};
    if (raster) { row.note_review_beats=[]; row.rhythm_evidence=[]; }
    const beats = [];
    for (const [index,item] of source.beats.entries()) {
        if (item.voice && item.voice!==0) throw Error('Multiple voices need separate review');
        const valid = [1,2,4,8,16,32,64].includes(item.duration) && Number.isInteger(item.dots) && item.dots>=0 && item.dots<=2 &&
            Array.isArray(item.tuplet) && item.tuplet.length===2 && item.tuplet.every(n=>Number.isInteger(n) && n>0) &&
            (item.tuplet[0]!==1 || item.tuplet[1]===1);
        const beat = new alpha.model.Beat(); voice.addBeat(beat);
        beat.duration = valid?item.duration:4; beat.dots = valid?item.dots:0;
        [beat.tupletNumerator,beat.tupletDenominator] = valid?item.tuplet:[1,1];
        if (item.grace) beat.graceType = alpha.model.GraceType.BeforeBeat;
        if (index===0 && !raster) beat.text = `DRAFT p${source.page} m${source.number}: review rhythm and effects`;
        if (raster) {
            row.rhythm_evidence.push({beat:index+1,source:item.rhythm_source,evidence:item.rhythm_evidence??null,reason:item.rhythm_reason??null});
            if (item.note_review) row.note_review_beats.push(index+1);
        }
        if (!valid || (raster && item.placeholder)) {
            row.placeholder_beats.push(index+1);
            beat.text = raster ? '?' : (beat.text?beat.text+'; ':'')+'UNKNOWN RHYTHM: quarter placeholder';
        }
        const notes = [];
        for (const n of item.notes) {
            if (!Number.isInteger(n.string) || n.string<1 || n.string>6 ||
                (!n.dead && (!Number.isInteger(n.fret) || n.fret<0 || n.fret>36)) || notes.some(x=>x[0]===n.string))
                throw Error('Unknown fret/string or duplicate note: do not guess');
            const note = new alpha.model.Note(); note.string = 7-n.string; note.isDead = !!n.dead;
            note.fret = n.dead?0:n.fret; beat.addNote(note);
            notes.push([n.string,n.dead?null:n.fret,!!n.dead]); review.note_count++;
        }
        beats.push({notes:notes.sort((a,b)=>a[0]-b[0]),duration:beat.duration,dots:beat.dots,
            tuplet:[beat.tupletNumerator,beat.tupletDenominator],grace:!!item.grace,text:beat.text});
    }
    expected.push(beats); review.bars.push(row);
}
const settings = new alpha.Settings(); score.finish(settings);
const bytes = new alpha.exporter.Gp7Exporter().export(score,settings);
const readback = alpha.importer.ScoreLoader.loadScoreFromBytes(bytes,settings);
const actual = readback.tracks[0].staves[0].bars;
if (actual.length!==bars.length || readback.title!==score.title ||
    JSON.stringify(readback.tracks[0].staves[0].tuning)!==JSON.stringify(data.tuning)) throw Error('Draft roundtrip changed structure');
for (let i=0;i<actual.length;i++) {
    const master=readback.masterBars[i],tempo=bars[i].tempo??data.tempo;
    const tempos=i===0 || tempo!==(bars[i-1].tempo??data.tempo)?[tempo]:[];
    if (master.timeSignatureNumerator!==bars[i].meter[0] || master.timeSignatureDenominator!==bars[i].meter[1] ||
        JSON.stringify(master.tempoAutomations.map(a=>a.value))!==JSON.stringify(tempos))
        throw Error('Draft roundtrip changed meter or tempo');
    const beats = actual[i].voices[0].beats;
    if (beats.length!==expected[i].length) throw Error('Draft roundtrip changed beat count');
    for (let j=0;j<beats.length;j++) {
        const b=beats[j],e=expected[i][j];
        const notes=b.notes.map(n=>[7-n.string,n.isDead?null:n.fret,n.isDead]).sort((a,b)=>a[0]-b[0]);
        // GP import represents ordinary non-tuplet beats as -1/-1.
        const tuplet=b.hasTuplet?[b.tupletNumerator,b.tupletDenominator]:[1,1];
        if (JSON.stringify(notes)!==JSON.stringify(e.notes) || b.duration!==e.duration || b.dots!==e.dots ||
            (b.graceType!==alpha.model.GraceType.None)!==e.grace || b.text!==e.text ||
            JSON.stringify(tuplet)!==JSON.stringify(e.tuplet))
            throw Error(`Draft roundtrip changed notes, timing or review label at bar ${i+1}, beat ${j+1}`);
    }
}
review.roundtrip = 'passed; serialized content only, not PDF or playback accuracy';
const lines = ['# 待人工校正草稿','',
    raster ? '音符来自图片数字识别，仍需人工核对。明确连接的横梁用于识别时值；其余按默认值占位，并在谱内用 ? 标记。默认四分音符，剩余空间不足时统一缩短；剩余拍数补休止占位。BPM、拍号、定弦为人工设置。小节号为检测顺序号。' : '音符来自 PDF 识别结果，未经整曲验收。节奏保留识别值；未知时值用四分音符占位，并在谱内标记 placeholder。',
    '本草稿未导出延音线、泛音、滑音、推弦、掌根闷音、顿音等技巧及反复结构，播放前请对照原谱修改。X 闷音记号本身保留。',
    `音符数：${review.note_count}；小节数：${bars.length}。所有小节均需复核，下面列出识别器已知的问题。`,
    ...review.tempo_issues.map(x=>'速度待核对：'+JSON.stringify(x)),...(review.warnings??[]),'',
    '| 来源页 | 小节 | 已知问题 | 占位时值的拍序号 |','| --- | --- | --- | --- |',
    ...review.bars.filter(b=>b.issues.length || b.placeholder_beats.length || b.note_review_beats?.length).map(b=>
        `| ${b.page} | ${b.source_bar} | ${[...b.issues,...(b.note_review_beats?.length?['数字/弦位待核对音符序号（低分或位置重试）：'+b.note_review_beats.join(', ')]:[])].join('; ').replaceAll('|','/').replaceAll('\n',' ')} | ${b.placeholder_beats.join(', ')} |`)];
fs.writeFileSync(output,bytes);
fs.writeFileSync(output+'.review.json',JSON.stringify(review,null,2)+'\n');
fs.writeFileSync(output+'.review.md',lines.join('\n')+'\n');
console.log(JSON.stringify({output,bars:bars.length,notes:review.note_count,draft:true,roundtrip:'passed'}));
