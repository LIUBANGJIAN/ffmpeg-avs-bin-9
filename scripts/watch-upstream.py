#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
上游巡检 —— FFmpeg 有没有发布比当前锁定版本更新的版本？

## 为什么要双源交叉

两个源各自代表一件不同的事，缺一不可：

  ffmpeg.org/releases/ffmpeg-<ver>.tar.xz   「官方确实发了这个版本」
  GitHub tag n<ver>                         「本仓库真的能拉到这份源码」

后者的必要性来自 env.sh：FFMPEG_URL 指向
github.com/FFmpeg/FFmpeg/archive/refs/tags/n<ver>.tar.gz，
所以「官网有、GitHub 还没同步」的版本追了会在下载阶段 404。

反过来「GitHub 有、官网没有」也不是正式发布，追了等于自己当小白鼠。

## 上游版本列表从哪来

endoflife.date 的 JSON，能一次看到所有还活着的 release 线
（包括什么时候冒出新 major）。它是第三方镜像数据，可能延迟或出错，
所以它算出的候选版仍然要过上面两道验证才作数。

它整个挂掉时退化为「按序探测 patch / minor」，巡检不会因此停摆。

## 用法

  python3 scripts/watch-upstream.py                        # 读 $FFMPEG_VERSION
  python3 scripts/watch-upstream.py --current 9.0.2
  python3 scripts/watch-upstream.py --current 9.0.2 --want 9.0.3

输出：判定过程打到 stdout；$GITHUB_OUTPUT 存在时写入 workflow 用的键。
退出码：0 判定完成（「没有更新」也算完成）；2 参数或探测失败。
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

EOL_API = "https://endoflife.date/api/ffmpeg.json"
REL_XZ = "https://ffmpeg.org/releases/ffmpeg-{v}.tar.xz"
GH_REF = "https://api.github.com/repos/FFmpeg/FFmpeg/git/ref/tags/n{v}"
UA = "ffmpeg-avs-watch/1.0 (+https://github.com/LIUBANGJIAN/ffmpeg-avs-bin-9)"

_cache = {}


def say(msg=""):
    print(msg, flush=True)


def parse_ver(s):
    """'9.0.2' -> (9,0,2)；'9.1' -> (9,1,0)；'n9.0.2' 也认。解析不了返回 None。"""
    if s is None:
        return None
    s = str(s).strip()
    if s.startswith("n"):
        s = s[1:]
    m = re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?$", s)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)


def _token():
    return os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""


def _open(url, method, timeout):
    req = urllib.request.Request(url, method=method)
    req.add_header("User-Agent", UA)
    if "api.github.com" in url and _token():
        # 未认证的 api.github.com 只有 60 次/小时，巡检虽然用得少，
        # 但 runner 上 GITHUB_TOKEN 现成，带上更稳妥。
        req.add_header("Authorization", "Bearer " + _token())
    return urllib.request.urlopen(req, timeout=timeout)


