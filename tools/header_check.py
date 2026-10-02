#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
header_check.py —— 每个头文件必须把自己用到的框架类型 import 进来。

踩过的坑：GBOverlay.h 声明了 `UIWindow *_Nullable GBOverlayWindow(void);`
但只 import 了 Foundation，于是云端构建直接挂：
    GBOverlay.h:30:1: error: unknown type name 'UIWindow'

头文件不能依赖「包含它的 .m 先 import 了 UIKit」—— 包含顺序不保证。
本地没有 iOS SDK 编译不了，所以用这个脚本先把这类错误拦住。
"""
import pathlib
import re
import sys

SRC = pathlib.Path(__file__).resolve().parent.parent / "Sources"

COMMENT_LINE = re.compile(r"//[^\n]*")
COMMENT_BLOCK = re.compile(r"/\*.*?\*/", re.S)
STRING_LIT = re.compile(r'@?"(?:[^"\\]|\\.)*"')

# 框架 -> (该框架里的类型关键字, 正确的 import 写法)
FRAMEWORKS = {
    "UIKit": (["UIWindow", "UIView", "UIViewController", "UIControl", "UIButton",
               "UILabel", "UISwitch", "UISlider", "UIColor", "UIFont", "UIScrollView",
               "UITextView", "UIScreen", "UIApplication", "UIResponder", "UIEvent",
               "UIWindowScene", "UIGestureRecognizer", "UIImage", "UIImageView"],
              "<UIKit/UIKit.h>"),
    "QuartzCore": (["CALayer", "CAAnimation"], "<QuartzCore/QuartzCore.h>"),
    "CoreGraphics": (["CGRect", "CGPoint", "CGSize", "CGFloat", "CGAffineTransform"],
                     "<CoreGraphics/CoreGraphics.h>"),
    "objc/runtime": (["Method", "Ivar", "objc_property_t"], "<objc/runtime.h>"),
}


def strip_code(src: str) -> str:
    src = COMMENT_BLOCK.sub("", src)
    src = COMMENT_LINE.sub("", src)
    src = STRING_LIT.sub('""', src)
    return src


def main() -> int:
    bad = 0
    for h in sorted(SRC.glob("*.h")):
        code = strip_code(h.read_text(encoding="utf-8"))
        for fw, (types, import_path) in FRAMEWORKS.items():
            used = [t for t in types if re.search(r"\b" + t + r"\b", code)]
            if not used:
                continue
            if "#import " + import_path in code:
                continue
            # Foundation 已经把 CGRect/CGPoint/CGSize 暴露出来了，
            # 只有真正需要 CoreGraphics 专有类型时才要求显式 import
            if fw == "CoreGraphics" and "#import <Foundation/Foundation.h>" in code:
                if not {"CALayer", "CGAffineTransform"} & set(used):
                    continue
            print("  x %s 用到 %s 却没 import %s"
                  % (h.name, "/".join(used[:4]), import_path))
            bad += 1

    print()
    print("头文件依赖检查：%s" % ("全部通过" if bad == 0 else "%d 处需要修" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
