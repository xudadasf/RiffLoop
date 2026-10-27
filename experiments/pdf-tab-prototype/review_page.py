"""Offline review-page presentation shared by image and vector PDF results."""
import html
from pathlib import Path

ROOT = Path(__file__).resolve().parent
esc = lambda value: html.escape(str(value), quote=True)


def render_review(source, folder, outcome, body, *, notes, bars, issues, settings='', guidance=''):
    primary = ('<a class="button primary" href="score.draft.gp">打开 / 保存 GP 草稿 ↗</a>'
               if outcome.get('draft') and (folder/'score.draft.gp').is_file() else '<span class="no-draft">尚未生成 GP 草稿</span>')
    links = [('查看原文件', source.as_uri())] if source.is_file() else []
    links += [(label, name) for name, label in [('overlay.pdf', '原谱识别标记'),
              ('score.draft.gp.review.md', '待修改清单')] if (folder/name).is_file()]
    technical = [(label, name) for name, label in [('recognized.json', '识别数据'),
                 ('worker.log', 'GP 导出日志'), ('note-verification.json', '另行完成的音符核对记录'),
                 ('digit-ocr/review.html', '详细数字识别报告'), ('image-digits.log', '处理日志'),
                 ('image-model.log', '图片模型日志')]
                 if (folder/name).is_file()]
    link_html = lambda pairs: ''.join(f'<a href="{esc(url)}">{esc(label)} ↗</a>' for label, url in pairs)
    css = (ROOT/'review_page.css').read_text(encoding='utf-8')
    js = (ROOT/'review_page.js').read_text(encoding='utf-8')
    return f'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(source.name)} · RiffLoop 识别结果</title>
<style>{css}</style></head><body>
<a class="skip-link" href="#review-content">跳到谱图与问题说明</a>
<header class="topbar"><a class="brand" href="#top">RiffLoop <span>识别结果</span></a><span class="local-tag">本机文件 · 未上传</span></header>
<main id="top"><section class="intro"><div><p class="eyebrow">导出草稿 · 在 Guitar Pro 中修改</p>
<h1>{esc(source.name)}</h1><p class="outcome">{esc(outcome['status'])}</p><p class="summary-text">{esc(outcome['message'])}</p></div>
<div class="file-actions">{primary}<nav aria-label="文件入口">{link_html(links)}</nav></div></section>
<div class="notice"><strong>下一步：在 Guitar Pro 中打开 GP 草稿。</strong> 音符和节奏直接在 Guitar Pro 修改；下方原谱与问题说明供参考。<b>?</b> 表示时值或休止占位。</div>
<section class="metrics" aria-label="结果概览"><div><b>{bars}</b><span>小节总数</span></div>
<div><b>{notes}</b><span>识别音符</span></div><div class="warning-stat"><b>{issues}</b><span>标有待修改项的小节</span></div>
</section>
{f'<p class="settings-line">{esc(settings)}</p>' if settings else ''}
<details class="guide"><summary>怎么看这份结果？识别范围与注意事项</summary><div>{guidance}</div></details>
<div class="review-toolbar" aria-label="查看结果"><div class="filter-control"><label for="review-filter">显示</label>
<select id="review-filter"><option value="all">全部小节</option><option value="issues">仅有待修改项</option></select></div>
<label class="search-control"><span class="sr-only">查找页码或小节</span><input id="review-search" type="search" placeholder="查找页码 / 小节，如：小节4"></label>
<button id="next-issue" class="button">下一处待修改 ↓</button><span id="visible-count" class="filter-count"></span></div>
<p id="review-feedback" role="status" aria-live="polite"></p>
<div id="review-content">{body}</div><div id="filter-empty" class="empty-state" hidden>当前筛选下没有小节。<button id="reset-filter" class="button">显示全部</button></div>
<details class="technical"><summary>识别数据与处理记录</summary><nav>{link_html(technical)}</nav></details>
<footer>页面用于查看识别结果；修改请在 Guitar Pro 中保存。</footer></main>
<dialog id="image-dialog" aria-labelledby="image-title"><div class="dialog-toolbar"><strong id="image-title">谱图对照</strong>
<div><button class="button" id="zoom-out" aria-label="缩小谱图">−</button><span id="zoom-value">100%</span>
<button class="button" id="zoom-in" aria-label="放大谱图">＋</button><button class="button" id="zoom-fit">适合窗口</button>
<button class="button" id="zoom-original">原始大小</button><button class="button primary" id="close-image">关闭 · Esc</button></div></div>
<div id="image-stage"><img id="large-image" alt="放大的谱图对照"></div><p class="dialog-tip">可横向、纵向滚动查看细节。</p></dialog>
<script>{js}</script></body></html>'''
