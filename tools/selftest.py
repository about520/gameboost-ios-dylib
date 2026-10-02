#!/usr/bin/env python3
"""
轻量静态自检（对象 Objective-C 的字符级扫描，不做正则偷懒）。

检查项：
  1. 花括号 / 圆括号 / 方括号 配平（正确跳过注释与字符串字面量）
  2. @interface + @implementation 与 @end 数量配对
  3. 源码中调用的 GB 前缀函数，是否在头文件里声明过（或本文件内有 static 定义）

用法： python tools/selftest.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources"


def strip_noise(text: str) -> str:
    """把注释和字符串字面量替换成等长占位符，保留换行以便报行号。"""
    out = []
    i, n = 0, len(text)
    state = "code"
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if state == "code":
            if c == "/" and nxt == "/":
                state = "line_comment"
                out.append("  ")
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block_comment"
                out.append("  ")
                i += 2
                continue
            if c == "@" and nxt == '"':
                state = "string"
                out.append("  ")
                i += 2
                continue
            if c == '"':
                state = "string"
                out.append(" ")
                i += 1
                continue
            if c == "'":
                state = "char"
                out.append(" ")
                i += 1
                continue
            out.append(c)
            i += 1
        elif state == "line_comment":
            if c == "\n":
                state = "code"
                out.append("\n")
            else:
                out.append(" ")
            i += 1
        elif state == "block_comment":
            if c == "*" and nxt == "/":
                state = "code"
                out.append("  ")
                i += 2
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
        elif state in ("string", "char"):
            if c == "\\":
                out.append("  ")
                i += 2
                continue
            if (state == "string" and c == '"') or (state == "char" and c == "'"):
                state = "code"
            out.append("\n" if c == "\n" else " ")
            i += 1

    return "".join(out)


def balance(text: str, open_ch: str, close_ch: str):
    depth, first_neg = 0, None
    for idx, line in enumerate(text.splitlines(), 1):
        for ch in line:
            if ch == open_ch:
                depth += 1
            elif ch == close_ch:
                depth -= 1
                if depth < 0 and first_neg is None:
                    first_neg = idx
    return depth, first_neg


def main() -> int:
    files = sorted(SRC.glob("*.h")) + sorted(SRC.glob("*.m"))
    if not files:
        print(f"没有在 {SRC} 找到源文件")
        return 2

    print(f"{'file':<24}{'{}':>5}{'()':>5}{'[]':>5}{'@iface':>8}{'@impl':>7}{'@end':>6}   状态")
    problems = []

    for f in files:
        raw = f.read_text(encoding="utf-8")
        code = strip_noise(raw)

        b, b_ln = balance(code, "{", "}")
        p, p_ln = balance(code, "(", ")")
        s, s_ln = balance(code, "[", "]")

        iface = len(re.findall(r"@interface\b", code))
        impl = len(re.findall(r"@implementation\b", code))
        end = len(re.findall(r"@end\b", code))

        msgs = []
        if b:
            msgs.append(f"花括号差 {b}" + (f"（第 {b_ln} 行先出现多余 }}）" if b_ln else ""))
        if p:
            msgs.append(f"圆括号差 {p}" + (f"（第 {p_ln} 行）" if p_ln else ""))
        if s:
            msgs.append(f"方括号差 {s}" + (f"（第 {s_ln} 行）" if s_ln else ""))
        if iface + impl != end:
            msgs.append(f"@interface({iface})+@implementation({impl}) != @end({end})")

        status = "OK" if not msgs else "！ " + "；".join(msgs)
        if msgs:
            problems.append(f.name)
        print(f"{f.name:<24}{b:>5}{p:>5}{s:>5}{iface:>8}{impl:>7}{end:>6}   {status}")

    # —— 跨文件函数声明检查
    declared = set()
    defined_here = set()
    for f in files:
        code = strip_noise(f.read_text(encoding="utf-8"))
        if f.suffix == ".h":
            for mt in re.finditer(r"\b(GB\w+)\s*\(", code):
                declared.add(mt.group(1))
        else:
            # 本文件内的 static / 前置声明也算已定义
            for mt in re.finditer(r"\bstatic\s+[\w\s\*<>]*?\b(GB\w+)\s*\(", code):
                defined_here.add(mt.group(1))
            for mt in re.finditer(r"^(?!\s*static)[\w\s\*<>]*?\b(GB\w+)\s*\([^;]*\)\s*\{", code, re.M):
                defined_here.add(mt.group(1))

    called = set()
    for f in files:
        if f.suffix == ".m":
            code = strip_noise(f.read_text(encoding="utf-8"))
            for mt in re.finditer(r"\b(GB[A-Z]\w+)\s*\(", code):
                called.add(mt.group(1))

    unresolved = sorted(called - declared - defined_here)

    print()
    print("—— 跨文件符号 ——")
    print(f"头文件声明 {len(declared)} 个，本文件内 static 定义 {len(defined_here)} 个，被调用 {len(called)} 个")
    if unresolved:
        print("未在头文件声明、也未识别为本文件 static 定义的调用：")
        for name in unresolved:
            print("   ·", name)
        print("（多数是识别不到的 static 定义，逐个确认即可）")
    else:
        print("全部调用都能对上声明 ✓")

    print()
    if problems:
        print("结构检查：需复查 ->", ", ".join(problems))
        return 1
    print("结构检查：全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
