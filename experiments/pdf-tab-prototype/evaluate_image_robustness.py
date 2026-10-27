"""Deterministic image degradation audit; truth is used only after prediction.

This is a synthetic stress test, not a claim about arbitrary photographed TAB.
Use the digit-ocr-env interpreter. Inputs and per-case predictions are frozen.
"""
import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from raster_tab import deskew, locate_systems, raster_pages
from raster_string_digits import read_string_bands


def rotate(gray, angle):
    h, w = gray.shape
    m = cv2.getRotationMatrix2D((w/2, h/2), angle, 1)
    c, s = abs(m[0,0]), abs(m[0,1])
    nw, nh = int(np.ceil(w*c+h*s)), int(np.ceil(h*c+w*s))
    m[0,2] += (nw-w)/2
    m[1,2] += (nh-h)/2
    return cv2.warpAffine(gray, m, (nw,nh), flags=cv2.INTER_CUBIC, borderValue=255)


VARIANTS = {
    'clean': {}, 'blur-0.7': {'blur': .7}, 'blur-1.2': {'blur': 1.2},
    'blur-1.8': {'blur': 1.8}, 'shadow-55': {'shadow': .55}, 'shadow-25': {'shadow': .25},
    'tilt-minus3': {'angle': -3}, 'tilt-plus3': {'angle': 3}, 'tilt-plus7': {'angle': 7},
    'combined': {'blur': .7, 'shadow': .45, 'angle': 3},
}


def degrade(gray, recipe):
    result = gray.copy()
    if recipe.get('blur'):
        result = cv2.GaussianBlur(result, (0,0), recipe['blur'])
    if recipe.get('shadow'):
        h,w = gray.shape
        xx, yy = np.meshgrid(np.linspace(0,1,w), np.linspace(0,1,h))
        shade = 1-(1-recipe['shadow'])*np.exp(-((xx-.55)/.24)**2)*(.8+.2*yy)
        result = np.clip(result.astype(float)*shade,0,255).astype(np.uint8)
    if recipe.get('angle'):
        result = rotate(result, recipe['angle'])
    return result


def infer(source, engine, enhancement='none'):
    result = {'systems': [], 'errors': []}
    for page, gray in enumerate(raster_pages(source),1):
        if enhancement == 'adaptive':
            from raster_image_quality import condition_page
            gray,_ = condition_page(gray)
        elif enhancement != 'none':
            from raster_image_quality import normalize_lighting
            gray = normalize_lighting(gray, sharpen=enhancement=='sharpen')
        gray, angle = deskew(gray)
        try:
            regions = locate_systems(gray)
        except ValueError as error:
            result['errors'].append(str(error))
            continue
        if not regions:
            result['errors'].append(f'page {page}: no six-line staff')
        for region in regions:
            notes, unresolved, discarded, raw = read_string_bands(gray,region,engine)
            result['systems'].append({'page':page,'deskew':angle,'region':region,'notes':notes,
                                      'unresolved':unresolved,'discarded_bands':discarded,'raw':raw})
    return result


def compare(prediction, expected):
    actual = []
    for system in prediction['systems']:
        for bar in range(1,system['region']['expected_bars']+1):
            actual.append([[n['string'],n['fret']] for n in system['notes'] if n['bar']==bar])
    # Exact ordered sequence includes bar boundaries: extra/missing bars fail.
    return {'exact': actual==expected, 'expected_notes':sum(map(len,expected)),
            'actual_notes':sum(map(len,actual)), 'exact_bars':sum(a==b for a,b in zip(actual,expected)),
            'bar_count':len(actual), 'actual':actual}


def main(args):
    from rapidocr import RapidOCR
    args.output.mkdir(parents=True,exist_ok=False)
    inputs=args.output/'inputs'
    inputs.mkdir()
    engine=RapidOCR(params={'Global.model_root_dir':str(args.model_root),'Global.log_level':'warning',
                            'EngineConfig.onnxruntime.intra_op_num_threads':4,
                            'EngineConfig.onnxruntime.inter_op_num_threads':1})
    manifest=[]
    for source in args.sources:
        with Image.open(source) as image:
            gray=np.array(image.convert('L'))
        for variant,recipe in VARIANTS.items():
            name=f'{source.stem}-{variant}'
            path=inputs/f'{name}.png'
            Image.fromarray(degrade(gray,recipe)).save(path)
            prediction=infer(path,engine,args.enhancement)
            (args.output/f'{name}.prediction.json').write_text(json.dumps(prediction,ensure_ascii=False,indent=2),encoding='utf-8')
            manifest.append({'id':name,'source':str(source),'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
                             'variant':variant,'recipe':recipe,'input_sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
            print(json.dumps({'finished':name,'notes':sum(len(s['notes']) for s in prediction['systems'])}),flush=True)
    (args.output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    # No reference is loaded until all predictions have been written.
    truth=json.loads(args.truth.read_text(encoding='utf-8'))['bars']
    rows=[]
    for case in manifest:
        prediction=json.loads((args.output/f'{case["id"]}.prediction.json').read_text(encoding='utf-8'))
        rows.append({**case,**compare(prediction,truth[Path(case['source']).name])})
    summary={'scope':'Synthetic perturbations of four development images; ordered string/fret/bar accuracy only, no rhythm claim',
             'enhancement':args.enhancement,
             'exact_images':sum(r['exact'] for r in rows),'images':len(rows),'cases':rows}
    (args.output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in summary.items() if k!='cases'},ensure_ascii=False),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sources',type=Path,nargs='+')
    parser.add_argument('--truth',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--model-root',type=Path,required=True)
    parser.add_argument('--enhancement',choices=['none','flatten','sharpen','adaptive'],default='none')
    main(parser.parse_args())
