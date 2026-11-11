"""Generate synthetic confidence references using the actual desktop decoder.

No model, user image, or source data is read. Output must be a new file.
"""

import argparse
import json
from pathlib import Path

import numpy as np
from rapidocr.ch_ppocr_rec.utils import CTCLabelDecode

from cpu_reference import ctc_runs


CASES = (
    # Repeats must use the FIRST score, even when a later score is higher.
    ('repeat_and_blank', [0, 1, 1, 0, 1, 2, 2, 0],
     [0.99, 0.71, 0.99, 0.99, 0.96, 0.98, 0.99, 0.99]),
    ('unknown_and_space', [1, 4, 5, 2, 0], [0.97, 0.99, 0.98, 0.96, 0.99]),
    ('decimal_ties', [1, 0, 2, 0], [0.015625, 0.99, 0.046875, 0.99]),
    ('threshold_neighbors', [1, 0, 2, 0, 1], [0.799994, 0.99, 0.949994, 0.99, 0.950006]),
    # NumPy's line rounding differs from Python's character rounding here.
    ('numpy_mean_tie', [1, 0, 2], [0.8, 0.99, 0.99997]),
    ('empty_line', [0, 0, 0], [0.9, 0.8, 0.7]),
)


def reference():
    cases = []
    for name, indices, scores in CASES:
        # 0=blank; 1/2 are digits, 3 punctuation, 4 is not mapped in Swift,
        # and 5 is the desktop's extra whitespace character.
        labels = ['1', '2', ',', 'X']
        decoder = CTCLabelDecode(character=labels)
        pred = np.zeros((1, len(indices), 6), dtype=np.float32)
        for time, (category, score) in enumerate(zip(indices, scores)):
            pred[0, time, category] = np.float32(score)
        output, word = decoder(pred, return_word_box=True)
        if np.argmax(pred[0], axis=1).tolist() != indices:
            raise RuntimeError('Unexpected synthetic winner')
        runs = ctc_runs(indices)
        confidence = word[0].confs
        if runs and len(confidence) != len(runs):
            raise RuntimeError('Confidence and CTC runs do not match')
        items = []
        for run, score in zip(runs, confidence):
            items.append({'classID': run['class'], 'start': run['start'], 'end': run['end'],
                          'rawFirstScore': float(np.float32(scores[run['start']])),
                          'roundedScore': score})
        cases.append({'name': name, 'indices': indices,
                      'scores': [float(np.float32(value)) for value in scores],
                      'lineScore': output[0][1], 'items': items})
    return {'scope': 'Synthetic RapidOCR CTC confidence behavior only; not an accuracy benchmark',
            'cases': cases}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    with Path(args.output).open('x', encoding='utf-8', newline='\n') as out:
        json.dump(reference(), out, ensure_ascii=False, indent=2)
        out.write('\n')
