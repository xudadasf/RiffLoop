# PDF 六线谱 → GP 独立实验

这是可运行的电脑端实验工具，尚未接入 RiffLoop，也未更改 Android 或 iOS。当前结论：**电子六线谱的部分片段已验证可导出，但整曲自动转换尚未达到可用标准。**

## 怎么识别

只输入 PDF，不读取原 GP。用 PyMuPDF 提取 PDF 本身的文字绘制记录和线条：六条等距横线确定弦位，线上的数字确定品位，符干、横梁、附点和连音数字确定时值。然后按小节检查拍数。这里没有调用大模型，也没有上传素材。

选择文字绘制记录而非普通文本段，是因为排版提取可能把相邻的 `14、15、14` 合并成 `141514`。这仍依赖 PDF 的字体和绘制方式，不是通用 OCR。

`recognize.py` 生成音符数据及原谱标记图，`gp-export.cjs` 通过仓库已有 alphaTab 1.8.4 写出 GP7 格式，并重新读取检查导出是否改变数据。`convert.py` 把这两步串起来。只有评估工具才允许读取 GP 答案。

## 当前边界

- 面向可提取文字及矢量线条的六弦电子 PDF，当前重点支持 Arial/Helvetica 品位数字和部分 SMuFL 音乐符号。扫描 PDF、照片、四弦贝斯、鼓谱不支持。
- 默认处理单分谱、单声部；重复小节号和未解决的拍数问题阻止导出。
- 必须从 PDF 找到标准定弦文字和初始 BPM。未识别到拍号时暂按 4/4，数据中标为 `assumed-4/4`，对照页面明确提示。BPM 暂按四分音符计拍。两项假设都需要人工确认。
- 休止符、延音线、装饰音类型、推弦、滑音、泛音、击勾弦、反复结构、变调及中途变速均未完整实现。装饰音暂按八分时值、拍前装饰音导出；括号音符不能自动确定是延音还是弱音。
- 绿色框**仅表示拍数合计通过**，不能证明音符、顺序或演奏技巧正确。没有完整的正确性置信度。
- 默认转换整份 PDF；任何小节有未解决问题即不输出整曲。可以显式选择已核对的连续片段。导出标题和文件名均标为实验稿。

## 本次验证（2026-10-06）

输入为用户本地素材目录。先用少量 PDF 调试规则，再冻结识别规则进行批量评估；之后仅增加假设说明和导出检查，未根据保留样本继续调参。

82 组自动候选配对中：50 组完成逐小节对比，14 组存在多分谱或重复小节号，4 组未找到六线谱，14 组因两个原始 GP 文件无法由当前 alphaTab 导入而无法评估。失败项保留在报告中。两份 GP 是可读取的 ZIP 容器，但导入器报告 `No compatible importer found for file`；尚未定位内部格式差异，不能据此判断原文件损坏。

| 已完成对比的候选样本 | 音符匹配率 | 音符覆盖率 | 音符及节奏覆盖率 |
| --- | ---: | ---: | ---: |
| 全部 50 组 | 95.56% | 91.48% | 77.72% |
| 其中未参与调试的 47 组 | 95.41% | 91.53% | 78.45% |

这些是按音符总数加权的诊断指标，不是整曲成功率。自动配对可能不正确，GP 多轨时在评估阶段选择匹配最多的六弦轨道，因此也不是严格盲测成绩。同一曲子的不同分谱并不统计独立。

- 音符匹配率 = 弦位/品位匹配数 ÷ PDF 识别音符数。
- 音符覆盖率 = 匹配数 ÷ GP 全部音符数，包含漏识别的音符。
- 音符及节奏覆盖率额外要求时值、附点、连音比例、是否装饰音一致。
- 匹配限制在同号小节内，以最长公共子序列对齐。不评估休止符完整性、技巧、延音、拍号、速度变化或反复结构。JSON 中 `exact_bars` 也只表示音符/上述节奏属性及拍数检查通过，不表示小节完整正确。
- 每份预测先独立写入 JSON 并保存 SHA-256，再读取参考 GP；识别器和导出器都没有 GP 答案参数。

