# 合成谱音符字节修改实验

该实验仅接受 `gp-semantic-probe/test_semantic.py` 生成的固定合成 GPIF（严格核对 SHA-256），验证候选后仅支持其中两个自然音 C↔D 的品位调整。它同步修改品位、MIDI 和两套记谱音名，保留其余 XML 字节；不会读取或写出 GP 文件，不能用于用户乐谱，也没有接入应用。

运行：`python -B -m unittest discover -s experiments/gp-note-patch -p 'test_*.py'`。

测试中的解析观察是合成的，不证明真实 GP 兼容、调号与移调规则、技巧、播放、附件或 iPad 表现。扩大到真实乐谱前仍需要严格检查这些条件、真实导入器往返及外部软件兼容；来源摘要只绑定调用方声明，不认证解析器。
