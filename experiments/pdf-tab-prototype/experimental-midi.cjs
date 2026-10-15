// Experiment only. The application library and its prototype stay unchanged.
const alpha=require('../../RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {createHash}=require('crypto');

// Ig is private in the bundled alphaTab 1.8.4 build. Refuse a different
// implementation instead of silently applying this experiment after an update.
const tremoloMethodHash='9d603fee2a1cfc22bead5ff87f6a56465530e97bf020e1e6cc9e0fe25a10b580';

function createCompleteTremoloGenerator(score,settings,handler) {
    const original=alpha.midi.MidiFileGenerator.prototype.Ig;
    if(typeof original!=='function' || createHash('sha256').update(original.toString()).digest('hex')!==tremoloMethodHash)
        throw Error('Unsupported alphaTab tremolo implementation; revalidate the experimental adapter');
    const generator=new alpha.midi.MidiFileGenerator(score,settings,handler);
    generator.Ig=(note,start,duration,key,velocity,channel)=>{
        const picking=note.beat.tremoloPicking;
        if(picking.marks===0)return;
        const step=picking.getDurationAsTicks(note.beat.duration)*duration.beatDurationFactor;
        const span=duration.untilTieOrSlideEnd;
        // Ignore only floating-point residue, never a fixed musical duration.
        const epsilon=Number.EPSILON*Math.max(1,Math.abs(span))*4;
        for(let index=0;index*step<span-epsilon;index++) {
            const offset=index*step;
            handler.addNote(note.beat.voice.bar.staff.track.index,start+offset,Math.min(step,span-offset),key,velocity,channel);
        }
    };
    return generator;
}

module.exports={createCompleteTremoloGenerator};
