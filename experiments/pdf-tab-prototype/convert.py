"""Standalone experimental PDF -> GP. No reference score is an input."""
import argparse
import json
import subprocess
import html
from pathlib import Path
from recognize import recognize, overlay

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('pdf',type=Path)
parser.add_argument('--out',required=True,type=Path)
parser.add_argument('--bars',default='all',help='Explicit PDF bar selection, e.g. 2-9; default exports the full PDF or blocks')
args=parser.parse_args()
args.out.mkdir(parents=True,exist_ok=True)
# Invalidate the previous GP even if reading the new PDF fails.
output=args.out/'experimental.gp'
if output.exists(): output.unlink()
result=recognize(args.pdf)
path=args.out/'recognized.json'
path.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
overlay(args.pdf,result,args.out/'overlay.pdf')
bars=[b for s in result['systems'] for b in s['bars']]
rows=''.join('<tr><td>'+str(b['number'])+'</td><td>'+str(sum(len(x['notes']) for x in b['beats']))+'</td><td>'+html.escape('；'.join(b['issues']) or '拍数检查通过，仍不代表音符与技巧全部正确')+'</td></tr>' for b in bars)
warnings=''.join('<li>'+html.escape(w)+'</li>' for w in result['warnings']+result.get('structure_issues',[]))
(args.out/'review.html').write_text('<!doctype html><meta charset="utf-8"><title>识别结果</title><style>body{font:16px system-ui;margin:36px}td,th{padding:9px;border-bottom:1px solid #ddd;text-align:left}p{max-width:900px;line-height:1.7}</style><h1>PDF 六线谱识别实验稿</h1><p>'+html.escape(args.pdf.name)+'</p><p>只识别电子 PDF。支持部分休止符、延音、附点及变拍号；扫描谱、多声部和完整演奏技巧仍不支持。拍号未识别时阻止导出。绿色小节仅说明时值合计通过，不代表完全正确。</p><ul>'+warnings+'</ul><p><a href="overlay.pdf">查看原谱标记：蓝框音符、红框待核对小节</a></p><table><tr><th>小节</th><th>识别音符数</th><th>状态</th></tr>'+rows+'</table>',encoding='utf-8')
completed=subprocess.run(['node',str(Path(__file__).with_name('gp-export.cjs')),str(path),
                          str(output),args.bars])
raise SystemExit(completed.returncode)
