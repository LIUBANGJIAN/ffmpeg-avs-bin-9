#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
etr290.py —— 一条命令做完「抓流 -> TSDuck analyze -> TR 101 290 体检报告」。

和 etr290_report.py 的分工：
  etr290_report.py  只负责「把 analyze 的 JSON 翻成人话 + 给判定 + 退出码」
  etr290.py         负责找 tsp、拼命令行、抓包、然后把 JSON 交给上面那个

用法
----
  # 实时组播抓 30 秒（最常用）
  python etr290.py 239.1.2.3:1234

  # 指定网卡（多网卡机器收不到包时基本都要加）
  python etr290.py 239.1.2.3:1234 --local-address 192.168.1.20

  # 抓 60 秒，保留 JSON 备查
  python etr290.py 239.1.2.3:1234 --seconds 60 --keep out.json

  # 分析本地录像（离线体检，不联网）
  python etr290.py 录制.ts
  python etr290.py 录制.ts --seconds 120        # 只看前 120 秒

  # 手上已经有 analyze 的 JSON，只想出报告
  python etr290.py analyze.json

退出码
------
  0 = 优先级 1/2 检查通过（可能有 3 级告警）
  1 = 有优先级 1（或 2）级错误，或抓包/分析本身失败

依赖
----
  TSDuck（tsp）。Windows 下装完默认在 C:\\tsduck\\bin\\tsp.exe，
  也会从 PATH、$TSDuck_HOME/bin、常见安装目录里自动找；
  找不到时用 --tsp 显式指定。
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

TS_FILE_EXT = (".ts", ".m2ts", ".mts", ".trp", ".mpg", ".mpeg", ".tp")
MCAST_RE = re.compile(r"^(?:\[(?P<v6>[0-9a-fA-F:]+)\]|(?P<v4>\d{1,3}(?:\.\d{1,3}){3}))"
                      r":(?P<port>\d{1,5})$")
SCHEME_RE = re.compile(r"^(?P<scheme>[a-zA-Z][a-zA-Z0-9+.-]*)://")


def eprint(*a):
    print(*a, file=sys.stderr)


def find_tsp(explicit):
    """按优先级找 tsp：显式指定 > 环境变量 > PATH > 常见安装位置。"""
    cands = []
    if explicit:
        cands.append(explicit)
    for k in ("TSDuck_HOME", "TSDUCK_HOME", "TSDUCK_ROOT"):
        v = os.environ.get(k)
        if v:
            cands.append(os.path.join(v, "bin", "tsp"))
            cands.append(os.path.join(v, "bin", "tsp.exe"))
            cands.append(os.path.join(v, "tsp"))
    for name in ("tsp", "tsp.exe"):
        w = shutil.which(name)
        if w:
            cands.append(w)
    cands += [
        r"C:\tsduck\bin\tsp.exe",
        r"C:\Program Files\TSDuck\bin\tsp.exe",
        r"C:\Program Files (x86)\TSDuck\bin\tsp.exe",
        os.path.expanduser("~/tsduck/bin/tsp"),
        "/opt/tsduck/bin/tsp",
        "/usr/bin/tsp",
        "/usr/local/bin/tsp",
    ]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return os.path.abspath(c)
    return None


def classify(src):
    """判断 source 是 json / 本地文件 / 网络地址。"""
    low = src.lower()
    if low.endswith(".json"):
        return "json", src
    if os.path.isfile(src):
        # 传绝对路径：下面会把 tsp 的 cwd 切到它自己的目录（为了让它找到 *.names），
        # 相对路径留着就会失效。
        return "file", os.path.abspath(src)
    s = SCHEME_RE.sub("", src)
    scheme = (SCHEME_RE.match(src).group("scheme").lower()
              if SCHEME_RE.match(src) else None)
    if MCAST_RE.match(s):
        return "net", (scheme, s)
    raise SystemExit(
        "看不懂这个来源：%r\n"
        "  组播请写成 239.1.2.3:1234（或 udp://239.1.2.3:1234）\n"
        "  本地文件请给已存在的 .ts 路径\n"
        "  已有 analyze JSON 请给 .json 路径" % src)


