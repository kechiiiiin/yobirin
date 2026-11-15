#!/usr/bin/env python3
"""Unicode の emoji-test.txt から、絵文字の並び順（Core/EmojiOrder.swift）を作る。

    curl -sSfLO https://unicode.org/Public/emoji/latest/emoji-test.txt
    python3 tools/gen-emoji-order.py emoji-test.txt > Core/EmojiOrder.swift

fully-qualified の行だけを、ファイルの順（顔 → 人 → … → 旗）で並べる。肌の色の違い（U+1F3FB〜1F3FF）は除く。
"""
import sys

path = sys.argv[1]
version = ""
order = []
for line in open(path, encoding="utf-8"):
    if line.startswith("# Version:"):
        version = line.split(":", 1)[1].strip()
    if line.startswith("#") or ";" not in line:
        continue
    codes, rest = line.split(";", 1)
    if not rest.strip().startswith("fully-qualified"):
        continue
    cps = [int(c, 16) for c in codes.split()]
    if any(0x1F3FB <= c <= 0x1F3FF for c in cps):
        continue
    order.append("".join(chr(c) for c in cps))

print("// 自動生成（tools/gen-emoji-order.py）。手で直さない")
print(f"// 元: https://unicode.org/Public/emoji/latest/emoji-test.txt（Emoji {version}）")
print("// © Unicode, Inc. 利用条件: https://www.unicode.org/terms_of_use.html")
print()
print("enum EmojiOrder {")
print(f'    static let version = "{version}"')
print("    /// 1 行に 1 つ。Unicode の推奨の並び（絵文字キーボードの並びと同じ）")
print('    static let list = """')
for e in order:
    print(e)
print('"""')
print("}")
