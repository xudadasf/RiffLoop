"""Local lighting normalization for printed TAB; no generative restoration."""
import cv2
import numpy as np


def normalize_lighting(gray, sharpen=True):
    # Closing estimates paper brightness while bridging dark strokes. Dividing
    # by that surface corrects smooth shadows without inventing glyph shapes.
    size = max(21, round(min(gray.shape)*.1)) | 1
    size = min(size, 81)
    background = cv2.morphologyEx(gray, cv2.MORPH_CLOSE,
                                cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(size,size)))
    result = np.clip(gray.astype(np.float32)*245/np.maximum(background.astype(np.float32),32),0,255).astype(np.uint8)
    if sharpen:
        result = cv2.addWeighted(result,1.7,cv2.GaussianBlur(result,(0,0),1),-.7,0)
    return result


def condition_page(gray):
    size = min(81,max(21,round(min(gray.shape)*.1)) | 1)
    background = cv2.morphologyEx(gray,cv2.MORPH_CLOSE,
                                cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(size,size)))
    spread = float(np.percentile(background,90)-np.percentile(background,10))
    applied = spread > 45
    corrected = normalize_lighting(gray,sharpen=False) if applied else gray
    return corrected, {'lighting_corrected':applied,'background_range':round(spread,1),
                       'method':'smooth-paper normalization when uneven; no generative sharpening'}
