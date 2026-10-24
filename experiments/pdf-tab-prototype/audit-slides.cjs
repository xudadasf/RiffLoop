// Evaluation only: distinguish verified rules, mismatches and remaining coverage.
const fs=require('fs'),path=require('path');
const alpha=require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');

function auditSlides(pred,track,exactBars) {
    const expected=[],actual=[];
    for(const bar of track.staves[0].bars) for(const beat of bar.voices[0].beats) for(const note of beat.notes) {
        if(note.slideOutType!==alpha.model.SlideOutType.Legato || !note.slideTarget)continue;
        const target=note.slideTarget;
        expected.push({bar:bar.index+1,beat:beat.index,string:7-note.string,fret:note.isDead?null:note.fret,
            target_bar:target.beat.voice.bar.index+1,target_fret:target.isDead?null:target.fret});
    }
    for(const system of pred.systems) for(const bar of system.bars) bar.beats.forEach((beat,i)=>{
        for(const note of beat.notes) if(note.legato_slide) actual.push({bar:bar.number,beat:i,
            string:note.string,fret:note.fret,target_bar:note.slide_target_bar,target_fret:note.slide_target_fret});
    });
    const comparable=e=>exactBars.has(e.bar)&&exactBars.has(e.target_bar);
    const key=e=>JSON.stringify(e),found=new Set(actual.map(key)),truth=new Set(expected.map(key));
    const pattern=e=>{
        const beat=track.staves[0].bars[e.bar-1].voices[0].beats[e.beat];
        if(beat.notes.length>1)return 'chord';
        const system=n=>pred.systems.findIndex(s=>s.bars.some(b=>b.number===n));
        return system(e.bar)!==system(e.target_bar)?'across-system':'single-note-evidence-not-matched';
    };
    return {
        verified:actual.filter(e=>comparable(e)&&truth.has(key(e))),
        mismatched:actual.filter(e=>comparable(e)&&!truth.has(key(e))),
        not_recognized:expected.filter(e=>comparable(e)&&!found.has(key(e))).map(e=>({...e,pattern:pattern(e)})),
        unverified_predictions:actual.filter(e=>!comparable(e)),
        unaligned_reference:expected.filter(e=>!comparable(e))
    };
}

function findRegressions(current,baseline) {
    const regressions=[];
    for(const before of baseline.cases) {
        const after=current.cases.find(c=>c.case===before.case && c.pdf===before.pdf && c.track_index===before.track_index);
        const verified=new Set((after?.verified||[]).map(e=>JSON.stringify(e)));
        for(const event of before.verified||[]) if(!verified.has(JSON.stringify(event)))regressions.push({case:before.case,event});
    }
    return regressions;
}

if(require.main===module) {
    const [folder,baselineFile]=process.argv.slice(2);
    if(!folder)throw Error('Usage: node audit-slides.cjs <benchmark-folder> [baseline-audit-or-summary.json]');
    const read=p=>JSON.parse(fs.readFileSync(p,'utf8'));
    const rows=read(path.join(folder,'results.json')),cases=[],scores=new Map();
    for(const row of rows) {
        if(row.status!=='evaluated')continue;
        if(!scores.has(row.gp))scores.set(row.gp,alpha.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(row.gp)),new alpha.Settings()));
        const tracks=scores.get(row.gp).tracks.filter(t=>t.name===row.track && t.staves.length===1 && t.staves[0].tuning.length===6);
        if(tracks.length!==1){cases.push({case:row.case,status:'ambiguous-reference-track'});continue;}
        const pred=read(path.join(folder,row.case,'recognized.json'));
        const exact=new Set(read(path.join(folder,row.case,'comparison.json')).filter(b=>b.core_exact).map(b=>b.number));
        cases.push({case:row.case,pdf:path.basename(row.pdf),status:'audited',track_index:tracks[0].index,
            marks:pred.slide_marks||[],...auditSlides(pred,tracks[0],exact)});
    }
    const categories=['verified','mismatched','not_recognized','unverified_predictions','unaligned_reference'];
    const summary={candidate_count:cases.length,counts:Object.fromEntries(categories.map(k=>[k,cases.reduce((n,c)=>n+(c[k]?.length||0),0)])),
        cases_with_verified_rule:cases.filter(c=>c.verified?.length).length,
        limitations:['Repeated corpus, not a blind test','Comparison requires exact source and destination bars; other notes remain unverified',
            'Missing recognition is a coverage gap, not automatically proof of a new notation type','Unambiguous single-staff reference tracks only'],cases};
    summary.regressions=[];
    if(baselineFile) {
        const baseline=read(baselineFile);
        summary.regressions=findRegressions(summary,baseline.slide_audit||baseline);
    }
    fs.writeFileSync(path.join(folder,'slide-audit.json'),JSON.stringify(summary,null,2));
    console.log(JSON.stringify({candidate_count:summary.candidate_count,counts:summary.counts,
        cases_with_verified_rule:summary.cases_with_verified_rule,regressions:summary.regressions.length}));
    if(summary.counts.mismatched || summary.regressions.length)process.exitCode=1;
}

module.exports={auditSlides,findRegressions};
