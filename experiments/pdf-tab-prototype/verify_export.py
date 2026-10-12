"""Evaluation only: verify an exported excerpt against an original GP track."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

from evaluate import core_events


def tempo_sequence(score,first,last):
    active=score['tempo'];linear=False;changes=[]
    for event in sorted(score.get('tempo_events',[]),key=lambda e:(e['bar'],e['position'])):
        if event['bar']<first or event['bar']==first and event['position']==0:
            active=event['bpm'];linear=event['linear']
        elif first<=event['bar']<=last:
            changes.append((event['bar']-first+1,event['position'],event['bpm'],event['linear']))
    result=[(1,0,active,linear)]
    for event in changes:
        if event[2:]!=result[-1][2:] or event[3]:result.append(event)
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('exported',type=Path)
    parser.add_argument('reference',type=Path)
    parser.add_argument('--track',required=True)
    parser.add_argument('--track-index',type=int,help='Optional zero-based original GP track index to resolve duplicate names')
    parser.add_argument('--bars',required=True,help='Contiguous original bar range, e.g. 10-13')
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    first,last=map(int,args.bars.split('-'))
    if first<1 or last<first: raise ValueError('Invalid range')
    with tempfile.TemporaryDirectory() as folder:
        scores=[]
        for i,path in enumerate((args.exported,args.reference)):
            output=Path(folder)/f'{i}.json'
            subprocess.run(['node',str(Path(__file__).with_name('gp-reference.cjs')),str(path),str(output)],check=True)
            scores.append(json.loads(output.read_text(encoding='utf-8')))
    actual,original=scores
    tracks=[t for t in original['tracks'] if t['name']==args.track and len(t['tuning'])==6
            and (args.track_index is None or t['track']==args.track_index)]
    if len(tracks)!=1: raise ValueError('Reference track is missing or ambiguous')
    expected=tracks[0]
    chosen=expected['bars'][first-1:last]
    received=actual['tracks'][0]
    differences=[]
    if len(chosen)!=last-first+1 or len(chosen)!=len(received['bars']): differences.append('bar count')
    if received['tuning']!=expected['tuning']: differences.append('tuning')
    expected_tempos=tempo_sequence(original,first,last)
    actual_tempos=tempo_sequence(actual,1,len(received['bars']))
    if actual['tempo']!=expected_tempos[0][2]: differences.append('initial tempo')
    if actual_tempos!=expected_tempos: differences.append('tempo changes')

    for a,b in zip(received['bars'],chosen):
        if any(v['notes'] for v in b['beats'] if v['voice']!=0):
            differences.append(f"bar {b['number']}: multiple voices unsupported")
        if core_events(a)!=core_events(b) or a['meter']!=b['meter']:
            differences.append(f"bar {b['number']}: notes, rhythm, rests, ties or meter differ")
    result={'reference':args.reference.name,'track':args.track,'source_bars':args.bars,
            'reference_track_index':expected['track'],'reference_staff_index':expected['staff'],
            'bars':len(chosen),'notes':sum(len(v['notes']) for b in chosen for v in b['beats'] if v['voice']==0),
            'passed':not differences,'differences':differences,
            'checked':['string/fret/dead/tie','rational duration/dots/tuplet/grace flag','voice-0 beat sequence including full-bar silence','meter','tuning','initial tempo','tempo changes'],
            'not_checked':['techniques','repeat structures','audible playback']}
    args.out.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
