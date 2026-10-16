"""Run a complete evaluation round and keep a cross-score problem backlog."""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from diagnostics import diagnose,write_report

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
AUDITS={'slide':('slides','slide'),'staccato':('staccato','staccato'),
        'palm_mute':('palm-mute','palm-mute'),'ornament':('ornaments','ornament'),'tremolo':('tremolos','tremolo')}


def read(path):return json.loads(path.read_text(encoding='utf-8'))
def save(path,data):path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def problem_queue(summary):
    """Categories are investigation leads, never a claim of a shared root cause."""
    issues=[]
    groups={c['case']:c['group'] for c in summary['diagnostics']['cases']}
    def add(category,case,priority,detail):
        identity={k:detail[k] for k in ('bar','beat','string','fret','target_bar','target_fret') if k in detail}
        key=json.dumps([category,case,identity],sort_keys=True)
        issues.append({'id':hashlib.sha256(key.encode()).hexdigest()[:20],'category':category,'case':case,
                       'pairing':groups.get(case,'uncertain'),'priority':priority,'detail':detail})
    for case in summary['cases']:
        if case['status']!='evaluated':add('input/'+case['status'],case['case'],4,{})
    for case in summary['diagnostics']['cases']:
        for field,layer,priority in [('rhythm_differences','rhythm',0),('differences','core',2)]:
            for event in case[field]:add(layer+'/'+event['reason'],case['case'],priority,event)
    for key in AUDITS:
        for case in summary[key+'_audit']['cases']:
            for event in case.get('not_recognized',[]):
                add(key+'/'+event.get('pattern','missing'),case['case'],1,event)
    for case in summary['full_score_exports']:
        if case.get('error'):
            add('export/failed',case['case'],0,{'error':case['error']});continue
        for mode,result in [('app',case),('experimental',case['experimental'])]:
            for check,passed in result['checks'].items():
                if not passed:add('playback/'+mode+'/'+check,case['case'],0,result.get('differences',{}).get(check,{}))
    buckets=collections.defaultdict(list)
    for issue in issues:buckets[issue['category'],issue['pairing']].append(issue)
    queue=[{'category':key[0],'pairing':key[1],'priority':min(i['priority'] for i in items),
            'case_count':len({i['case'] for i in items}),'cases':sorted({i['case'] for i in items}),
            'issue_count':len(items),'issues':items} for key,items in buckets.items()]
    return sorted(queue,key=lambda g:(g['pairing']!='consistent',g['priority'],-g['case_count'],-g['issue_count'],g['category']))


def find_regressions(before,after):
    regressions=[]
    old={c['case']:c for c in before['cases']};new={c['case']:c for c in after['cases']}
    if old.keys()!=new.keys():regressions.append({'layer':'candidates','reason':'candidate-set-changed'})
    for case,prior in old.items():
        if case not in new:continue
        if prior['pdf']!=new[case]['pdf']:regressions.append({'case':case,'layer':'input','reason':'pdf-changed'})
        if prior['status']=='evaluated' and new[case]['status']!='evaluated':
            regressions.append({'case':case,'layer':'evaluation','reason':'previously-evaluated-case-lost'})
    current={c['case']:c for c in after['diagnostics']['cases']}
    for prior in before['diagnostics']['cases']:
        case=prior['case'];now=current.get(case)
        if now is None:continue  # Loss is recorded above, not silently counted as a pass.
        if prior['bars']!=now['bars'] or prior['group']!=now['group']:
            regressions.append({'case':case,'layer':'comparison','reason':'reference-bars-or-pairing-group-changed'})
        for field in ('differences','rhythm_differences'):
            old_pass=set(range(1,prior['bars']+1))-{e['bar'] for e in prior[field]}
            new_pass=set(range(1,now['bars']+1))-{e['bar'] for e in now[field]}
            for bar in sorted(old_pass-new_pass):regressions.append({'case':case,'layer':field,'bar':bar})
    current={c['case']:c for c in after['full_score_exports']}
    for prior in before['full_score_exports']:
        if prior.get('error'):continue
        case=prior['case'];now=current.get(case)
        if now is None or now.get('error'):
            regressions.append({'case':case,'layer':'export','reason':'previous-export-lost'});continue
        for mode,left,right in [('app',prior,now),('experimental',prior['experimental'],now['experimental'])]:
            for check,passed in left['checks'].items():
                if passed and not right['checks'].get(check):regressions.append({'case':case,'layer':mode,'check':check})
    for key in AUDITS:
        audit=after[key+'_audit']
        for event in audit['regressions']:regressions.append({'layer':key,'reason':'verified-event-lost',**event})
        for case in audit['cases']:
            for event in case.get('mismatched',[]):regressions.append({'layer':key,'case':case['case'],'reason':'mismatched','event':event})
    return regressions


