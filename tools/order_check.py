#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
order_check.py —— 静态检查：static 函数是否在「首次被调用」之前定义。

C99 起 clang 不再允许隐式函数声明，顺序错了会直接报
  error: call to undeclared function 'xxx'
这属于纯编译期错误，本地无法编译时用一个脚本先兜住，能省一轮云端构建。
"""
import pathlib
import re
import sys

SRC = pathlib.Path(__file__).resolve().parent.parent / "Sources"

FUNC_DEF = re.compile(r"^\s*static\s+[\w\s*<>,\[\]()]*?\b([A-Za-z_]\w*)\s*\([^;]*\)\s*\{")
FUNC_DECL = re.compile(r"^\s*static\s+[\w\s*<>,\[\]()]*?\b([A-Za-z_]\w*)\s*\([^;]*\)\s*;")

COMMENT_LINE = re.compile(r"//[^\n]*")
COMMENT_BLOCK = re.compile(r"/\*.*?\*/", re.S)
STRING_LIT = re.compile(r'@?"(?:[^"\\]|\\.)*"')
OBJC_AT = re.compile(r"^\s*@")
DEF_OR_DECL = re.compile(r"^\s*static\b.*(;|\{)\s*$")


def strip_code(src: str) -> str:
    src = COMMENT_BLOCK.sub("", src)
    src = COMMENT_LINE.sub("", src)
    src = STRING_LIT.sub('""', src)
    return src


def main() -> int:
    bad = 0
    files = sorted(SRC.glob("*.m"))
    if not files:
        print("找不到 Sources/*.m")
        return 1

    for f in files:
        clean = strip_code(f.read_text(encoding="utf-8"))
        lines = clean.splitlines()

        defs = {}
        decls = set()
        for i, ln in enumerate(lines, 1):
            m = FUNC_DEF.match(ln)
            if m and m.group(1) not in defs:
                defs[m.group(1)] = i
            m2 = FUNC_DECL.match(ln)
            if m2:
                decls.add(m2.group(1))

        for name, dline in defs.items():
            if name in decls:
                continue                      # 有前置声明，顺序无关
            call = re.compile(r"\b" + re.escape(name) + r"\s*\(")
            for i, ln in enumerate(lines[: dline - 1], 1):
                if not call.search(ln):
                    continue
                if DEF_OR_DECL.match(ln) or OBJC_AT.match(ln):
                    continue
                print("  x %s:%d 调用了 %s()，但它定义在第 %d 行" % (f.name, i, name, dline))
                bad += 1
                break

    print()
    print("顺序检查：%s" % ("全部通过" if bad == 0 else "%d 处需要调整" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