def build_cmd(tsp, kind, src, a, out_json):
    if kind == "file":
        cmd = [tsp, "-I", "file", src]
    else:
        scheme, addr = src
        if scheme and scheme not in ("udp", "ip"):
            eprint("[!] TSDuck 的 -I ip 只做裸 UDP；%s:// 会被当作 UDP 处理"
                   "（RTP 头需要 -I rtp，本脚本未启用）" % scheme)
        cmd = [tsp, "-I", "ip"]
        if a.local_address:
            cmd += ["--local-address", a.local_address]
        if a.bitrate:
            cmd += ["--bitrate", str(a.bitrate)]
        cmd += [addr]

    cmd += ["-P", "analyze", "--json", "-o", out_json]
    if a.seconds:
        cmd += ["-P", "until", "--seconds", str(int(a.seconds))]
    cmd += ["-O", "drop"]
    return cmd


def watchdog(kind, seconds):
    """给 tsp 兜一个硬超时。

    `-P until --seconds N` 只在「有数据流过」时才计时；如果这个组压根没流，
    tsp 会一直阻塞在 recv 上永不返回。所以外面必须自己掐表。
    正常情况 until 会先到点、tsp 自己退出，这里只是兜底。
    """
    grace = 300 if kind == "file" else 25
    return (seconds or 0) + grace


def run_tsp(cmd, cwd, deadline):
    """跑 tsp，返回 (returncode, stderr 文本, 是否被强杀)。"""
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         cwd=cwd)
    killed = False
    try:
        _, err = p.communicate(timeout=deadline)
    except subprocess.TimeoutExpired:
        killed = True
        p.terminate()
        try:
            _, err = p.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            _, err = p.communicate()
    except KeyboardInterrupt:
        p.terminate()
        raise
    return p.returncode, err.decode("utf-8", "replace").strip(), killed


