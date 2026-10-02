#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
deploy_via_api.py —— 完全绕开 git 传输通道，用 GitHub Git Data API 推代码。

为什么需要它：
    本机到 github.com 的 git-over-HTTPS 传输极慢（实测卡住不动），
    但 api.github.com 响应正常（200 / 0.3s）。所以把「推送」拆成
    纯 REST 调用：

        POST /git/blobs     逐个文件上传（base64）
        POST /git/trees     组装目录树
        POST /git/commits   创建提交
        POST /git/refs      写入 refs/heads/main

    顺带强制 LF 行尾（macOS runner 上 CRLF 的 .sh 会 bad interpreter）。

用法：
    GH_TOKEN=ghp_xxx python deploy_via_api.py <owner>/<repo> [源目录]
"""

import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
UA = "GameBoost-Deployer"


def req(method, path, token, payload=None, retries=4):
    """带重试的 REST 调用；返回 (状态码, 解析后的 JSON 或原始文本)。"""
    url = API + path
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    last = None
    for attempt in range(retries):
        r = urllib.request.Request(url, data=data, method=method)
        r.add_header("Authorization", "Bearer " + token)
        r.add_header("Accept", "application/vnd.github+json")
        r.add_header("X-GitHub-Api-Version", "2022-11-28")
        r.add_header("User-Agent", UA)
        if data:
            r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                body = resp.read().decode("utf-8", "replace")
                try:
                    return resp.status, json.loads(body)
                except Exception:
                    return resp.status, body
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            try:
                parsed = json.loads(body)
            except Exception:
                parsed = body
            # 4xx（除限流）不重试
            if e.code in (403, 429) or e.code >= 500:
                last = (e.code, parsed)
                time.sleep(2 * (attempt + 1))
                continue
            return e.code, parsed
        except Exception as e:                      # 网络层
            last = (0, str(e))
            time.sleep(2 * (attempt + 1))
    return last if last else (0, "unknown error")


# 需要强制 LF 的文本扩展名（macOS runner 上 CRLF 会直接搞死构建）
TEXT_EXT = {
    ".sh", ".yml", ".yaml", ".py", ".m", ".h", ".c", ".cpp", ".md",
    ".txt", ".json", ".js", ".ts", ".rb", ".mk", ".plist", ".entitlements",
}
TEXT_NAMES = {"Makefile", "makefile", "control", ".gitattributes",
              ".gitignore", "LICENSE", "Dockerfile", "README"}


def is_text(path: pathlib.Path, raw: bytes) -> bool:
    if b"\x00" in raw[:4096]:
        return False
    if path.suffix.lower() in TEXT_EXT:
        return True
    if path.name in TEXT_NAMES or path.name.startswith("."):
        return True
    return True                                     # 本工程全是文本


def normalize(path: pathlib.Path, raw: bytes):
    """返回 (bytes, 是否做过 CRLF→LF 转换)。"""
    if is_text(path, raw):
        new = raw.replace(b"\r\n", b"\n")
        return new, (new != raw)
    return raw, False


def main():
    if len(sys.argv) < 2:
        print("用法: GH_TOKEN=xxx python deploy_via_api.py <owner>/<repo> [源目录]")
        return 2
    repo = sys.argv[1]
    src = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parent.parent
    token = os.environ.get("GH_TOKEN", "").strip()
    if not token:
        print("❌ 缺少 GH_TOKEN")
        return 2

    print("=" * 60)
    print(" 用 Git Data API 推送（绕过 git 传输）")
    print("=" * 60)

    # 收集文件
    files, skipped = [], []
    for p in sorted(src.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(src)
        if rel.parts and rel.parts[0] in (".git", ".ghcli", "build", "__pycache__"):
            skipped.append(str(rel))
            continue
        files.append((p, rel))

    print(f"▶ 源目录 : {src}")
    print(f"▶ 仓库   : {repo}")
    print(f"▶ 文件数 : {len(files)}（跳过 {len(skipped)}）")
    if skipped:
        print(f"   跳过: {', '.join(skipped[:6])}{' ...' if len(skipped) > 6 else ''}")
    print()

    # 0) 空仓库不给建 blob（409 Git Repository is empty），
    #    先用 Contents API 打一个初始化提交把 main 建出来。
    st_ref, ref = req("GET", f"/repos/{repo}/git/ref/heads/main", token)
    if st_ref != 200:
        print("→ 仓库为空，先用 Contents API 初始化 main")
        st, res = req("PUT", f"/repos/{repo}/contents/.gitkeep", token, {
            "message": "chore: 初始化仓库",
            "content": base64.b64encode(b"").decode("ascii"),
        })
        if st not in (200, 201):
            print(f"  ✗ 初始化失败 HTTP {st}: {str(res)[:300]}")
            return 1
        print(f"  ✓ main 已创建 ({res.get('commit', {}).get('sha', '')[:12]})")
        time.sleep(3)                     # 等 GitHub 侧 ref 可见
        for _ in range(6):
            st_ref, ref = req("GET", f"/repos/{repo}/git/ref/heads/main", token)
            if st_ref == 200:
                break
            time.sleep(2)
        if st_ref != 200:
            print(f"  ✗ 初始化后仍读不到 main（HTTP {st_ref}）")
            return 1
        print()

    # 1) 逐个建 blob
    print("→ 上传 blobs")
    entries, fixed_lf = [], []
    for p, rel in files:
        raw = p.read_bytes()
        data, changed = normalize(p, raw)
        if changed:
            fixed_lf.append(str(rel))
        st, res = req("POST", f"/repos/{repo}/git/blobs", token,
                      {"content": base64.b64encode(data).decode("ascii"),
                       "encoding": "base64"})
        if st not in (200, 201) or not isinstance(res, dict) or "sha" not in res:
            print(f"  ✗ {rel}  HTTP {st}  {str(res)[:160]}")
            return 1
        entries.append({"path": str(rel).replace("\\", "/"),
                        "mode": "100755" if p.suffix == ".sh" else "100644",
                        "type": "blob", "sha": res["sha"]})
        print(f"  ✓ {str(rel):<44} {len(data):>6} B")
    if fixed_lf:
        print(f"  （顺手修了 {len(fixed_lf)} 个 CRLF→LF: {', '.join(fixed_lf)}）")
    print()

    # 2) tree
    print("→ 组装 tree")
    st, tree = req("POST", f"/repos/{repo}/git/trees", token, {"tree": entries})
    if st not in (200, 201) or not isinstance(tree, dict) or "sha" not in tree:
        print(f"  ✗ 建 tree 失败 HTTP {st}: {str(tree)[:300]}")
        return 1
    print(f"  ✓ tree {tree['sha'][:12]}  共 {len(entries)} 项")
    print()

    # 3) 判断是否已有 main，决定是否带 parent
    st_ref, ref = req("GET", f"/repos/{repo}/git/ref/heads/main", token)
    parents = []
    if st_ref == 200 and isinstance(ref, dict) and "object" in ref:
        parents = [ref["object"]["sha"]]
        print(f"→ main 已存在（{parents[0][:12]}），将作为父提交")
    else:
        print("→ main 尚不存在（空仓库），创建首个提交")

    st, commit = req("POST", f"/repos/{repo}/git/commits", token, {
        "message": "GameBoost: iOS 免越狱注入型 dylib（悬浮窗 + 跳过广告 + 奖励翻倍）",
        "tree": tree["sha"],
        "parents": parents,
    })
    if st not in (200, 201) or not isinstance(commit, dict) or "sha" not in commit:
        print(f"  ✗ 建 commit 失败 HTTP {st}: {str(commit)[:300]}")
        return 1
    print(f"  ✓ commit {commit['sha'][:12]}")
    print()

    # 4) 写 ref
    if parents:
        st, res = req("PATCH", f"/repos/{repo}/git/refs/heads/main", token,
                      {"sha": commit["sha"], "force": False})
    else:
        st, res = req("POST", f"/repos/{repo}/git/refs", token,
                      {"ref": "refs/heads/main", "sha": commit["sha"]})
    if st not in (200, 201):
        print(f"  ✗ 写 ref 失败 HTTP {st}: {str(res)[:300]}")
        return 1
    print(f"  ✓ refs/heads/main → {commit['sha'][:12]}")
    print()

    print("=" * 60)
    print(f"✅ 推送完成： https://github.com/{repo}")
    print(f"   commit: {commit['sha']}")
    print(f"   文件数: {len(files)}")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
