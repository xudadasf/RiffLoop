"""Compare independent PDF predictions to local GP references, including misses."""
import argparse
import difflib
import hashlib
import html
import json
import re
import subprocess
from pathlib import Path
from fractions import Fraction
from recognize import recognize, overlay

CALIBRATION_FILES={'此生不换 (2).pdf','《默》-那英-DaMingBai313.pdf','PDF 谱.pdf','七重人格.pdf',
                   '《灰色轨迹》 间奏-大毛笔.pdf','双截棍.pdf','变相怪杰 吉他2.pdf','好想爱这个世界啊 吉他4.pdf',
                   '一路向北-大明白313.pdf','千万次奔向 木吉他.pdf','向阳而生 尾奏.pdf',
                   '好想爱这个世界啊 吉他3.pdf','晨光里有你.pdf','好想我回来啊.pdf',
                   '「青鸟」火影忍者OP3-大明白313.pdf'}


def normalized(s):
    return re.sub(r'[^\w\u4e00-\u9fff]','',s).lower()


def pair(pdf):
    candidates=sorted(list(pdf.parent.glob('*.gp'))+list(pdf.parent.glob('*.gp5')))
    if not candidates: return None
    exact=[p for p in candidates if normalized(p.stem)==normalized(pdf.stem)]
    if exact: return exact[0]
    if len(candidates)==1: return candidates[0]
    scored=sorted((difflib.SequenceMatcher(None,normalized(pdf.stem),normalized(p.stem)).ratio(),str(p)) for p in candidates)
    return Path(scored[-1][1]) if scored[-1][0]>.6 else None


def lcs_pairs(a,b):
    # Exact LCS within each numbered bar. No cross-bar alignment that hides shifts.
    dp=[[0]*(len(b)+1) for _ in range(len(a)+1)]
    for i in range(len(a)-1,-1,-1):
        for j in range(len(b)-1,-1,-1):
            dp[i][j]=1+dp[i+1][j+1] if a[i]==b[j] else max(dp[i+1][j],dp[i][j+1])
    i=j=0; pairs=[]
    while i<len(a) and j<len(b):
        if a[i]==b[j]: pairs.append((i,j)); i+=1; j+=1
        elif dp[i+1][j]>=dp[i][j+1]: i+=1
        else: j+=1
    return pairs


def flat_notes(beats):
    return [(n,b) for b in beats for n in b['notes']]


def rhythm(b):
    t=b['tuplet']; t=[1,1] if t[0]<=1 else t
    return b['duration'],b['dots'],tuple(t),b['grace']


def core_events(bar):
    """Canonical primary-voice timeline, including silence and tie destinations."""
    beats=[b for b in bar['beats'] if b.get('voice',0)==0]
    events=[]
    for b in beats:
        if b['duration'] is None: return None
        whole_rest=not b['notes'] and len(beats)==1 and (b.get('fullBarRest') or b.get('empty') or b['duration']==1)
        duration=Fraction(bar['meter'][0]*4,bar['meter'][1]) if whole_rest else (
            Fraction(4,b['duration'])*(2-Fraction(1,2**b['dots']))*
            (Fraction(*reversed(b['tuplet'])) if b['tuplet'][0]>1 else 1))
        notes=tuple(sorted((n['string'],n['fret'],n.get('dead',False),n.get('tie',False)) for n in b['notes']))
        events.append((duration,b['grace'],notes))
    return events