def head_status(url, timeout=25):
    """只发 HEAD，不拉 body。返回状态码；网络层失败返回 None。"""
    try:
        with _open(url, "HEAD", timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        say("    [warn] HEAD %s -> %s" % (url, e))
        return None


def api_status(url, timeout=25):
    """GitHub 的 /git/ref 对 HEAD 支持不稳，用 GET，但 body 只有几百字节。"""
    try:
        with _open(url, "GET", timeout) as r:
            r.read(2048)
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        say("    [warn] GET %s -> %s" % (url, e))
        return None


def official_ok(v):
    """官网 tar.xz 在不在。"""
    key = ("xz", v)
    if key not in _cache:
        st = head_status(REL_XZ.format(v=v))
        _cache[key] = (st == 200)
        say("    官网 ffmpeg-%s.tar.xz -> %s" % (v, st))
    return _cache[key]


def gh_tag(t):
    """
    GitHub 上有没有 tag n<ver>，有则返回对应的版本串。

    FFmpeg 的点版本和次版本命名不一样：9.0.3 是「9.0.3」，
    而 9.1 就是「9.1」而不是「9.1.0」。

    注意这里有个必须守住的边界：三段式（9.0.3）只能认精确名。
    早期版本曾让 9.0.3 在失败后回落到 9.0 并返回成功，
    结果是「版本不存在」被静默报成「已是最新」——比报错恶劣得多。
    """
    if t[2]:
        cands = ["%d.%d.%d" % t]
    else:
        cands = ["%d.%d" % t[:2]]
    for v in cands:
        key = ("gh", v)
        if key not in _cache:
            st = api_status(GH_REF.format(v=v))
            _cache[key] = (st == 200)
            say("    GitHub tag n%s -> %s" % (v, st))
        if _cache[key]:
            return v
    return None


def usable(t):
    """两个源都过才返回真实版本串，否则 None。"""
    if t is None:
        return None
    gh = gh_tag(t)
    if not gh:
        return None
    if not official_ok(gh):
        return None
    return gh


def fetch_eol():
    """拉 endoflife.date 的 FFmpeg 版本线。失败返回空列表（调用方会降级）。"""
    try:
        with _open(EOL_API, "GET", 25) as r:
            data = json.load(r)
        if isinstance(data, list):
            return [c for c in data if isinstance(c, dict) and c.get("cycle")]
    except Exception as e:
        say("    [warn] endoflife.date 不可用：%s" % e)
    return []


def emit(path, kv):
    if not path:
        return
    with open(path, "a", encoding="utf-8") as f:
        for k, v in kv.items():
            v = str(v).replace("\n", " ").replace("\r", " ")
            f.write("%s=%s\n" % (k, v))


def main():
    ap = argparse.ArgumentParser(description="FFmpeg 上游版本巡检")
    ap.add_argument("--current", default=os.environ.get("FFMPEG_VERSION", ""),
                    help="当前锁定版本，默认读 $FFMPEG_VERSION")
    ap.add_argument("--want", default="",
                    help="手动指定要验证的版本（跳过上游检测）")
    ap.add_argument("--outputs", default=os.environ.get("GITHUB_OUTPUT", ""),
                    help="GitHub Actions 输出文件，默认读 $GITHUB_OUTPUT")
    a = ap.parse_args()

    cur = parse_ver(a.current)
    if cur is None:
        say("[error] 当前版本解析失败：%r" % a.current)
        return 2
    cur_s = "%d.%d.%d" % cur
    say("当前锁定：%s" % cur_s)

    latest = None
    new_major = None
    note = ""

    if a.want:
        # ---------------------------------------------------------------
        # 手动模式：只验指定的那一个版本，不去猜上游最新是什么
        # ---------------------------------------------------------------
        say("[模式] 手动指定：%s" % a.want)
        t = parse_ver(a.want)
        if t is None:
            say("[error] 版本格式不对（要 X.Y 或 X.Y.Z）：%r" % a.want)
            return 2
        v = usable(t)
        if not v:
            say("[error] %s 没能通过双源确认（官网没发 / GitHub 没有 tag n%s）"
                % (a.want, a.want))
            return 2
        latest = v
    else:
        # ---------------------------------------------------------------
        # 自动模式
        # ---------------------------------------------------------------
        say("[1/2] 问上游有哪些 release 线")
        cycles = fetch_eol()
        if cycles:
            same, higher = [], []
            for c in cycles:
                t = parse_ver(c.get("cycle", ""))
                if not t:
                    continue
                if t[0] == cur[0]:
                    same.append(c)
                elif t[0] > cur[0]:
                    higher.append(c)
            if same:
                best = max(same, key=lambda c: parse_ver(c.get("latest") or c["cycle"]) or (0, 0, 0))
                latest = best.get("latest") or best["cycle"]
                say("    同 major 最新：%s（%s）" % (latest, best.get("latestReleaseDate") or "?"))
            if higher:
                nb = max(higher, key=lambda c: parse_ver(c.get("cycle")) or (0, 0, 0))
                new_major = nb.get("latest") or nb["cycle"]
                say("    发现更高 major：%s（%s）" % (new_major, nb.get("cycle")))

        if not latest and not new_major:
            say("")
            say("[2/2] 按序探测（先补丁号，再试下一个 minor）")
            if cycles:
                note = "上游确无更新"
            for p in range(cur[2] + 1, cur[2] + 8):
                v = usable((cur[0], cur[1], p))
                if v:
                    latest = v
                    break
            if not latest:
                for mi in range(cur[1] + 1, cur[1] + 3):
                    v = usable((cur[0], mi, 0))
                    if v:
                        latest = v
                        break

    # -------------------------------------------------------------------
    # 定候选：新 major 才是「最新」，优先于同 major 的点版本
    # -------------------------------------------------------------------
    final = None
    if new_major:
        t = parse_ver(new_major)
        if t and t > cur:
            final = new_major
    if not final and latest:
        t = parse_ver(latest)
        if t and t > cur:
            final = latest

    if final:
        say("")
        say("[校验] 候选 %s 过双源" % final)
        real = usable(parse_ver(final))
        if not real:
            say("    [warn] %s 两个源没能同时确认，本次不动作" % final)
            note = (note + "；" if note else "") + "%s 探测未通过（疑似 API 数据延迟）" % final
            final = None
        else:
            final = real

    has_update = final is not None
    if has_update:
        t = parse_ver(final)
        if t[0] != cur[0]:
            kind = "major"
        elif t[1] != cur[1]:
            kind = "minor"
        else:
            kind = "patch"
    else:
        kind = "none"

    say("")
    say("=" * 56)
    if has_update:
        say("结论：有更新  %s -> %s（%s）" % (cur_s, final, kind))
    else:
        say("结论：已是最新（%s）" % cur_s)
    if note:
        say("备注：%s" % note)
    say("=" * 56)

    emit(a.outputs, {
        "current": cur_s,
        "latest": final or "",
        "has_update": "true" if has_update else "false",
        "kind": kind,
        "needs_manual": "true" if kind == "major" else "false",
        "note": note,
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