已实际生成并重新读入、再对照原 GP 的两个片段：

| PDF | 原谱小节 | 音符数 | 结果 |
| --- | --- | ---: | --- |
| 七重人格 | 10–13 | 96 | 所检查项目全部一致；调试样本 |
| 变相怪杰 吉他2 | 8–39 | 255 | 所检查项目全部一致；未参与调试 |

片段检查包括第 1 声部的音符/休止节拍序列、弦位、品位、闷音、时值、附点、连音、装饰音标志、拍号、定弦和初始速度。没有验证技巧、延音、反复、中途变速和实际听感。片段选在批量结果中可导出的小节，因此不能用它们推断整曲成功率。《变相怪杰》这份 PDF 的全部 775 个音符及所测节奏属性匹配，但仍有 16 个空小节/休止符小节未解决，整曲导出会被阻止。

脱敏后的逐素材结果保存在 `validation-summary.json`。完整原谱、GP 答案和生成文件仅保存在本地 `output/pdf-tab-prototype/`，不提交到 Git。

## 使用

依赖 Python 3.10+、Node.js；本次环境为 Python 3.14、PyMuPDF 1.27.2.3、Node 24.14.0。以下命令在仓库根目录运行。

安装 PDF 解析依赖：

```powershell
python -m pip install -r experiments/pdf-tab-prototype/requirements.txt
```

弹出文件选择窗口，完成后打开结果文件夹（不自动安装依赖）：

```powershell
pwsh -STA -File experiments/pdf-tab-prototype/run.ps1
```

也可指定 PDF。每次输出使用独立文件夹：

```powershell
pwsh -STA -File experiments/pdf-tab-prototype/run.ps1 -PdfPath 'C:\谱子\练习.pdf' -Bars '10-13'
```

命令行转换，输出目录应专用于本工具。同目录重跑会替换结果，并清除旧的 `experimental.gp`，避免失败后误用旧稿：

```powershell
python experiments/pdf-tab-prototype/convert.py 'C:\谱子\练习.pdf' --out output/pdf-tab-prototype/manual
```

输出包括 `review.html`（逐小节说明）、`overlay.pdf`（蓝框音符、红框待核对小节）、`recognized.json`。只有拍数检查及导出回读检查通过才生成 `experimental.gp`。

## 重现验证

自动回归检查覆盖弦位/品位/四分音符识别及真实 GP 导出、时值未知时阻止导出、扫描 PDF 不伪装转换成功、失败重跑清除旧结果：

```powershell
python -m unittest discover -s experiments/pdf-tab-prototype -v
```

批量独立识别后对照答案（需要用户本地素材，运行约数分钟）：

```powershell
python experiments/pdf-tab-prototype/evaluate.py 'C:\Users\sadada\Desktop\素材' --out output/pdf-tab-prototype/benchmark
```

查看生成的 `report.html`。仅更新报告显示可加 `--report-only`。候选配对规则为同目录同名、同目录唯一 GP、最后才是文件名相似度；人工复核配对和轨道是解释结果的前提。

验证一个导出片段与原 GP 的指定轨道：

```powershell
python experiments/pdf-tab-prototype/verify_export.py output/pdf-tab-prototype/heldout-demo/experimental.gp 'C:\Users\sadada\Desktop\素材\花花\变相怪杰\变相怪杰.gp' --track '吉他2' --bars 8-39 --out output/pdf-tab-prototype/heldout-demo/verification.json
```

后续应优先解决空小节/休止符、延音、拍号和速度的可靠识别，再处理技巧及多声部；在整曲验证通过前保持独立实验。

## 参考 API

- [PyMuPDF 文字绘制记录](https://pymupdf.readthedocs.io/en/latest/functions.html#Page.get_texttrace)
- [alphaTab GP7 导出器](https://www.alphatab.net/docs/reference/types/exporter/gp7exporter/)
