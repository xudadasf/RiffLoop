"""Evaluation only: separate pairing uncertainty from reference-bar differences."""
import argparse
import collections
import html
import json
from pathlib import Path

from evaluate import core_events

REASONS={
    'pass':'核心检查通过',
    'missing_bar':'未识别到对应小节',
    'multiple_voices':'参考含多个有音符的声部',
    'meter':'拍号未知或不一致',
    'unknown_duration':'存在未识别时值',
    'notes':'音符序列差异',
    'rhythm_rests':'节奏或休止差异',
    'ties_only':'仅延音标记差异',
    'validation':'其他导出校验未通过',
}
GROUPS={'consistent':'配对有一致性支持','uncertain':'配对证据不足'}
RHYTHM_REASONS={k:REASONS[k] for k in ('pass','missing_bar','multiple_voices','meter','unknown_duration','validation')}
RHYTHM_REASONS.update({'pass':'节奏序列检查通过','timing_attack_rest':'时值、起音、延续或休止差异'})


def failure_reason(bar,reference):
    """One first differing layer per reference bar, not a claim of root cause."""
    if bar is None:return 'missing_bar'
    if any(v['notes'] for v in reference['beats'] if v.get('voice',0)!=0):return 'multiple_voices'
    if bar.get('meter_source')!='pdf' or bar['meter']!=reference['meter']:return 'meter'
    actual,expected=core_events(bar),core_events(reference)
    if actual is None or expected is None:return 'unknown_duration'
    notes=lambda events:[(s,f,d,g) for t,g,ns in events for s,f,d,tie in ns]
    untied=lambda events:[(t,g,tuple((s,f,d) for s,f,d,tie in ns)) for t,g,ns in events]
    if notes(actual)!=notes(expected):return 'notes'
    if untied(actual)!=untied(expected):return 'rhythm_rests'
    if actual!=expected:return 'ties_only'
    return 'validation' if bar['issues'] else 'pass'


def rhythm_reason(bar,reference):
    """Compare beat timing and attack/hold/rest presence independently of pitch."""
    reason=failure_reason(bar,reference)
    if reason in ('missing_bar','multiple_voices','meter','unknown_duration'):return reason
    def sequence(score):
        return [(duration,grace,any(not tie for s,f,d,tie in notes),any(tie for s,f,d,tie in notes))
                for duration,grace,notes in core_events(score)]
    if sequence(bar)!=sequence(reference):return 'timing_attack_rest'
    return 'validation' if bar['issues'] else 'pass'


def diagnose(folder,pairing_baseline=None):
    read=lambda path:json.loads(path.read_text(encoding='utf-8'))
    rows=read(folder/'results.json')
    pairing_rows=rows if pairing_baseline is None else read(pairing_baseline/'results.json')
    pairing={r['case']:r for r in pairing_rows}
    if set(pairing)!={r['case'] for r in rows}:raise ValueError('Pairing baseline has a different candidate set')
    groups={g:{'cases':0,'bars':0,'counts':dict.fromkeys(REASONS,0),
               'rhythm_counts':dict.fromkeys(RHYTHM_REASONS,0)} for g in GROUPS}
    cases=[]
    for row in rows:
        if row['status']!='evaluated':continue
        pred=read(folder/row['case']/'recognized.json')
        reference=read(folder/row['case']/'reference.json')
        tracks=[t for t in reference['tracks'] if t['name']==row['track'] and len(t['tuning'])==6
                and any(v['notes'] for b in t['bars'] for v in b['beats'])]
        if len(tracks)!=1:raise ValueError('Missing or ambiguous evaluation track: '+row['case'])
        bars=[b for s in pred['systems'] for b in s['bars']]
        if len({b['number'] for b in bars})!=len(bars):raise ValueError('Repeated PDF bar numbers: '+row['case'])
        by_number={b['number']:b for b in bars}
        counts=dict.fromkeys(REASONS,0);differences=[]
        rhythm_counts=dict.fromkeys(RHYTHM_REASONS,0);rhythm_differences=[]
        for rb in tracks[0]['bars']:
            bar=by_number.get(rb['number']);reason=failure_reason(bar,rb);counts[reason]+=1
            if reason!='pass':differences.append({'bar':rb['number'],'reason':reason})
            rhythm=rhythm_reason(bar,rb);rhythm_counts[rhythm]+=1
            if rhythm!='pass':rhythm_differences.append({'bar':rb['number'],'reason':rhythm})
        if counts['pass']!=row['metrics']['core_exact_bars']:
            raise ValueError('Classification disagrees with frozen evaluation: '+row['case'])
        basis=pairing[row['case']]
        if any(basis.get(key)!=row.get(key) for key in ('pdf','gp')):
            raise ValueError('Pairing baseline refers to different files: '+row['case'])
        group=basis.get('pairing_checks',{}).get('status','uncertain')
        if group not in GROUPS:group='uncertain'
        groups[group]['cases']+=1;groups[group]['bars']+=len(tracks[0]['bars'])
        for reason,count in counts.items():groups[group]['counts'][reason]+=count
        for reason,count in rhythm_counts.items():groups[group]['rhythm_counts'][reason]+=count
        cases.append({'case':row['case'],'pdf':Path(row['pdf']).name,'group':group,
                      'current_pairing_status':row.get('pairing_checks',{}).get('status','uncertain'),
                      'bars':len(tracks[0]['bars']),'counts':counts,'differences':differences,
                      'rhythm_counts':rhythm_counts,'rhythm_differences':rhythm_differences})
    return {'candidate_count':len(rows),'pairing_basis':pairing_baseline.name if pairing_baseline else 'current-results',
            'statuses':dict(collections.Counter(r['status'] for r in rows)),
            'groups':groups,'cases':cases,
            'method':'One first differing layer per reference bar: missing, voices, meter, unknown duration, notes, rhythm/rests, ties, validation. Counts are not independent root causes.',
            'rhythm_method':'Exact voice-0 beat durations, grace flags and attack/hold/rest presence with confirmed meter and validation. Ignores pitch and chord size; does not establish tempo, repeats, grace placement or audible timing.',
            'pairing_caution':'Consistency is an automatic check, not proof of matching editions. Keep both groups; do not use the supported subset as overall success.'}


