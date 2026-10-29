"""Editable offline region plans and validated recropping for recognition."""
import html
import json
import math
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent


def write_editor(folder, manifest, outcome):
    if not manifest.get('complete') or not manifest.get('pages'):
        (folder/'review.html').write_text('<!doctype html><meta charset="utf-8"><h1>分区未完成</h1><p>'
            +html.escape(outcome['message'])+'</p><p>请重新完成分区后再确认。</p>',encoding='utf-8')
        return
    payload = json.dumps({**manifest,'review_folder':str(folder.resolve())},ensure_ascii=False).replace('<','\\u003c')
    css=(ROOT/'region_review.css').read_text(encoding='utf-8')
    js=(ROOT/'region_review.js').read_text(encoding='utf-8')
    document=f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>乐谱分区确认 · RiffLoop</title>
<style>{css}</style><body><header><h1>乐谱分区确认</h1><p>{html.escape(Path(manifest['source']).name)}</p>
<p>先看每页是否漏谱，再决定采用哪些框。候选框可能含文字或指板图；绿色建议框也需要人工确定。</p>
<p>可以补画、重画、取消采用。保存方案后，在桌面程序点击“导入分区确认方案”；只裁剪已确认页中采用的区域。</p>
<div class="toolbar"><button id="save">保存分区方案</button><button id="load">载入已保存方案</button>
<input id="plan-file" type="file" accept=".json" hidden><span id="progress"></span></div></header>
<nav class="toolbar"><button id="prev">上一页</button><select id="page" aria-label="选择 PDF 页码"></select>
<button id="next">下一页</button><button id="unconfirmed">下一未确认页</button>
<button id="confirm">确认本页并下一页</button><label>放大 <select id="zoom" aria-label="谱图缩放"><option value="1">适合窗口</option>
<option value="1.5">150%</option><option value="2">200%</option><option value="3">300%</option></select></label></nav>
<p id="feedback" role="status" aria-live="polite"></p><main><section>
<div class="toolbar"><button id="add">补画区域</button><button id="redraw">重画所选框</button><button id="remove">删除所选框</button>
<span id="page-status"></span></div><p class="tip">蓝框是当前所选；勾选“采用”决定是否识别。点击“补画”或“重画”后，在谱图上拖出完整区域。</p>
<div id="stage"><div id="sheet"><img id="source" alt="未画框的原页"><svg id="overlay" xmlns="http://www.w3.org/2000/svg" aria-label="可编辑分区框"></svg></div></div>
</section><aside><h2>本页区域</h2><p>按列表顺序输出，可用 ↑ ↓ 调整。一个连续练习可画成一个大框，并取消原来的小框。</p>
<div id="regions"></div><p class="tip">没有候选框的页也要查看原图；无谱页可直接确认。修改已确认页会取消该页的确认状态。
区域之间默认空 1 小节，导入后在拼接窗口调整。</p></aside></main>
<script id="region-data" type="application/json">{payload}</script><script>{js}</script></body></html>'''
    (folder/'review.html').write_text(document,encoding='utf-8')


def validate_plan(plan, manifest):
    if not isinstance(plan,dict):
        raise ValueError('请选择浏览器保存的 RiffLoop 分区方案')
    if not manifest.get('document_id') or plan.get('format') != 'riffloop-region-plan-v1' or plan.get('document_id') != manifest['document_id']:
        raise ValueError('确认方案不属于这次分区，请选中对应的 PDF 分区结果')
    if not manifest.get('complete'):
        raise ValueError('这次分区未完成，请重新分区后确认')
    pages=plan.get('pages')
    if not isinstance(pages,list) or len(pages)!=len(manifest['pages']):
        raise ValueError('方案页数与分区记录不一致')
    selected=[]
    for entry, original in zip(pages,manifest['pages']):
        if entry.get('page')!=original['page'] or type(entry.get('confirmed')) is not bool:
            raise ValueError('方案页码或确认状态无效')
        regions=entry.get('regions')
        if not isinstance(regions,list) or len(regions)>1000:
            raise ValueError('方案区域列表无效')
        adopted=[]
        for index,r in enumerate(regions,1):
            box=r.get('box')
            if not isinstance(box,list) or len(box)!=4 or any(type(v) not in (int,float) or not math.isfinite(v) for v in box):
                raise ValueError('分区坐标无效')
            x0,y0,x1,y1=box
            if not (0<=x0<x1<=original['width'] and 0<=y0<y1<=original['height']) or x1-x0<10 or y1-y0<10:
                raise ValueError('分区框超出原页或过小，请重新画框')
            if type(r.get('selected')) is not bool:
                raise ValueError('区域采用状态无效')
            if entry['confirmed'] and r['selected']:
                for a in adopted:
                    intersection=max(0,min(a[2],x1)-max(a[0],x0))*max(0,min(a[3],y1)-max(a[1],y0))
                    if intersection>min((a[2]-a[0])*(a[3]-a[1]),(x1-x0)*(y1-y0))*.15:
                        raise ValueError(f'第 {entry["page"]} 页采用框明显重叠，请取消重复框或重画，避免重复识别')
                adopted.append(box)
                selected.append((original,index,[round(v) for v in box]))
    if not any(p['confirmed'] for p in pages):
        raise ValueError('尚未确认任何页面，请先查看原页并点击“确认本页”')
    if not selected:
        raise ValueError('已确认页中没有采用的乐谱区域；未生成空识别队列')
    return selected


def apply_region_plan(plan_path, source_folder, target_folder):
    source_folder,target_folder=Path(source_folder).resolve(),Path(target_folder).resolve()
    manifest=json.loads((source_folder/'regions.json').read_text(encoding='utf-8'))
    plan=json.loads(Path(plan_path).read_text(encoding='utf-8'))
    selected=validate_plan(plan,manifest)
    target_folder.mkdir(parents=True,exist_ok=True)
    if any(target_folder.iterdir()):
        raise ValueError('确认结果目录必须为空，避免覆盖已有文件')
    sources=[]
    for page,index,box in selected:
        image_path=(source_folder/page['original']).resolve()
        if not image_path.is_relative_to(source_folder) or not image_path.is_file():
            raise ValueError('缺少本次分区的原页图片，请重新分区')
        with Image.open(image_path) as image:
            if image.size!=(page['width'],page['height']):
                raise ValueError('原页尺寸与分区记录不同，请重新分区')
            output=target_folder/f'page-{page["page"]:03d}-region-{index:02d}.png'
            image.crop(box).save(output)
            sources.append(str(output))
    confirmed=sum(p['confirmed'] for p in plan['pages'])
    result={'source':manifest['source'],'folder':str(target_folder),'draft':None,'is_regions':True,
            'status':'人工分区已应用','region_sources':sources,'region_report':str(source_folder/'review.html'),
            'message':f'已按确认方案重新裁剪 {len(sources)} 个区域，来自 {confirmed}/{len(plan["pages"])} 个已确认页。'
                      '未确认页不包含；区域间默认空 1 小节，可在拼接设置中修改。'}
    (target_folder/'applied-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2),encoding='utf-8')
    (target_folder/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    previews=''.join('<section><h2>'+html.escape(Path(path).name)+'</h2><img style="max-width:100%" src="'
                     +html.escape(Path(path).name,quote=True)+'" alt="按人工边界重新裁剪的谱区"></section>' for path in sources)
    (target_folder/'review.html').write_text('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>body{font:16px/1.6 system-ui,sans-serif;max-width:1100px;margin:auto;padding:24px}section{margin:24px 0}</style>'
        '<h1>人工分区已应用</h1><p>'
        +html.escape(result['message'])+'</p><a href="'+html.escape((source_folder/'review.html').as_uri(),quote=True)
        +'">返回分区编辑页面</a> · <a href="applied-plan.json" download>已应用的分区方案</a>'
        '<p>裁剪图已加入桌面程序，可选择拼接生成新的 GP。继续修改时，在分区编辑页面载入已应用的方案。</p>'
        +previews,encoding='utf-8')
    return result
