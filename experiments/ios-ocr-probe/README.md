# 独立 iPad 数字模型探针

这个工程只比较合成输入在电脑 CPU 与 iPad 模拟器上的模型输出，不接入 RiffLoop、谱面文件或音频。它不代表真实谱子的识别准确率，也不代表 iPad mini 6 真机的速度和内存。

固定模型是 RapidOCR 的 `PP-OCRv6_rec_small.onnx`，SHA-256 为 `6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884`。权重不存入本仓库；独立云端工作流从 RapidAI 的固定版本下载到临时目录并校验哈希，随后只用于模拟器测试。ONNX Runtime 的 Swift 包固定为 1.24.2；电脑参考结果由 1.31.1 的 CPU 执行器生成。

电脑端脚本要求自行提供模型文件：

```powershell
& 'D:\RiffLoop-model-tests\raster-tab-20261027\digit-ocr-env\Scripts\python.exe' -B `
  experiments\ios-ocr-probe\cpu_reference.py `
  --model 'D:\RiffLoop-model-tests\raster-tab-20261027\digit-ocr-probe\models\PP-OCRv6_rec_small.onnx'
```

脚本默认只输出 JSON；如需文件，`--output` 和 `--alphabet-output` 只接受不存在的目标，不覆盖模型或已有结果。`cpu_reference_expected.json` 只包含合成输入的参考结果，没有用户文件或路径。

模拟器测试校验输入字节、输出形状、每个时间步的最高类别、部分数字的 CTC 解码及抽样数值。固定点阵不等于实际六线谱；真正识谱仍需单独移植与验证图像预处理、完整词典、谱线定位和字符分组。
