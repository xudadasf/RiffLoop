import copy
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np
from PIL import Image

from region_review import apply_region_plan, validate_plan, write_editor


def fixtures(root):
    pixels=np.arange(160*120,dtype=np.uint8).reshape(120,160)
    Image.fromarray(pixels).save(root/'original.png')
    manifest={'document_id':'test-document','complete':True,'source':str(root/'book.pdf'),
              'pages':[{'page':n,'width':160,'height':120,'original':'original.png','regions':[]} for n in (1,2)]}
    plan={'format':'riffloop-region-plan-v1','document_id':'test-document','pages':[
        {'page':1,'confirmed':True,'regions':[{'box':[10,20,90,80],'selected':True},
                                           {'box':[100,15,150,90],'selected':False}]},
        {'page':2,'confirmed':False,'regions':[{'box':[0,0,100,100],'selected':True}]}]}
    (root/'regions.json').write_text(json.dumps(manifest),encoding='utf-8')
    return pixels,manifest,plan


class RegionPlanTests(unittest.TestCase):
    def test_manual_box_recrops_clean_original_and_ignores_unconfirmed(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);pixels,manifest,plan=fixtures(root)
            path=root/'plan.json';path.write_text(json.dumps(plan),encoding='utf-8')
            result=apply_region_plan(path,root,root/'result')
            self.assertEqual(len(result['region_sources']),1)
            with Image.open(result['region_sources'][0]) as image:
                np.testing.assert_array_equal(np.asarray(image),pixels[20:80,10:90])
            self.assertIn('1/2',result['message'])
            plan['pages'][0]['regions'][0]['box']=[20,30,120,100]
            path.write_text(json.dumps(plan),encoding='utf-8')
            newer=apply_region_plan(path,root,root/'newer')
            with Image.open(newer['region_sources'][0]) as image:
                np.testing.assert_array_equal(np.asarray(image),pixels[30:100,20:120])
            with self.assertRaisesRegex(ValueError,'必须为空'):
                apply_region_plan(path,root,root/'result')

    def test_foreign_plan_invalid_box_and_page_order_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            _,manifest,plan=fixtures(Path(temp))
            bad=[]
            p=copy.deepcopy(plan);p['document_id']='another';bad.append(p)
            p=copy.deepcopy(plan);p['pages'].reverse();bad.append(p)
            for box in ([-1,0,50,50],[1,1,500,30],[20,20,10,30],[0,0,float('nan'),50],[0,0,2,2]):
                p=copy.deepcopy(plan);p['pages'][0]['regions'][0]['box']=box;bad.append(p)
            for p in bad:
                with self.assertRaises(ValueError):validate_plan(p,manifest)

    def test_no_confirmations_or_no_selected_music_does_not_make_queue(self):
        with tempfile.TemporaryDirectory() as temp:
            _,manifest,plan=fixtures(Path(temp))
            plan['pages'][0]['confirmed']=False
            with self.assertRaisesRegex(ValueError,'尚未确认'):validate_plan(plan,manifest)
            plan['pages'][0]['confirmed']=True
            plan['pages'][0]['regions'][0]['selected']=False
            with self.assertRaisesRegex(ValueError,'没有采用'):validate_plan(plan,manifest)

    def test_overlapping_selected_regions_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            _,manifest,plan=fixtures(Path(temp))
            plan['pages'][0]['regions'].append({'box':[15,25,95,90],'selected':True})
            with self.assertRaisesRegex(ValueError,'重叠'):validate_plan(plan,manifest)

    def test_editor_embedded_json_cannot_break_out_of_script(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);_,manifest,_=fixtures(root)
            manifest['source']='x</script><script>alert(1)</script>.pdf'
            write_editor(root,manifest,{'message':'test'})
            content=(root/'review.html').read_text(encoding='utf-8')
            self.assertNotIn('x</script>',content)
            self.assertIn('\\u003c/script>',content)
