# 六线谱自动候选实验记录

一次独立的灰度栅格实验尝试根据水平线和近等距的六条线生成分区候选。简单合成样本曾覆盖：纯六线、线条短暂中断、纯五线、同页多行和双栏。该实验没有接入 App，也没有在 iPad 上运行。

## 真实教材检查

- 使用《地狱训练（叛逆入伍）》的桌面试验结果中第 61、103、121 页的原始灰度图，与同一份桌面记录中的已采用六线定位结果比较。
- 比较范围仅限已有六线坐标且标记为已采用的 6 个桌面结果；这些定位结果并非完整的人工标注真值，不能据此计算整本教材的召回率。
- 判为匹配的条件：候选的 6 条线中至少 5 条与参考线的纵坐标相差不超过 2 像素，并且候选横向覆盖参考线范围的至少 80%。不比较节奏符号边界或音符识别。
- 6 个参考中只有 4 个匹配；三页分别产生 44、44、71 个候选，包含大量图文误框和未完整覆盖的情况。
- 本机电脑上的数据不能代表 iPad mini 6 性能。由于误框和漏检较多，该实验未达到接入条件，实验实现已移除。

后续可复用桌面识别项目中的 `test_textbook_recall.py` 和 `test_textbook_regions.py` 所覆盖的谱线、双栏与倾斜场景，并对真实页增加逐条人工标注的六线区域；除了谱线位置，还需要检查整行边界、截断、漏检和误框。无候选不应视为无谱。

## 桌面规则原样复测（2026-11-09）

使用保存在 `D:\RiffLoop-model-tests\textbook-completeness-20261029\full-review-v3` 的三张原页灰度图，直接运行桌面项目 `textbook_regions.locate_regions` 和 `textbook_recall.add_recall_candidates`。比较对象仍是桌面项目 `textbook-coverage-cases.json` 中对应三页的 12 个已标注谱行主体；这些标注包括五线和六线区域，不能当作仅六线谱的专项标注。下表的“完整覆盖”要求一个输出框覆盖标注面积的至少 99%；“弱匹配”指输出框没有覆盖任一标注面积的 80%，这可能包括误框或部分谱行，不等同于人工确认的误报数。

| 页码 | 自动采用框 / 完整覆盖 | 所有框（含候选） / 完整覆盖 | 弱匹配框 |
| --- | --- | --- | --- |
| 61 | 3 个 / 3 行 | 6 个 / 4 行 | 2 个 |
| 103 | 2 个 / 1 行 | 8 个 / 4 行 | 3 个 |
| 121 | 1 个 / 4 行 | 2 个 / 4 行 | 1 个 |

第 121 页的自动框同时包含四行，其中存在不同 Intro 段；它虽然覆盖四个标注，不能证明分段正确。若未经确认直接采用，会使不同区域之间的空白小节设置失去作用。第 103 页还有自动框只覆盖第三行局部宽度，不能仅凭“已采用”认定完整。旧规则主要为五线谱与六线谱配对设计，不适合直接作为当前只识别六线谱的自动选择规则。

以上只是三页、12 个已有标注的对比，尚未建立完整误框真值，也不代表整本教材或 iPad 性能。候选规则尚不应直接接入或覆盖人工框；下一步应建立仅六线谱主体及分段的标注，分别统计完整覆盖、错误合并、截断和误框。

在当前 Windows 电脑、安装了 OpenCV、NumPy 和 Pillow 的 Python 环境中，可在 PowerShell 原样运行以下只读脚本复现表格，不修改素材：

```powershell
@'
import json, sys
from pathlib import Path
from PIL import Image
import numpy as np

project = Path(r'C:\Users\sadada\.codex\worktrees\riffloop-playback-stall-20260911\experiments\pdf-tab-prototype')
pages = Path(r'D:\RiffLoop-model-tests\textbook-completeness-20261029\full-review-v3')
sys.path.insert(0, str(project))
from textbook_regions import locate_regions
from textbook_recall import add_recall_candidates

cases = json.loads((project / 'textbook-coverage-cases.json').read_text(encoding='utf-8'))['cases']
for number in (61, 103, 121):
    gray = np.asarray(Image.open(pages / f'page-{number:03}-source.png').convert('L'))
    regions = add_recall_candidates(gray, locate_regions(gray)['regions'])
    labels = [case['staff_core'] for case in cases if case['page'] == number]
    def coverage(box, label):
        left, top, right, bottom = box
        x0, y0, x1, y1 = label
        intersection = max(0, min(right, x1) - max(left, x0)) * max(0, min(bottom, y1) - max(top, y0))
        return intersection / ((x1 - x0) * (y1 - y0))
    def complete(items):
        return sum(any(coverage(item['box'], label) >= .99 for item in items) for label in labels)
    accepted = [region for region in regions if region['accepted']]
    weak = sum(not any(coverage(region['box'], label) >= .8 for label in labels) for region in regions)
    print(number, len(accepted), complete(accepted), len(regions), complete(regions), weak)
'@ | python -B -
```

## 几何基线复测（2026-11-11）

另试验过一种寻找近似平行六线的轻量几何基线：人工生成的多行、双栏、轻度倾斜和短断线样本可通过，但六线指板图会产生误报。将教材第 61、103、121 页渲染至最长边 2048 像素后，三页均因粗线或重叠线触发人工检查，未能输出可用自动候选。实验未接入 App；该基线实现和临时合成测试已移除。合成通过不能替代真实教材验证，也无法据此估算整本教材的召回率。

## 矢量 PDF 分流探索（2026-11-11）

同一本教材的第 61、103、121 页均只有图片，没有可提取文字或矢量绘图，因此这三页必须走图像方案。素材目录中 101 份可读取 PDF 的首页里，99 页同时含绘图对象和文字；含绘图对象不代表它们一定可直接提取六线谱，也不能代表后续页面的情况。

在内存构造的合成电子 PDF 中，现有桌面六线检测能找到普通单行与短断线，但把同高的左右两栏合并为一个框，也将单个指板图当作六线谱。另一种按横向覆盖分栏、标记疑似指板的实验在合成输入上避免了这两类错误；对 98 个有绘图的真实 PDF 首页，它和旧规则分别在 86 页给出至少一个候选，新规则共给出 829 个候选，其中 238 个带警告。这里只统计候选存在与数量，没有逐框人工真值，不能说明召回或准确率提高。该实验未接入 App，代码已移除；需要先建立真实纯六线标注和独立对照，再判断是否值得继续。