def compare(pred,track):
    by_number={b['number']:b for b in track['bars']}
    counts={'recognized':0,'reference':sum(len(flat_notes(b['beats'])) for b in track['bars']),
            'matched':0,'matched_with_rhythm':0,'exact_bars':0,'bars':len(track['bars']),
            'core_exact_bars':0,'predicted_ties':0,'matched_ties':0,
            'reference_ties':sum(n.get('tie',False) for b in track['bars'] for n,v in flat_notes(b['beats']))}
    details=[]
    for s in pred['systems']:
        for bar in s['bars']:
            a=flat_notes(bar['beats']); b=flat_notes(by_number.get(bar['number'],{'beats':[]})['beats'])
            keys=lambda notes:[(n['string'],n['fret']) for n,_ in notes]
            pairs=lcs_pairs(keys(a),keys(b))
            same_rhythm=sum(rhythm(a[i][1])==rhythm(b[j][1]) for i,j in pairs)
            counts['recognized']+=len(a); counts['matched']+=len(pairs); counts['matched_with_rhythm']+=same_rhythm
            counts['predicted_ties']+=sum(n.get('tie',False) for n,v in a)
            counts['matched_ties']+=sum(a[i][0].get('tie',False) and b[j][0].get('tie',False) for i,j in pairs)
            exact=len(a)==len(b)==len(pairs) and same_rhythm==len(a) and not bar['issues']
            counts['exact_bars']+=int(exact)
            rb=by_number.get(bar['number'])
            core=bool(rb and not bar['issues'] and bar.get('meter_source')=='pdf'
                      and bar['meter']==rb['meter'] and core_events(bar)==core_events(rb)
                      and not any(v['notes'] for v in rb['beats'] if v.get('voice',0)!=0))
            counts['core_exact_bars']+=int(core)
            details.append({'number':bar['number'],'predicted_notes':len(a),'reference_notes':len(b),
                            'matched':len(pairs),'rhythm_matched':same_rhythm,'issues':bar['issues'],
                            'note_rhythm_exact':exact,'core_exact':core})
    counts['precision']=counts['matched']/max(1,counts['recognized'])
    counts['recall']=counts['matched']/max(1,counts['reference'])
    counts['rhythm_recall']=counts['matched_with_rhythm']/max(1,counts['reference'])
    counts['core_complete']=counts['core_exact_bars']==counts['bars']
    return counts,details


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('materials',type=Path)
    parser.add_argument('--out',required=True,type=Path)
    parser.add_argument('--limit',type=int,default=0)
    parser.add_argument('--report-only',action='store_true',help='Rebuild HTML from existing results, without rerunning recognition')
    args=parser.parse_args(); args.out.mkdir(parents=True,exist_ok=True)
    if args.report_only:
        write_report(json.loads((args.out/'results.json').read_text(encoding='utf-8')),args.out)
        return
    pdfs=sorted(p for p in args.materials.rglob('*.pdf') if not p.name.startswith('._'))
    cases=[]
    for pdf in pdfs:
        gp=pair(pdf)
        if gp: cases.append((pdf,gp))
    if args.limit: cases=cases[:args.limit]
    report=[]
    for i,(pdf,gp) in enumerate(cases):
        folder=args.out/f'case-{i:03}'; folder.mkdir(exist_ok=True)
        entry={'case':folder.name,'pdf':str(pdf),'gp':str(gp),
               'calibration':pdf.name in CALIBRATION_FILES}
        try:
            pred=recognize(pdf)
            raw=json.dumps(pred,ensure_ascii=False,indent=2).encode('utf-8')
            (folder/'recognized.json').write_bytes(raw)
            entry['prediction_sha256']=hashlib.sha256(raw).hexdigest()
            # Reference is only opened AFTER prediction is written and hashed.
            run=subprocess.run(['node',str(Path(__file__).with_name('gp-reference.cjs')),str(gp),str(folder/'reference.json')],capture_output=True,text=True,encoding='utf-8')
            if run.returncode: raise RuntimeError(run.stderr[-400:])
            reference=json.loads((folder/'reference.json').read_text(encoding='utf-8'))
            tracks=[t for t in reference['tracks'] if len(t['tuning'])==6 and any(n for b in t['bars'] for v in b['beats'] for n in v['notes'])]
            numbers=[b['number'] for s in pred['systems'] for b in s['bars']]
            if not numbers:
                entry['status']='unsupported-no-six-line-staff'
            elif len(numbers)!=len(set(numbers)):
                entry['status']='unsupported-multiple-parts-or-repeated-bar-numbers'
            elif not tracks:
                entry['status']='no-six-string-reference'
            else:
                candidates=[(compare(pred,t),t['name']) for t in tracks]
                (counts,details),name=max(candidates,key=lambda c:c[0][0]['matched'])
                entry.update(status='evaluated',track=name,track_selection='best matching GP track, evaluation only',metrics=counts)
                selected=next(t for t in tracks if t['name']==name)
                naming=(normalized(gp.stem) in normalized(pdf.stem)
                        or difflib.SequenceMatcher(None,normalized(pdf.stem),normalized(gp.stem)).ratio()>.8)
                bar_coverage=len(set(numbers)&set(b['number'] for b in selected['bars']))/max(1,len(selected['bars']))
                entry['pairing_checks']={'filename_compatible':naming,'bar_coverage':bar_coverage,
                                         'note_overlap':counts['recall'],'status':'consistent' if naming and bar_coverage==1 and counts['recall']>.75 else 'uncertain'}
                (folder/'comparison.json').write_text(json.dumps(details,ensure_ascii=False,indent=2),encoding='utf-8')
            overlay(pdf,pred,folder/'overlay.pdf')
        except Exception as error:
            entry.update(status='error',error=str(error))
        report.append(entry)
        (args.out/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
        print(f'{i+1}/{len(cases)} {pdf.name}: {entry["status"]}',flush=True)
    write_report(report,args.out)


def write_report(report,out):
    statuses={'evaluated':'已逐小节对比','unsupported-no-six-line-staff':'未找到六线谱',
              'unsupported-multiple-parts-or-repeated-bar-numbers':'多分谱或重复小节号，暂不支持',
              'no-six-string-reference':'答案中无六弦轨道','error':'读取或评估失败'}
    rows=[]
    for e in report:
        m=e.get('metrics',{})
        metric=lambda k: f'{m[k]*100:.1f}%' if k in m else '—'
        links=' · '.join('<a href="'+e['case']+'/'+file+'">'+label+'</a>'
                         for file,label in [('overlay.pdf','对照图'),('comparison.json','逐小节结果')]
                         if (out/e['case']/file).exists()) or '无可用对照'
        core=str(m['core_exact_bars'])+'/'+str(m['bars']) if 'core_exact_bars' in m else '—'
        pairing={'consistent':'文件名、结构及音符相互支持','uncertain':'配对存疑，不作成功样例'}.get(e.get('pairing_checks',{}).get('status'),'—')
        rows.append('<tr><td>'+html.escape(Path(e['pdf']).name)+'</td><td>'+('规则调试及回归' if e['calibration'] else '回归检查')+'</td><td>'+html.escape(statuses.get(e['status'],e['status']))+'</td><td>'+pairing+'</td><td>'+metric('precision')+'</td><td>'+metric('recall')+'</td><td>'+metric('rhythm_recall')+'</td><td>'+core+'</td><td>'+str(m.get('reference','—'))+'</td><td>'+links+'</td></tr>')
    measured=[e['metrics'] for e in report if 'metrics' in e]
    counts={k:sum(m[k] for m in measured) for k in ('recognized','reference','matched','matched_with_rhythm')}
    summary=f"共 {len(report)} 组候选配对，{len(measured)} 组完成对比，其余 {len(report)-len(measured)} 组不支持或读取失败。以下百分比仅针对已完成对比的候选配对，不代表整个素材库的成功率。"
    summary+=f" 音符匹配率 {counts['matched']/max(1,counts['recognized']):.2%}；音符覆盖率 {counts['matched']/max(1,counts['reference']):.2%}；音符及节奏覆盖率 {counts['matched_with_rhythm']/max(1,counts['reference']):.2%}。"
    if any('core_exact_bars' in m for m in measured):
        summary+=f" 核心小节检查通过 {sum(m.get('core_exact_bars',0) for m in measured)} / {sum(m['bars'] for m in measured)}；全部核心小节通过的分谱 {sum(m.get('core_complete',False) for m in measured)} 份。"
    page='''<!doctype html><meta charset="utf-8"><title>PDF 六线谱识别实验</title>
<style>body{font:16px system-ui;margin:36px;background:#f6f7fa;color:#172337}h1{font-size:28px}table{border-collapse:collapse;width:100%;background:white}td,th{padding:12px;border-bottom:1px solid #ddd;text-align:left}th{background:#172337;color:white}p{max-width:1100px;line-height:1.7}a{color:#2459b9}</style>
<h1>PDF → GP 独立识别实验</h1><p>仅识别电子 PDF 的六线谱。蓝框是识别音符；绿框仅代表小节拍数检查通过，红框代表节奏待核对。绿色不等于音符、节奏、技巧全部正确。本工具不支持扫描图片、四弦贝斯和完整多声部识别。</p>
<p>识别先完成并保存哈希，之后才读取 GP 答案。按小节号比较弦号/品位，用小节内最长公共子序列匹配，遗漏音符计入召回率。节奏覆盖率额外要求时值、附点、连音比例、是否装饰音一致。新增的核心小节检查进一步逐拍比较第 1 声部的音符、休止、延音和拍号，其他声部有音符时不判为通过。演奏技巧、速度变化和原始反复结构未计入，核心检查通过不代表演奏效果完全还原。</p>
<p>GP 多轨时在评估阶段选择匹配最多的轨道。配对检查采用文件名、小节覆盖及音符重合情况，只是自动一致性检查，不是正确配对的保证。所有配对存疑、读取失败和不支持的结果均保留。不同分谱可能来自同一曲目，本批素材也曾用于上一轮评估，因此不宣称盲测。</p>
'''+ '<p>'+summary+'</p><table><tr><th>PDF</th><th>用途</th><th>状态</th><th>配对检查</th><th>识别音符匹配率</th><th>音符覆盖率</th><th>音符及节奏覆盖率</th><th>核心小节通过</th><th>答案音符数</th><th>详情</th></tr>'+''.join(rows)+'</table>'
    (out/'report.html').write_text(page,encoding='utf-8')


if __name__=='__main__': main()
