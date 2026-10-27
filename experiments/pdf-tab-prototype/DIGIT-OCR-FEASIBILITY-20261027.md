# 图片数字识别可行性验证（2026-10-27）

结论：更换识别方式后，用户的单行练习截图可以读对品位和弦号；另一张整页谱仍有大量未解决区域。尚不能用于通用截图转 GP。

## 方法与边界

独立脚本 `raster_digit_probe.py` 使用 RapidOCR 本地 CPU 模型检测数字行，再通过像素字形间距区分单/双位品位，通过六线谱线和小节线分配弦号与小节。模型输入只有图片；人工参考只在输出保存后用于核对，不参与推断。

这次没有接入桌面入口，没有生成 GP，没有恢复节奏。和弦同时起音、技巧、X 闷音及复杂布局尚未支持。小节边界仍来自图像几何，并非经过验证的音乐结构。OCR 分数不是正确概率；低分数字标红，高分也不代表正确。遇到字符数不匹配、品位分组歧义或弦号无法确定时保留错误，不补音。某行后续数字无法定位时，该行此前成功定位的提案仍保留，因此部分输出不能当成完整小节。

## 实测

| 输入 | 结果 | 能支持的结论 |
| --- | --- | --- |
| 用户 `1.png`，开发样例 | 4 小节、64 个单音的弦号/品位/顺序与人工核对逐项一致；0 条未解决 OCR 行；10 个数字低分标记；运行约 1.512 秒（不含模型首次下载和初始化） | 该图的音符识别可行；不是盲测，不代表其他图片准确率 |
| 既有素材 `整页截图.png`，未用来调整本次规则 | 定位 8 行六线谱、24 个几何小节；产生 103 个音符提案、60 条未解决 OCR 行；约 11.465 秒 | 通用性未通过；103 是提案数，不是正确数，未计算音乐准确率 |

整页未解决原因：18 条含旁注/技巧等非纯数字；2 条只有窄数字 1，无法估计分组间距；23 条数字距弦线过远；17 条 OCR 字符数量与像素字形数量不符。未检测到的数字不一定出现在错误清单中，不能用错误行数推算漏音率。

原专用 OMR 模型对用户图首小节输出 9 组错误和弦，而原图是 16 个单音；原 GP 中四分音符占位还造成时值溢出及长标签堆叠。本探针没有修复旧导出器，也不改变旧桌面入口行为。

## 可复查产物

数据在 `D:\RiffLoop-model-tests\raster-tab-20261027\digit-ocr-probe`：

- `user-image-v1/review.html`：框选数字和逐小节序列；`evaluation.json`：独立人工对照。
- `cross-page-v1/review.html`：整页部分识别和所有已报告失败。
- 每个输出目录的 `prediction.json`：源图 SHA256、模型 SHA256、依赖版本、几何、原始坐标、提案和错误。
- 每行 `*-ocr.json`：先保存的 OCR 原始输出；`*-boxes.png`：定位框。

环境独立安装在 `D:\RiffLoop-model-tests\raster-tab-20261027\digit-ocr-env`（RapidOCR 3.10.0、ONNX Runtime 1.31.1），模型位于上述数据目录 `models`。未改动应用依赖。

```powershell
# 在 experiments/pdf-tab-prototype 目录运行，输出目录必须不存在。
& 'D:\RiffLoop-model-tests\raster-tab-20261027\digit-ocr-env\Scripts\python.exe' raster_digit_probe.py 'C:\Users\sadada\Desktop\素材\1.png' --output 'D:\RiffLoop-model-tests\raster-tab-20261027\digit-ocr-probe\user-image-new' --model-root 'D:\RiffLoop-model-tests\raster-tab-20261027\digit-ocr-probe\models'
```

下一步先改进整页数字分割与弦线定位，用未用于调整规则的图片核验漏音、错音和单双位品位；再独立恢复节奏并验证每小节时值，最后才连接 GP 导出。不能用“识别到 64 个数字”替代完整谱面正确性。

实现参考：[RapidOCR 使用文档](https://rapidai.github.io/RapidOCRDocs/main/install_usage/rapidocr/usage/)。
