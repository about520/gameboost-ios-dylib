#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
watch_and_fetch.py —— 等 GitHub Actions 跑完，成功就取 dylib，失败就拉日志。

用法：
    GH_TOKEN=ghp_xxx python watch_and_fetch.py <owner>/<repo> [run_id]

不给 run_id 时自动取最近一次运行。
"""

import base64
import hashlib
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request
import zipfile

API = "https://api.github.com"
UA = "GameBoost-Watcher"
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "build"


def req(method, path, token, raw=False, retries=4):
    url = API + path if path.startswith("/") else path
    for attempt in range(retries):
        r = urllib.request.Request(url, method=method)
        r.add_header("Authorization", "Bearer " + token)
        r.add_header("Accept", "application/vnd.github+json")
        r.add_header("X-GitHub-Api-Version", "2022-11-28")
        r.add_header("User-Agent", UA)
        try:
            with urllib.request.urlopen(r, timeout=60) as resp:
                body = resp.read()
                if raw:
                    return resp.status, body
                try:
                    return resp.status, json.loads(body.decode("utf-8", "replace"))
                except Exception:
                    return resp.status, body.decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            body = e.read()
            if raw:
                return e.code, body
            try:
                return e.code, json.loads(body.decode("utf-8", "replace"))
            except Exception:
                return e.code, body.decode("utf-8", "replace")
        except Exception as e:
            if attempt == retries - 1:
                return 0, str(e)
            time.sleep(2 * (attempt + 1))
    return 0, "unreachable"


def main():
    if len(sys.argv) < 2:
        print("用法: GH_TOKEN=xxx python watch_and_fetch.py <owner>/<repo> [run_id]")
        return 2
    repo = sys.argv[1]
    token = os.environ.get("GH_TOKEN", "").strip()
    if not token:
        print("❌ 缺少 GH_TOKEN")
        return 2

    rid = sys.argv[2] if len(sys.argv) > 2 else None
    if not rid:
        st, runs = req("GET", f"/repos/{repo}/actions/runs?per_page=3", token)
        if st != 200 or not runs.get("workflow_runs"):
            print(f"❌ 取运行列表失败 HTTP {st}: {str(runs)[:200]}")
            return 1
        rid = runs["workflow_runs"][0]["id"]

    print(f"▶ 运行 {rid}    https://github.com/{repo}/actions/runs/{rid}")
    status = concl = None
    for i in range(80):
        st, run = req("GET", f"/repos/{repo}/actions/runs/{rid}", token)
        if isinstance(run, dict):
            status, concl = run.get("status"), run.get("conclusion")
        print(f"\r    {i:>3}  {status} / {concl}   ", end="", flush=True)
        if status == "completed":
            break
        time.sleep(10)
    print()

    jobs_url = f"/repos/{repo}/actions/runs/{rid}/jobs"

    # —— 失败：拉日志
    if concl != "success":
        print(f"\n❌ 结论：{concl}")
        st, jobs = req("GET", jobs_url, token)
        jid = None
        for j in (jobs.get("jobs", []) if isinstance(jobs, dict) else []):
            if j.get("conclusion") == "failure":
                jid = j["id"]
                break
        if jid:
            st, log = req("GET",
                          f"/repos/{repo}/actions/jobs/{jid}/logs",
                          token, raw=True)
            txt = log.decode("utf-8", "replace") if isinstance(log, bytes) else str(log)
            pathlib.Path(ROOT / "build").mkdir(exist_ok=True)
            lp = ROOT / "build" / f"ci_log_{rid}.txt"
            lp.write_text(txt, encoding="utf-8")
            print(f"   完整日志已存: {lp}")
            # 只打错误上下文，别刷屏
            lines = txt.splitlines()
            hits = [i for i, l in enumerate(lines) if "error:" in l]
            if hits:
                print("   ── 错误行 ──")
                for i in hits[:20]:
                    print("   " + lines[i][31:][:220])
            else:
                print("   ── 末尾 25 行 ──")
                for l in lines[-25:]:
                    print("   " + l[31:][:220])
        return 1

    # —— 成功：取 artifact
    print("✅ 构建成功，下载 artifact")
    st, arts = req("GET", f"/repos/{repo}/actions/runs/{rid}/artifacts", token)
    aid = None
    for a in (arts.get("artifacts", []) if isinstance(arts, dict) else []):
        print(f"   artifact: {a['name']}  {a['size_in_bytes']} B")
        if a["name"] == "GameBoost.dylib" or a["name"].endswith(".dylib"):
            aid = a["id"]
    if not aid:
        print(f"❌ 没找到 dylib artifact：{str(arts)[:300]}")
        return 1

    st, blob = req("GET", f"/repos/{repo}/actions/artifacts/{aid}/zip", token, raw=True)
    if st != 200:
        print(f"❌ 下载 artifact 失败 HTTP {st}")
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    zpath = OUT / "artifact.zip"
    zpath.write_bytes(blob)

    got = []
    with zipfile.ZipFile(zpath) as z:
        for n in z.namelist():
            print("   包内:", n)
            if n.endswith(".dylib"):
                dst = OUT / pathlib.Path(n).name
                with z.open(n) as src, open(dst, "wb") as f:
                    f.write(src.read())
                got.append(dst)
    zpath.unlink()

    if not got:
        print("❌ 包里没有 .dylib")
        return 1

    print()
    print("=" * 60)
    for p in got:
        data = p.read_bytes()
        magic = data[:4]
        kind = {b"\xcf\xfa\xed\xfe": "Mach-O 64-bit (little endian)",
                b"\xca\xfe\xba\xbe": "Mach-O universal (fat)",
                b"\xca\xfe\xba\xbf": "Mach-O universal (fat64)"}.get(magic, "未知")
        print(f"✅ {p}")
        print(f"   大小   : {len(data)} B ({len(data)/1024:.1f} KB)")
        print(f"   魔数   : {magic.hex()}  →  {kind}")
        print(f"   SHA256 : {hashlib.sha256(data).hexdigest()}")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