def compare_queues(before,after):
    flatten=lambda queue:{i['id']:i for group in queue for i in group['issues']}
    old,new=flatten(before),flatten(after)
    return {'new':[new[k] for k in sorted(new.keys()-old.keys())],
            'resolved':[old[k] for k in sorted(old.keys()-new.keys())],
            'remaining_count':len(old.keys()&new.keys())}


def run_command(args,log,allowed=(0,)):
    with log.open('w',encoding='utf-8') as stream:
        result=subprocess.run([str(a) for a in args],cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,
                              env={**os.environ,'PYTHONIOENCODING':'utf-8'})
    if result.returncode not in allowed:raise RuntimeError(f'{log.name}: exit {result.returncode}')
    return result.returncode


def export_case(row,batch,out,baseline):
    case=row['case'];folder=out/case;folder.mkdir()
    data=read(batch/case/'recognized.json');save(folder/'recognized.json',data)
    tracks=[t for t in read(batch/case/'reference.json')['tracks'] if t['name']==row['track'] and len(t['tuning'])==6]
    prior=next((c for c in baseline['full_score_exports'] if c['case']==case and not c.get('error')),None)
    if prior:
        tracks=[t for t in tracks if t['track']==prior['verification']['reference_track_index']
                and t['staff']==prior['verification']['reference_staff_index']]
    if len(tracks)!=1 or tracks[0]['staff']!=0:raise ValueError('Missing or ambiguous reference track')
    index=tracks[0]['track'];numbers=[b['number'] for s in data['systems'] for b in s['bars']]
    if numbers!=list(range(1,max(numbers)+1)):raise ValueError('Full-score bars must be consecutive from 1')
    gp=folder/'experimental.gp'
    run_command(['node',HERE/'gp-export.cjs',folder/'recognized.json',gp],folder/'export.log')
    run_command([sys.executable,HERE/'verify_export.py',gp,row['gp'],'--track',row['track'],'--track-index',index,
                 '--bars',f'1-{max(numbers)}','--out',folder/'verification.json'],folder/'verification.log')
    verification=read(folder/'verification.json')
    if not verification['passed']:raise ValueError('Export verification failed')
    reports=[]
    for name,extra in [('app',[]),('experimental',['--complete-tremolos'])]:
        output=folder/f'{name}.json'
        code=run_command(['node',HERE/'verify-playback.cjs',gp,row['gp'],index,output,*extra],folder/f'{name}.log',(0,1))
        report=read(output)
        if code!=int(not report['passed']):raise ValueError('Playback exit status contradicts report')
        reports.append(report)
    return {'case':case,'pdf':Path(row['pdf']).name,'gp_sha256':digest(gp),'verification':verification,
            **reports[0],'experimental':reports[1]}


