import unittest
from types import SimpleNamespace

import cv2
import numpy as np

from raster_image_quality import condition_page
from raster_string_digits import recognize_band


class ImageQualityTests(unittest.TestCase):
    def test_clear_paper_is_not_changed(self):
        image=np.full((200,800),245,np.uint8)
        cv2.putText(image,'7 10 8 10',(60,110),cv2.FONT_HERSHEY_SIMPLEX,1,30,2)
        result,info=condition_page(image)
        self.assertFalse(info['lighting_corrected'])
        np.testing.assert_array_equal(result,image)

    def test_smooth_shadow_is_corrected_without_inverting_paper(self):
        image=np.tile(np.linspace(65,240,800,dtype=np.uint8),(200,1))
        cv2.putText(image,'7 10 8 10',(60,110),cv2.FONT_HERSHEY_SIMPLEX,1,20,2)
        result,info=condition_page(image)
        self.assertTrue(info['lighting_corrected'])
        self.assertLess(np.percentile(result[20],90)-np.percentile(result[20],10),10)
        self.assertGreater(float(np.median(result)),220)

    def test_weak_numeric_band_retries_small_offsets_and_marks_recovery(self):
        sequence=iter([('98g',.7),('989',.998),('98',.88)])
        def engine(image,**kwargs):
            text,score=next(sequence)
            return SimpleNamespace(txts=[text],scores=[score])
        out,y0,y1,attempts,recentered=recognize_band(np.full((60,100),255,np.uint8),0,100,20,40,14,engine)
        self.assertEqual(out.txts,['989'])
        self.assertEqual((y0,y1),(18,38))
        self.assertEqual(len(attempts),3)
        self.assertTrue(recentered)

    def test_empty_band_does_not_trigger_number_hunting(self):
        calls=[]
        def engine(image,**kwargs):
            calls.append(image)
            return SimpleNamespace(txts=[''],scores=[0])
        _,_,_,_,recentered=recognize_band(np.full((60,100),255,np.uint8),0,100,20,40,14,engine)
        self.assertEqual(len(calls),1)
        self.assertFalse(recentered)

    def test_tiny_score_gain_does_not_replace_double_digit_with_single_digit(self):
        sequence=iter([('1011',.93928),('101',.93977),('1011n',.824)])
        def engine(image,**kwargs):
            text,score=next(sequence)
            return SimpleNamespace(txts=[text],scores=[score])
        out,_,_,_,recentered=recognize_band(np.full((60,100),255,np.uint8),0,100,20,40,14,engine)
        self.assertEqual(out.txts,['1011'])
        self.assertFalse(recentered)

    def test_weak_neighboring_string_fragment_is_not_promoted(self):
        sequence=iter([('000',.55),('710010',.83),('',0)])
        def engine(image,**kwargs):
            text,score=next(sequence)
            return SimpleNamespace(txts=[text],scores=[score])
        out,_,_,_,recentered=recognize_band(np.full((60,100),255,np.uint8),0,100,20,40,14,engine)
        self.assertEqual(out.scores,[.55])
        self.assertFalse(recentered)


if __name__=='__main__':
    unittest.main()
