// Evaluation only. Reference GP flags never enter PDF recognition or export.
const fs=require('fs'),path=require('path');
const alpha=require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {findRegressions}=require('./audit-slides.cjs');

function auditStaccato(pred,track,exactBars) {
    const expected=[],actual=[];
    for(const bar of track.staves[0].bars)for(const beat of bar.voices[0].beats)for(const note of beat.notes)
        if(note.isStaccato)expected.push({bar:bar.index+1,beat:beat.index,string:7-note.string,fret:note.fret});
    for(const system of pred.systems)for(const bar of system.bars)bar.beats.forEach((beat,i)=>{
        for(const note of beat.notes)if(note.staccato)actual.push({bar:bar.number,beat:i,string:note.string,fret:note.fret});
    });
    const key=e=>JSON.stringify(e),truth=new Set(expected.map(key)),found=new Set(actual.map(key));
    return {
        verified:actual.filter(e=>exactBars.has(e.bar)&&truth.has(key(e))),
        mismatched:actual.filter(e=>exactBars.has(e.bar)&&!truth.has(key(e))),
        not_recognized:expected.filter(e=>exactBars.has(e.bar)&&!found.has(key(e))).map(e=>({...e,
            pattern:track.staves[0].bars[e.bar-1].voices[0].beats[e.beat].notes.length>1?'chord-note-scope':'single-note-mark-not-matched'})),
        unverified_predictions:actual.filter(e=>!exactBars.has(e.bar)),
        unaligned_reference:expected.filter(e=>!exactBars.has(e.bar))
    };
}

if(require.main===module) {
    const [folder,baselineFile]=process.argv.slice(2);
    if(!folder)throw Error('Usage: node audit-staccato.cjs <benchmark-folder> [baseline-audit-or-summary.json]');
    const read=p=>JSON.parse(fs.readFileSync(p,'utf8'));
    const rows=read(path.join(folder,'results.json')),cases=[],scores=new Map();
    for(const row of rows) {
        if(row.status!=='evaluated')continue;
        if(!scores.has(row.gp))scores.set(row.gp,alpha.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(row.gp)),new alpha.Settings()));
        const tracks=scores.get(row.gp).tracks.filter(t=>t.name===row.track&&t.staves.length===1&&t.staves[0].tuning.length===6);
        if(tracks.length!==1){cases.push({case:row.case,status:'ambiguous-reference-track'});continue;}
        const pred=read(path.join(folder,row.case,'recognized.json'));
        const exact=new Set(read(path.join(folder,row.case,'comparison.json')).filter(b=>b.core_exact).map(b=>b.number));
        cases.push({case:row.case,pdf:path.basename(row.pdf),status:'audited',track_index:tracks[0].index,
            ...auditStaccato(pred,tracks[0],exact)});
    }
    const categories=['verified','mismatched','not_recognized','unverified_predictions','unaligned_reference'];
    const summary={candidate_count:cases.length,counts:Object.fromEntries(categories.map(k=>[k,cases.reduce((n,c)=>n+(c[k]?.length||0),0)])),
        cases_with_verified_rule:cases.filter(c=>c.verified?.length).length,
        limitations:['Repeated regression corpus, not blind testing','Only core-exact bars can verify note-level articulation',
            'A chord-level printed dot does not identify which GP notes were marked','Outline dots are not distinguished from augmentation dots'],cases,
        regressions:[]};
    if(baselineFile){const baseline=read(baselineFile);summary.regressions=findRegressions(summary,baseline.staccato_audit||baseline);}
    fs.writeFileSync(path.join(folder,'staccato-audit.json'),JSON.stringify(summary,null,2));
    console.log(JSON.stringify({counts:summary.counts,cases_with_verified_rule:summary.cases_with_verified_rule,regressions:summary.regressions.length}));
    if(summary.counts.mismatched||summary.regressions.length)process.exitCode=1;
}

module.exports={auditStaccato};
