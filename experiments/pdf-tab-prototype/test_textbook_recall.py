import copy
import unittest
import numpy as np
import cv2

from textbook_recall import add_recall_candidates
from textbook_regions import locate_regions
from test_textbook_regions import draw_pair


class RecallTests(unittest.TestCase):
    def test_missing_tab_with_beam_uses_notation_candidate(self):
        gray=np.full((600,1000),255,np.uint8)
        draw_pair(gray,130)
        # Several TAB lines lost in a dense scan; five-line notation is intact.
        gray[229:255,50:950]=255
        before=locate_regions(gray)['regions']
        self.assertEqual(before,[])
        result=add_recall_candidates(gray,copy.deepcopy(before))
        self.assertTrue(any(r['box'][0]<=60 and r['box'][2]>=940 and r['box'][1]<=130
                            and r['box'][3]>=280 for r in result))
        self.assertFalse(any(r['accepted'] for r in result))

    def test_existing_accepted_region_is_unchanged(self):
        gray=np.full((600,1000),255,np.uint8)
        draw_pair(gray,130)
        before=locate_regions(gray)['regions']
        accepted=copy.deepcopy([r for r in before if r['accepted']])
        result=add_recall_candidates(gray,before)
        self.assertEqual([r for r in result if r['accepted']],accepted)

    def test_pure_tab_is_kept_for_manual_confirmation(self):
        gray=np.full((600,1000),255,np.uint8)
        for y in range(230,281,10):cv2.line(gray,(60,y),(940,y),0,1)
        result=add_recall_candidates(gray,[])
        self.assertTrue(any(r['box'][0]<=60 and r['box'][2]>=940 and r['box'][1]<=230
                            and r['box'][3]>=280 for r in result))
        self.assertTrue(all(not r['accepted'] for r in result))
