// Evaluation only. Reference GP never supplies recognition or export decisions.
const fs=require('fs'),path=require('path');
const alpha=require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {findRegressions}=require('./audit-slides.cjs');

function auditSlideOuts(pred,track,exactBars) {
    const actual=[],expected=[];
    for(const system of pred.systems)for(const bar of system.bars)bar.beats.forEach((beat,i)=>{
        for(const note of beat.notes)if(note.slide_out)actual.push({bar:bar.number,beat:i,string:note.string,
            fret:note.fret,direction:note.slide_out});
    });
    for(const bar of track.staves[0].bars)for(const beat of bar.voices[0].beats)for(const note of beat.notes) {
        if(![alpha.model.SlideOutType.OutUp,alpha.model.SlideOutType.OutDown].includes(note.slideOutType))continue;
        expected.push({bar:bar.index+1,beat:beat.index,string:7-note.string,fret:note.isDead?null:note.fret,
            direction:note.slideOutType===alpha.model.SlideOutType.OutUp?'up':'down'});
    }
    const key=e=>JSON.stringify(e),found=new Set(actual.map(key)),truth=new Set(expected.map(key));
    return {
        verified:actual.filter(e=>exactBars.has(e.bar)&&truth.has(key(e))),
        mismatched:actual.filter(e=>exactBars.has(e.bar)&&!truth.has(key(e))),
        not_recognized:expected.filter(e=>exactBars.has(e.bar)&&!found.has(key(e))),
        unverified_predictions:actual.filter(e=>!exactBars.has(e.bar)),
        unaligned_reference:expected.filter(e=>!exactBars.has(e.bar))
    };
}

if(require.main===module) {
    const [folder,baselineFile]=process.argv.slice(2);
    if(!folder)throw Error('Usage: node audit-slide-outs.cjs <benchmark-folder> [baseline-summary.json]');
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
            ...auditSlideOuts(pred,tracks[0],exact)});
    }
    const categories=['verified','mismatched','not_recognized','unverified_predictions','unaligned_reference'];
    const summary={candidate_count:cases.length,counts:Object.fromEntries(categories.map(k=>[k,cases.reduce((n,c)=>n+(c[k]?.length||0),0)])),
        cases_with_verified_rule:cases.filter(c=>c.verified?.length).length,
        limitations:['Repeated corpus, not blind testing','Only core-exact bars verify source and slide direction',
            'Connecting slides and ambiguous diagonals are excluded','Actual slide pitch curves and rendered audio are not verified'],cases,regressions:[]};
    if(baselineFile) {
        const baseline=read(baselineFile);
        summary.regressions=findRegressions(summary,baseline.slide_out_audit||{cases:[]});
    }
    fs.writeFileSync(path.join(folder,'slide-out-audit.json'),JSON.stringify(summary,null,2));
    console.log(JSON.stringify({counts:summary.counts,cases_with_verified_rule:summary.cases_with_verified_rule,
        regressions:summary.regressions.length}));
    if(summary.counts.mismatched||summary.regressions.length)process.exitCode=1;
}

module.exports={auditSlideOuts};
