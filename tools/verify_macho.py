#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_macho.py —— 不依赖 macOS 工具，纯 Python 解析 Mach-O，验证 dylib 是不是真货。

检查项：
  · fat header：几个架构切片、每个切片的 CPU 类型与大小
  · 每个切片头：magic / cputype / filetype 是否为 MH_DYLIB
  · LC_ID_DYLIB：install_name 对不对
  · LC_BUILD_VERSION：platform 是不是 iOS、最低版本
  · 链接了哪些库（LC_LOAD_DYLIB）
  · __TEXT 段是否含我们自己的 ObjC 类名（证明代码真在里面）

用法： python verify_macho.py build/GameBoost.dylib
"""

import pathlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_DYLIB = 0x6

CPU_NAMES = {
    7: "x86", 0x01000007: "x86_64",
    12: "ARM", 0x0100000C: "arm64",
}
SUBTYPE_ARM64E = 2
PLATFORMS = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS",
             6: "macCatalyst", 7: "iOS Simulator"}
LC = {0x0C: "LC_LOAD_DYLIB", 0x0D: "LC_ID_DYLIB",
      0x32: "LC_BUILD_VERSION", 0x24: "LC_VERSION_MIN_IPHONEOS",
      0x1D: "LC_CODE_SIGNATURE", 0x2B: "LC_SOURCE_VERSION"}


def parse_slice(data, off, label):
    """解析一个 Mach-O 64 位切片，返回信息 dict。"""
    info = {"label": label, "offset": off}
    if len(data) < off + 32:
        info["error"] = "切片头越界"
        return info
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags = \
        struct.unpack_from("<IiiIIII", data, off)
    info.update(magic=magic, cputype=cputype, cpusubtype=cpusubtype,
                filetype=filetype, ncmds=ncmds, sizeofcmds=sizeofcmds,
                flags=flags)
    info["cpu"] = CPU_NAMES.get(cputype, hex(cputype))
    info["is_dylib"] = (filetype == MH_DYLIB)
    info["is_64"] = (magic == MH_MAGIC_64)

    cmd_off = off + 32
    end = cmd_off + sizeofcmds
    loads, ident, platform, minos = [], None, None, None
    while cmd_off < end and cmd_off + 8 <= len(data):
        cmd, cmdsize = struct.unpack_from("<II", data, cmd_off)
        name = LC.get(cmd, hex(cmd))
        if name == "LC_ID_DYLIB" or name == "LC_LOAD_DYLIB":
            if cmdsize >= 24:
                nameoff = struct.unpack_from("<I", data, cmd_off + 8)[0]
                s = data[cmd_off + nameoff: cmd_off + cmdsize]
                s = s.split(b"\x00")[0].decode("utf-8", "replace")
                if name == "LC_ID_DYLIB":
                    ident = s
                else:
                    loads.append(s)
        if name == "LC_BUILD_VERSION" and cmdsize >= 24:
            platform = struct.unpack_from("<I", data, cmd_off + 8)[0]
            minos = struct.unpack_from("<I", data, cmd_off + 12)[0]
        cmd_off += cmdsize
    info["id"] = ident
    info["loads"] = loads
    info["platform"] = PLATFORMS.get(platform, platform)
    if minos is not None:
        info["min_os"] = f"{(minos >> 16)}.{(minos >> 8) & 0xFF}"
    return info


def main():
    p = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "build/GameBoost.dylib")
    data = p.read_bytes()
    print("=" * 68)
    print(f" 验证 {p}")
    print("=" * 68)
    print(f"文件大小 : {len(data)} B ({len(data)/1024:.1f} KB)")

    magic4 = data[:4]
    slices = []
    if magic4 == b"\xca\xfe\xba\xbe":                # fat（大端）
        nfat = struct.unpack_from(">I", data, 4)[0]
        print(f"容器     : Mach-O universal / fat，{nfat} 个切片")
        print()
        print(f"{'架构':<10}{'CPU':<12}{'subtype':<9}{'offset':>10}{'size':>10}")
        print("-" * 68)
        for i in range(nfat):
            cputype, cpusub, off, size, align = struct.unpack_from(">iiIII", data, 8 + i * 20)
            cpu = CPU_NAMES.get(cputype, hex(cputype))
            sub = "arm64e" if cpusub == SUBTYPE_ARM64E else str(cpusub)
            print(f"{cpu:<10}{hex(cputype):<12}{sub:<9}{off:>10}{size:>10}")
            slices.append((off, size, cpu, sub))
        print()
        for off, size, cpu, sub in slices:
            print("-" * 68)
            info = parse_slice(data, off, f"{cpu}/{sub}")
            print(f"▶ 切片 {cpu}/{sub}  @ 0x{off:x}")
            if "error" in info:
                print(f"    ✗ {info['error']}")
                continue
            print(f"    magic       : {hex(info['magic'])}  ({'64 位' if info['is_64'] else '非 64 位'})")
            print(f"    CPU         : {info['cpu']} (cputype={info['cputype']}, cpusubtype={info['cpusubtype']})")
            print(f"    filetype    : {info['filetype']}  ({'MH_DYLIB ✓' if info['is_dylib'] else '不是 dylib ✗'})")
            print(f"    load cmds   : {info['ncmds']} 条, {info['sizeofcmds']} 字节")
            print(f"    install name: {info['id']}")
            print(f"    platform    : {info['platform']}  最低版本 {info.get('min_os', '?')}")
            libs = [l for l in info["loads"]]
            print(f"    链接库({len(libs)}) :")
            for l in libs:
                print(f"        {l}")
    elif magic4 == b"\xcf\xfa\xed\xfe":              # 单架构 64 位
        print("容器     : Mach-O 64 位（单架构，非 fat）")
        print()
        info = parse_slice(data, 0, "single")
        print(f"    CPU         : {info['cpu']}")
        print(f"    filetype    : {info['filetype']}  ({'MH_DYLIB ✓' if info['is_dylib'] else '不是 dylib ✗'})")
        print(f"    install name: {info['id']}")
        print(f"    platform    : {info['platform']}  最低版本 {info.get('min_os', '?')}")
        for l in info["loads"]:
            print(f"        {l}")
    else:
        print(f"✗ 未知容器：{magic4.hex()}")
        return 1

    # —— 代码是否真在里面
    print()
    print("-" * 68)
    print("▶ 二进制里是否含我们自己的符号/类名")
    #
    # 注意编码：clang 把 **非 ASCII** 的 @"..." 字面量存成 UTF-16LE 放进
    # __TEXT,__ustring，纯 ASCII 的才以 UTF-8 留在 __cstring。所以中文字
    # 串必须两种编码都试，只按 UTF-8 搜会全 ✗ 造成误判。
    marks = [b"GameBoost", b"GBOverlay", b"GBAdHooks", b"GBRewardHooks",
             b"GBConfig", b"GBEntry", b"GBInstallHook", b"saveBallCenter",
             b"beginAppearanceTransition", b"multiplier",
             "GBPassthroughWindow", "GBPassthroughView",
             "onHide15:", "onResetBall:", "resetBallPosition",
             "悬浮球归位到屏幕右侧", "临时隐藏 15 秒（点击被挡时用）"]
    hit = 0
    for m in marks:
        b = m if isinstance(m, bytes) else m.encode("utf-8")
        label = b.decode("utf-8", "replace")
        n = data.count(b)
        enc = "utf-8"
        if isinstance(m, str) and not m.isascii():
            # 中文串按 UTF-16LE 再数一次
            n16 = data.count(m.encode("utf-16-le"))
            enc = "utf-16le"
            n = max(n, n16)
        flag = "✓" if n else "✗"
        if n:
            hit += 1
        print(f"    {flag} {label:<26} 出现 {n} 次 ({enc})")
    print()
    print(f"命中 {hit}/{len(marks)} 个标志串")
    print("=" * 68)
    return 0


if __name__ == "__main__":
    sys.exit(main())
