"""Generate a synthetic position reference with the actual desktop decoder.

No model or user images are used. Width and height are the bounded dimensions
after the desktop preprocessor, while left/right refer to the original crop.
"""

import json

import numpy as np
from rapidocr.ch_ppocr_rec.utils import CTCLabelDecode


def main():
    cases = []
    for width, height, steps in ((200, 40, 40), (560, 40, 84), (288, 32, 54),
                                 (800, 32, 150), (201, 40, 40)):
        decoder = CTCLabelDecode(character=["1", "2", ",", "X"])
        indices = np.zeros(steps, dtype=np.int64)
        indices[:10] = [1, 1, 0, 1, 3, 2, 5, 4, 0, 2]
        indices[-1] = 1
        logits = np.zeros((1, steps, 6), dtype=np.float32)
        for time, label in enumerate(indices):
            logits[0, time, label] = np.float32(0.5 + (time + 1) / 1000)
        ratio = width / height
        _, word_results = decoder(logits, return_word_box=True, wh_ratio_list=[ratio],
                                  max_wh_ratio=max(320 / 48, ratio))
        info = word_results[0]
        positioned = [(char, column, 10 + column * 200 / info.line_txt_len)
                      for word, columns in zip(info.words, info.word_cols)
                      for char, column in zip(word, columns)]
        cases.append({"bounded_width": width, "bounded_height": height, "steps": steps,
                      "line_length": info.line_txt_len, "positioned": positioned})
    print(json.dumps(cases, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