def write_report(result,folder):
    (folder/'diagnostics.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    groups=result['groups']
    summary=''.join(f'<p>{GROUPS[g]}：{data["cases"]} 份，核心小节通过 {data["counts"]["pass"]}/{data["bars"]}'
                    f'（{data["counts"]["pass"]/max(1,data["bars"]):.2%}）。</p>' for g,data in groups.items())
    counts=''.join('<tr><td>'+label+'</td>'+''.join(f'<td>{groups[g]["counts"][reason]}</td>' for g in GROUPS)+'</tr>'
                   for reason,label in REASONS.items())
    cases=''
    for group,label in GROUPS.items():
        cases+='<h2>'+label+'</h2><table><tr><th>PDF</th><th>通过/总小节</th><th>首个差异分类</th></tr>'
        for case in sorted((c for c in result['cases'] if c['group']==group),key=lambda c:c['bars']-c['counts']['pass'],reverse=True):
            failures='；'.join(f'{REASONS[k]} {v}' for k,v in case['counts'].items() if k!='pass' and v) or '无'
            cases+='<tr><td>'+html.escape(case['pdf'])+'</td><td>'+f'{case["counts"]["pass"]}/{case["bars"]}'+'</td><td>'+failures+'</td></tr>'
        cases+='</table>'
    page='''<!doctype html><meta charset="utf-8"><title>PDF 转谱错误分类</title>
<style>body{font:16px system-ui;max-width:1200px;margin:32px auto;padding:0 20px;color:#172337}p{line-height:1.7}table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #ddd;padding:10px;text-align:left}th{background:#eef2f7}</style>
<h1>PDF 转谱错误分类</h1><p>配对有一致性支持仍不保证是同一版本。配对证据不足的素材单独列出，不作为确定的识别错误，也不从全体结果中删除。</p>
<p>每个参考小节只归入首个不同层级：小节缺失 → 多声部 → 拍号 → 未知时值 → 音符序列 → 节奏/休止 → 延音 → 其他校验。分类是定位入口，并不证明唯一根因；例如漏掉延续和弦会归入音符序列差异。</p>'''
    excluded=result['candidate_count']-sum(g['cases'] for g in groups.values())
    page+=f'<p>共 {result["candidate_count"]} 组候选，{excluded} 组不支持或读取失败，未进入逐小节分类；详见 <a href="report.html">完整评估报告</a>。详细小节号见 <a href="diagnostics.json">分类数据</a>。</p>'
    if result['pairing_basis']!='current-results':
        page+='<p>本报告固定采用历史评估 '+html.escape(result['pairing_basis'])+' 的配对分组，避免识别提升使素材跨组、改变比较范围。当前自动配对检查仍保留在完整评估报告和分类数据中。</p>'
    page+=summary+'<table><tr><th>分类</th>'+''.join('<th>'+v+'</th>' for v in GROUPS.values())+'</tr>'+counts+'</table>'+cases
    page+='<h2>节奏优先检查</h2><p>逐拍比较时值、装饰音标志，以及是否起音、延续或休止，并检查拍号。即使总拍数相同，起音位置或休止位置不同也不通过。此项忽略品位、弦位及和弦音符数量，不替代核心检查；不验证速度、中途变速、反复、装饰音具体落点或实际听感。详细失败小节保存在分类数据的 rhythm_differences 中。</p>'
    page+='<table><tr><th>节奏分类</th>'+''.join('<th>'+v+'</th>' for v in GROUPS.values())+'</tr>'
    page+=''.join('<tr><td>'+label+'</td>'+''.join(f'<td>{groups[g]["rhythm_counts"][reason]}</td>' for g in GROUPS)+'</tr>'
                  for reason,label in RHYTHM_REASONS.items())+'</table>'
    (folder/'diagnostics.html').write_text(page,encoding='utf-8')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('benchmark',type=Path)
    parser.add_argument('--pairing-baseline',type=Path,help='Freeze grouping to the same candidates in a prior evaluation')
    args=parser.parse_args();result=diagnose(args.benchmark,args.pairing_baseline);write_report(result,args.benchmark)
    print(json.dumps({'candidate_count':result['candidate_count'],'groups':result['groups']},ensure_ascii=False))
