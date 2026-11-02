import copy
import unittest
import numpy as np
import cv2

from textbook_recall import add_recall_candidates
from textbook_regions import locate_regions
from test_textbook_regions import draw_pair


class RecallTests(unittest.TestCase):
    def test_tab_only_candidate_does_not_hide_missing_notation(self):
        gray=np.full((600,1000),255,np.uint8)
        draw_pair(gray,130)
        # Faint notation cannot form a separate five-line proposal.
        gray[130:165,50:950]=255
        cv2.circle(gray,(400,140),4,0,-1)
        before=[{'box':[40,210,960,330],'accepted':False,'reason':'partial TAB'}]
        result=add_recall_candidates(gray,before)
        self.assertTrue(any(r['box'][0]<=60 and r['box'][1]<=130
                            and r['box'][2]>=940 and r['box'][3]>=280 for r in result))

    def test_sloping_staff_halves_are_one_complete_candidate(self):
        gray=np.full((600,1500),255,np.uint8)
        for i in range(6):
            cv2.line(gray,(140,230+i*10),(1330,234+i*10),0,1)
        result=add_recall_candidates(gray,[])
        self.assertTrue(any(r['box'][0]<=140 and r['box'][2]>=1330
                            and r['box'][1]<=230 and r['box'][3]>=284 for r in result))

    def test_accepted_partial_width_is_preserved_with_full_width_alternative(self):
        gray=np.full((600,1000),255,np.uint8)
        draw_pair(gray,130)
        accepted={'box':[40,60,850,340],'accepted':True,'reason':'old suggestion'}
        result=add_recall_candidates(gray,[copy.deepcopy(accepted)])
        self.assertIn(accepted,result)
        self.assertTrue(any(not r['accepted'] and r['box'][0]<=60 and r['box'][2]>=940
                            and r['box'][1]<=130 and r['box'][3]>=280 for r in result))

    def test_separate_columns_stay_separate_candidates(self):
        gray=np.full((600,1400),255,np.uint8)
        for left,right in [(50,650),(780,1370)]:
            for y in range(230,281,10):cv2.line(gray,(left,y),(right,y),0,1)
        result=add_recall_candidates(gray,[])
        self.assertTrue(any(r['box'][0]<=50 and r['box'][2]>=650 for r in result))
        self.assertTrue(any(r['box'][0]<=780 and r['box'][2]>=1370 for r in result))
        self.assertFalse(any(r['box'][0]<650 and r['box'][2]>780 for r in result))

    def test_neighboring_rows_with_overlapping_margins_stay_separate(self):
        gray=np.full((800,1000),255,np.uint8)
        for top in (230,450):
            for y in range(top,top+51,10):cv2.line(gray,(60,y),(940,y),0,1)
        result=add_recall_candidates(gray,[])
        self.assertEqual(len(result),2)
        self.assertFalse(any(r['box'][1]<=230 and r['box'][3]>=500 for r in result))

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