def main():
    # 中文输出在管道/重定向时不要因为编码炸掉
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except Exception:
            pass

    ap = argparse.ArgumentParser(
        description="抓流并做 TR 101 290（ETR 290）体检",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：python etr290.py 239.1.2.3:1234 --seconds 60 --keep out.json")
    ap.add_argument("source", help="239.1.2.3:1234 / udp://… / 本地 .ts / analyze.json")
    ap.add_argument("--seconds", type=int, default=None,
                    help="抓多久（秒）。网络源默认 30；本地文件默认整段")
    ap.add_argument("--local-address", dest="local_address", default=None,
                    help="收流网卡地址，如 192.168.1.20（多网卡收不到包时加）")
    ap.add_argument("--bitrate", type=int, default=None,
                    help="告诉 analyze 一个已知码率（bps），一般不用给")
    ap.add_argument("--tsp", default=None, help="tsp 可执行文件路径")
    ap.add_argument("--keep", default=None, help="把 analyze 的 JSON 保存到该路径")
    ap.add_argument("--max-cc", dest="max_cc", type=int, default=0,
                    help="允许的 CC 错误数上限，默认 0（严格）")
    ap.add_argument("--quiet", action="store_true", help="只输出结论行")
    a = ap.parse_args()

    kind, src = classify(a.source)

    # 直接给 JSON：跳过抓包
    if kind == "json":
        return run_report(src, a)

    tsp = find_tsp(a.tsp)
    if not tsp:
        eprint("[X] 找不到 tsp（TSDuck）。")
        eprint("    Windows 安装包：https://tsduck.io/download/tsduck/latest/")
        eprint("    或用 --tsp 指定，例如 --tsp C:\\tsduck\\bin\\tsp.exe")
        return 2

    if kind == "net" and a.seconds is None:
        a.seconds = 30          # 网络源必须有个头，否则永远抓不完
    if kind == "file" and a.seconds is None:
        a.seconds = 0           # 0 = 不截断，整段分析

    tmpdir = None
    if a.keep:
        out_json = os.path.abspath(a.keep)
        od = os.path.dirname(out_json)
        if od and not os.path.isdir(od):
            os.makedirs(od, exist_ok=True)
    else:
        tmpdir = tempfile.mkdtemp(prefix="etr290_")
        out_json = os.path.join(tmpdir, "analyze.json")
    if os.path.exists(out_json):
        os.remove(out_json)     # 避免把上一次的陈旧结果当成本次结果

    cmd = build_cmd(tsp, kind, src, a, out_json)

    if not a.quiet:
        if kind == "net":
            print("[*] 抓流 %d 秒：%s" % (int(a.seconds or 0), src[1]))
            if a.local_address:
                print("[*] 收流网卡    ：%s" % a.local_address)
        else:
            lim = "前 %d 秒" % int(a.seconds) if a.seconds else "整段"
            print("[*] 离线分析    ：%s（%s）" % (os.path.basename(src), lim))
        print("[*] tsp         ：%s" % tsp)
        sys.stdout.flush()

    try:
        # cwd 切到 tsp 所在目录：TSDuck 只在「exe 自身目录」和「当前目录」找
        # tsduck.dtv.names 等名字表，从别处调用时会先甩一行
        # "Error: error opening file ...dtv.names"，看着像出错其实不影响分析。
        # 路径参数在拼命令时都已转成绝对路径，切 cwd 不会破坏它们。
        rc_tsp, err, killed = run_tsp(
            cmd, os.path.dirname(os.path.abspath(tsp)), watchdog(kind, a.seconds))
    except KeyboardInterrupt:
        eprint("\n[!] 已中断，尝试用已抓到的数据出报告")
        rc_tsp, err, killed = None, "", True

    # 名字表缺失是纯装饰性提示（只影响业务名显示），不要拿它吓人
    err = "\n".join(l for l in err.splitlines()
                    if not re.search(r"error opening file .*\.names$", l.strip()))

    if not os.path.isfile(out_json) or os.path.getsize(out_json) < 16:
        eprint("[X] 没拿到 analyze 结果。")
        if killed and kind == "net":
            eprint("    （tsp 在 %.0f 秒内一个包都没收到，被强制结束）" % a.seconds)
        if err:
            eprint("--- tsp 输出 ---")
            eprint(err[-2000:])
        if kind == "net":
            eprint("可能原因（按概率排序）：")
            eprint("  1) 组地址/端口不对，或该组当前没有流；")
            eprint("  2) 多网卡机器默认选了错误的网卡 —— 加 --local-address <本机IP>；")
            eprint("  3) 本机没有到该组播的路由（需要接在业务网内）；")
            eprint("  4) 防火墙拦了 UDP。")
        return 2

    if err and not a.quiet:
        # tsp 有时会往 stderr 打非致命提示，保留但压缩
        tail = [l for l in err.splitlines() if l.strip()][-5:]
        if tail:
            print("[!] tsp 提示：")
            for l in tail:
                print("    " + l)

    rc = run_report(out_json, a)

    if a.keep and not a.quiet:
        print("[*] analyze JSON 已保存：%s" % out_json)

    if tmpdir:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return rc


def run_report(json_path, a):
    """调用同目录的 etr290_report.py（同进程 import，省一层解释器启动）。"""
    sys.path.insert(0, HERE)
    try:
        import etr290_report as rep
    except ImportError as e:
        eprint("[X] 找不到 etr290_report.py（应与本脚本同目录）：%s" % e)
        return 2
    argv = [json_path, "--max-cc", str(a.max_cc)]
    if a.quiet:
        argv.append("--quiet")
    old = sys.argv
    sys.argv = ["etr290_report.py"] + argv
    try:
        return rep.main()
    finally:
        sys.argv = old


if __name__ == "__main__":
    sys.exit(main())
