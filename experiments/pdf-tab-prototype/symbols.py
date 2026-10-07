"""Recognize outlined music glyphs against the repository's own Bravura font.

Templates come from the font, never from reference scores. Low-confidence or
ambiguous silhouettes remain unrecognized; no bar-length fitting is performed.
"""
import io
from functools import lru_cache
from pathlib import Path

import fitz
from fontTools.ttLib import TTFont


def mask(pix):
    data=pix.samples
    points=[(i%pix.width,i//pix.width) for i,v in enumerate(data) if v<128]
    if not points: return None
    left=min(x for x,y in points); right=max(x for x,y in points)+1
    top=min(y for x,y in points); bottom=max(y for x,y in points)+1
    bits=frozenset(y*32+x for y in range(32) for x in range(32)
                   if data[min(bottom-1,top+int((y+.5)*(bottom-top)/32))*pix.width+
                           min(right-1,left+int((x+.5)*(right-left)/32))]<128)
    return bits,(left,top,right,bottom)


@lru_cache(maxsize=1)
def font_buffer():
    font=TTFont(Path(__file__).parents[2]/'RiffLoop/Resources/GpWeb/font/Bravura.woff')
    font.flavor=None; buffer=io.BytesIO(); font.save(buffer); font.close()
    return buffer.getvalue()


@lru_cache(maxsize=1)
def templates():
    result=[]
    codes=list(range(0xe080,0xe08c))+[0xe0a2,0xe0a3,0xe0a4,0xe1e7]+list(range(0xe240,0xe248))+list(range(0xe4e3,0xe4ea))
    for code in codes:
        with fitz.open() as doc:
            page=doc.new_page(width=300,height=300)
            page.insert_font(fontname='music',fontbuffer=font_buffer())
            page.insert_text((100,150),chr(code),fontname='music',fontsize=100)
            bits,rect=mask(page.get_pixmap(colorspace=fitz.csGRAY))
            result.append((code,bits,rect))
    return result


@lru_cache(maxsize=4096)
def classify(key):
    # key coordinates are normalized to a 60 point box. Repeated printed glyphs
    # share the cached result across pages and scores.
    with fitz.open() as doc:
        page=doc.new_page(width=64,height=64); shape=page.new_shape()
        for kind,coords in key:
            if kind=='c': shape.draw_bezier(*(fitz.Point(*p) for p in coords))
            elif kind=='l': shape.draw_line(*(fitz.Point(*p) for p in coords))
            elif kind=='re': shape.draw_rect(fitz.Rect(*coords[0],*coords[1]))
        shape.finish(color=None,fill=(0,0,0),closePath=False); shape.commit()
        found=mask(page.get_pixmap(colorspace=fitz.csGRAY))
    if not found: return None
    bits,rect=found; ratio=(rect[2]-rect[0])/(rect[3]-rect[1])
    scores=[]
    for code,other,bounds in templates():
        candidate_ratio=(bounds[2]-bounds[0])/(bounds[3]-bounds[1])
        if abs(ratio/candidate_ratio-1)>.15: continue
        score=len(bits&other)/max(1,len(bits|other))
        scores.append((score,code,bounds))
    scores.sort(reverse=True)
    if not scores or scores[0][0]<.85: return None
    if len(scores)>1 and scores[0][0]-scores[1][0]<.04: return None
    return scores[0],rect


def outline_spans(shapes):
    spans=[]
    for sh in shapes:
        r=sh['rect']
        if sh['type']!='f' or not (.7<r.width<18 and .7<r.height<38): continue
        if any(i[0] not in ('c','l','re') for i in sh['items']): continue
        scale=60/max(r.width,r.height)
        def point(p): return (round((p.x-r.x0)*scale+2,1),round((p.y-r.y0)*scale+2,1))
        key=tuple((i[0],(point(i[1].tl),point(i[1].br)) if i[0]=='re' else tuple(point(p) for p in i[1:])) for i in sh['items'])
        match=classify(key)
        if not match: continue
        (confidence,code,bounds),ink=match
        glyph_scale=(ink[3]-ink[1])/scale/(bounds[3]-bounds[1])
        origin=(r.x0+(ink[0]-2)/scale+(100-bounds[0])*glyph_scale,
                r.y0+(ink[1]-2)/scale+(150-bounds[1])*glyph_scale)
        spans.append({'text':chr(code),'origin':origin,'bbox':list(r),
                      'font':'GPBravuraOutline','size':100*glyph_scale,
                      'source':'font-outline','confidence':round(confidence,3)})
    return spans