def run_round(materials,baseline_file,pairing,out):
    baseline=read(baseline_file)
    baseline_hash=digest(baseline_file);pairing_hash=digest(pairing/'results.json')
    if out.resolve().is_relative_to(materials.resolve()):raise ValueError('Output must be outside the original materials')
    # Refuse overwriting a round, including a failed or partial round.
    out.mkdir(parents=True,exist_ok=False);logs=out/'logs';logs.mkdir()
    save(out/'state.json',{'status':'running'})
    try:
        frozen=read(pairing/'results.json')
        if {r['case'] for r in frozen}!={r['case'] for r in baseline['cases']}:
            raise ValueError('Pairing and validation baselines contain different candidates')
        inputs=[{'case':r['case'],'pdf':digest(Path(r['pdf'])),'gp':digest(Path(r['gp']))} for r in frozen]
        if baseline.get('input_hashes') is not None and inputs!=baseline['input_hashes']:
            raise ValueError('Materials changed since baseline; establish a separate corpus explicitly')
        source_files=sorted([*HERE.glob('*.py'),*HERE.glob('*.cjs'),ROOT/'RiffLoop/Resources/GpWeb/alphaTab.min.js'])
        hashes={str(p.relative_to(ROOT)):digest(p) for p in source_files}
        print('Running automatic tests',flush=True)
        run_command([sys.executable,'-m','unittest','discover','-s',HERE,'-p','test*.py'],logs/'tests.log')
        batch=out/'benchmark'
        print('Recognizing and comparing all PDF/GP candidates',flush=True)
        run_command([sys.executable,HERE/'evaluate.py',materials,'--out',batch],logs/'evaluation.log')
        rows=read(batch/'results.json')
        diagnostics=diagnose(batch,pairing);write_report(diagnostics,batch)
        audits={}
        for key,(command,filename) in AUDITS.items():
            print('Checking '+key,flush=True)
            run_command(['node',HERE/f'audit-{command}.cjs',batch,baseline_file],logs/f'{key}.log',(0,1))
            audits[key+'_audit']=read(batch/f'{filename}-audit.json')
        exports=[];export_folder=out/'exports';export_folder.mkdir()
        for row in rows:
            if not row.get('metrics',{}).get('core_complete'):continue
            print('Exporting and checking playback: '+row['case'],flush=True)
            try:exports.append(export_case(row,batch,export_folder,baseline))
            except (RuntimeError,ValueError,OSError) as error:
                exports.append({'case':row['case'],'pdf':Path(row['pdf']).name,'error':str(error)})
        if hashes!={str(p.relative_to(ROOT)):digest(p) for p in source_files}:
            raise ValueError('Experiment source changed during this round')
        if inputs!=[{'case':r['case'],'pdf':digest(Path(r['pdf'])),'gp':digest(Path(r['gp']))} for r in frozen]:
            raise ValueError('Materials changed during this round')
        if baseline_hash!=digest(baseline_file) or pairing_hash!=digest(pairing/'results.json'):
            raise ValueError('Validation or pairing baseline changed during this round')
        result={'baseline_file':baseline_file.name,'baseline_sha256':baseline_hash,'input_hashes':inputs,
                'source_hashes':hashes,'candidates':len(rows),'diagnostics':diagnostics,'full_score_exports':exports,
                'cases':[{'case':r['case'],'pdf':Path(r['pdf']).name,'status':r['status'],
                          'metrics':r.get('metrics'),'prediction_sha256':r.get('prediction_sha256')} for r in rows],**audits}
        result['regressions']=find_regressions(baseline,result)
        result['queue']=problem_queue(result)
        result['queue_changes']=compare_queues(problem_queue(baseline),result['queue'])
        result['status']='regression' if result['regressions'] else 'no-regressions'
        result['playback_passed']=sum(e.get('passed',False) for e in exports)
        result['full_score_exports_count']=sum(not e.get('error') for e in exports)
        result['core_pass_bars']=sum(g['counts']['pass'] for g in diagnostics['groups'].values())
        result['rhythm_pass_bars']=sum(g['rhythm_counts']['pass'] for g in diagnostics['groups'].values())
        result['reference_bars']=sum(g['bars'] for g in diagnostics['groups'].values())
        save(out/'summary.json',result)
        write_round_report(result,out)
        save(out/'state.json',{'status':result['status'],'summary':'summary.json'})
        return result
    except Exception as error:
        save(out/'state.json',{'status':'failed','error':str(error)})
        raise


def write_round_report(result,out):
    changes=result['queue_changes']
    lines=['# PDF 转谱批量回归',
           f"本轮 {result['candidates']} 组候选，完整导出 {result['full_score_exports_count']} 份，全部所测播放时序一致 {result['playback_passed']} 份。",
           f"历史通过项退步 {len(result['regressions'])} 项；问题记录新增 {len(changes['new'])} 条，解决 {len(changes['resolved'])} 条，仍存在 {changes['remaining_count']} 条。",
           '无退步不等于全部转换成功。分类是调查入口，不自动证明根因；同一小节可有多条记录，两个播放引擎分别记录，数量不能当作独立音乐错误数。',
           '## 按跨曲影响排序的问题',
           '| 分类 | 配对分组 | 受影响分谱 | 记录数 | 样例 |',
           '| --- | --- | ---: | ---: | --- |']
    for group in result['queue']:
        lines.append(f"| {group['category']} | {group['pairing']} | {group['case_count']} | {group['issue_count']} | {', '.join(group['cases'][:5])} |")
    lines.extend(['','详细小节、音符、播放差异示例及新增/已解决记录见 [summary.json](summary.json)。',
                  '下一轮优先调查影响多首且与练习节奏有关的类别，确认谱面证据后修改通用规则，再运行完整回归。不要通过降低判定门槛消除问题记录。'])
    (out/'report.md').write_text('\n\n'.join(lines[:5])+'\n\n'+'\n'.join(lines[5:])+'\n',encoding='utf-8')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('materials',type=Path)
    parser.add_argument('--baseline',required=True,type=Path,help='Previous validation summary, including diagnostics, audits and both playback modes')
    parser.add_argument('--pairing-baseline',required=True,type=Path,help='Frozen results.json directory; preserves candidate identities and pairing groups')
    parser.add_argument('--out',required=True,type=Path,help='New directory, never reused')
    args=parser.parse_args()
    result=run_round(args.materials.resolve(),args.baseline.resolve(),args.pairing_baseline.resolve(),args.out.resolve())
    print(json.dumps({'status':result['status'],'playback_passed':result['playback_passed'],'regressions':len(result['regressions'])}))
    raise SystemExit(bool(result['regressions']))
