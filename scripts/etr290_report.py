#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 TSDuck `-P analyze --json` 的输出翻译成一份 TR 101 290（ETR 290）体检结论。

为什么要单独做这一层：
  TSDuck 的 analyze 已经把 TR 101 290 需要的数据都统计出来了，但它输出的是
  一张给人看的固定宽度表格 / 一个很深的 JSON。这里只做两件事——
    1) 按 TR 101 290 的优先级（1.x / 2.x / 3.x）把指标归类、给出判定；
    2) 让脚本可以直接用退出码表达「有没有问题」，方便挂进流水线。

TR 101 290 的检查项里，analyze 能覆盖的：
  P1 (1.1) 同步丢失                     -> ts.packets.invalid-syncs
  P1 (1.2) transport_error_indicator    -> ts.packets.transport-errors
  P1 (1.4) continuity_count_error       -> pids[].packets.discontinuities
  P1 (1.5) PMT/PAT 重复间隔             -> tables[].repetition-ms
  P2 (2.1) CRC 错误                     -> analyze 只在表级体现（sections/tables 计数）
  P2 (2.2)/(2.3) PCR 重复间隔与精度      -> pcr / pcr-leap
  P2 (2.4) PTS 重复间隔                  -> pts / pts-leap / dts-leap
  P2 (2.5) PES 头错误                    -> invalid-pes-prefix
  P2 (2.6) 加扰标志异常                  -> packets.invalid-scrambling
  P3 (3.x) 表重复间隔                    -> tables[].repetition-ms / versions
不能覆盖的（需要专用分析仪）：PCR 抖动精度（±500ns）、部分描述符语法检查。

用法：
    python etr290_report.py <analyze.json> [--max-cc N] [--quiet]

    想看「抓包 + 分析 + 出报告」一条龙，用同目录的 etr290.py。
"""

import argparse
import json
import os
import sys
import unicodedata

LINE = "=" * 74
SUB = "-" * 74

# TR 101 290 里几个硬阈值
PCR_INTERVAL_MAX_MS = 40.0     # 2.3：PCR 间隔应 ≤ 40 ms（DVB 要求 ≤ 40 ms）
PTS_INTERVAL_MAX_MS = 700.0    # 2.4：PTS 间隔应 ≤ 700 ms
PAT_PMT_REPEAT_MAX_MS = 500.0  # 1.5：PAT/PMT 重复间隔 ≤ 500 ms
PAT_PMT_REPEAT_MIN_MS = 25.0   # 1.5：不允许 < 25 ms（过度重复同样违规）


# ---------------------------------------------------------------- 排版工具
def dwidth(s):
    """按终端显示宽度计算字符串宽度：CJK 宽字符算 2 列。"""
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1
               for c in s)


def pad(s, width, align="left"):
    """把 s 补齐/截断到 width 个显示列。"""
    s = str(s)
    if dwidth(s) > width:                      # 截断时也不能把一个宽字符劈开
        out = ""
        for c in s:
            if dwidth(out + c) > width:
                break
            out += c
        s = out
    gap = " " * (width - dwidth(s))
    return s + gap if align == "left" else gap + s


def kv(label, value, labelw=18):
    """对齐的 "键 : 值" 行（键按显示宽度补齐，中文才不会把冒号推歪）。"""
    return "  %s: %s" % (pad(label, labelw), value)


def pid_role(p):
    if p.get("pmt"):
        return "PMT"
    if p.get("video"):
        return "视频"
    if p.get("audio"):
        return "音频"
    if p.get("ecm"):
        return "ECM"
    if p.get("emm"):
        return "EMM"
    if p.get("iip"):
        return "IIP"
    if p.get("t2mi"):
        return "T2-MI"
    if p.get("unreferenced"):
        return "未引用"
    return p.get("description") or "其它"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json_file")
    ap.add_argument("--max-cc", type=int, default=0,
                    help="允许的 continuity_count 错误上限，默认 0（严格）")
    ap.add_argument("--quiet", action="store_true", help="只输出结论行")
    a = ap.parse_args()

    if not os.path.isfile(a.json_file):
        sys.exit("找不到 %s" % a.json_file)
    with open(a.json_file, "r", encoding="utf-8", errors="replace") as f:
        d = json.load(f)

    ts = d.get("ts", {})
    pk = ts.get("packets", {})
    pids = d.get("pids", [])
    tables = d.get("tables", [])

    dur = ts.get("duration", 0) or 0
    total_pkt = pk.get("total", 0) or 0
    bitrate = ts.get("pcr-bitrate") or ts.get("bitrate") or 0
    user_br = ts.get("user-bitrate") or 0

    fails = []       # 优先级 1 级错误
    warns = []       # 优先级 2/3 级问题

    if not a.quiet:
        print(LINE)
        print("TS 总览（TR 101 290）")
        print(SUB)
        print(kv("传输流 ID", "0x%04X (%d)" % (ts.get("id", -1), ts.get("id", -1))))
        print(kv("时长 / 包数", "%.0f 秒 / %s 包" % (dur, format(total_pkt, ","))))
        print(kv("码率(PCR 推算)", "%.2f Mbps" % (bitrate / 1e6)))
        if user_br and user_br != bitrate:
            print(kv("码率(用户指定)", "%.2f Mbps" % (user_br / 1e6)))
        print(kv("同步丢失", "%d" % pk.get("invalid-syncs", 0)))
        print(kv("transport_error", "%d" % pk.get("transport-errors", 0)))
        print(kv("可疑并忽略", "%d" % pk.get("suspect-ignored", 0)))
        sv = ts.get("pids", {}) or {}
        print(kv("PID 数", "%d（加密 %d）"
                 % (sv.get("total", 0), sv.get("scrambled", 0))))
        ssv = ts.get("services", {}) or {}
        print(kv("服务数", "%d（加密 %d）"
                 % (ssv.get("total", 0), ssv.get("scrambled", 0))))

    # ---------------- 优先级 1 ----------------
    if pk.get("transport-errors", 0):
        fails.append("1.2 transport_error_indicator = %d（应为 0）"
                     % pk["transport-errors"])
    if pk.get("invalid-syncs", 0):
        fails.append("1.1 同步丢失 %d 次" % pk["invalid-syncs"])

    cc_total = sum((p.get("packets") or {}).get("discontinuities", 0) for p in pids)
    dup_total = sum((p.get("packets") or {}).get("duplicated", 0) for p in pids)
    pkt_total = sum((p.get("packets") or {}).get("total", 0) for p in pids)
    if cc_total > a.max_cc:
        fails.append("1.4 continuity_count_error = %d（上限 %d）"
                     % (cc_total, a.max_cc))
    if dup_total:
        warns.append("1.5 重复包 %d 个" % dup_total)

    # PAT/PMT 重复间隔（1.5）
    for t in tables:
        tid = t.get("tid")
        if tid not in (0x00, 0x02):
            continue
        rep = t.get("repetition-ms")
        name = "PAT" if tid == 0x00 else "PMT"
        if rep is None:
            continue
        if rep > PAT_PMT_REPEAT_MAX_MS:
            fails.append("1.5 %s 重复间隔 %.0f ms > %.0f ms"
                         % (name, rep, PAT_PMT_REPEAT_MAX_MS))
        elif rep < PAT_PMT_REPEAT_MIN_MS:
            warns.append("1.5 %s 重复间隔 %.0f ms < %.0f ms（过度重复）"
                         % (name, rep, PAT_PMT_REPEAT_MIN_MS))

    # ---------------- 优先级 2 ----------------
    for p in pids:
        pp = p.get("packets") or {}
        name = "PID 0x%04X (%s)" % (p.get("id", -1), pid_role(p))
        if pp.get("pcr-leap", 0):
            fails.append("2.3 %s PCR 跳变 %d 次" % (name, pp["pcr-leap"]))
        if pp.get("pts-leap", 0):
            fails.append("2.4 %s PTS 跳变 %d 次" % (name, pp["pts-leap"]))
        if pp.get("dts-leap", 0):
            warns.append("2.4 %s DTS 跳变 %d 次" % (name, pp["dts-leap"]))
        if p.get("invalid-pes-prefix", 0):
            fails.append("2.5 %s PES 头非法 %d 次" % (name, p["invalid-pes-prefix"]))
        if pp.get("invalid-scrambling", 0):
            warns.append("2.6 %s 加扰标志异常 %d 次"
                         % (name, pp["invalid-scrambling"]))

        # PCR/PTS 间隔（用计数与时长估算，比 analyze 的表更直白）
        if dur > 0 and pp.get("pcr", 0) > 1:
            iv = dur * 1000.0 / pp["pcr"]
            if iv > PCR_INTERVAL_MAX_MS:
                warns.append("2.3 %s PCR 平均间隔 %.1f ms > %.0f ms"
                             % (name, iv, PCR_INTERVAL_MAX_MS))
        if dur > 0 and pp.get("pts", 0) > 1:
            iv = dur * 1000.0 / pp["pts"]
            if iv > PTS_INTERVAL_MAX_MS:
                warns.append("2.4 %s PTS 平均间隔 %.1f ms > %.0f ms"
                             % (name, iv, PTS_INTERVAL_MAX_MS))

    # ---------------- 明细表 ----------------
    if not a.quiet:
        print(SUB)
        print("按 PID 明细")
        print(SUB)
        hdr = (pad("PID", 10) + pad("角色", 12) + pad("码率Mbps", 11, "right")
               + pad("包数", 12, "right") + pad("CC错误", 9, "right")
               + pad("重复包", 9, "right") + pad("PES非法", 8, "right"))
        print("  " + hdr)
        for p in sorted(pids, key=lambda x: x.get("id", 0)):
            pp = p.get("packets") or {}
            row = (pad("0x%04X" % p.get("id", 0), 10)
                   + pad(pid_role(p), 12)
                   + pad("%.3f" % ((p.get("bitrate", 0) or 0) / 1e6), 11, "right")
                   + pad(format(pp.get("total", 0), ","), 12, "right")
                   + pad(pp.get("discontinuities", 0), 9, "right")
                   + pad(pp.get("duplicated", 0), 9, "right")
                   + pad(p.get("invalid-pes-prefix", 0), 8, "right"))
            print("  " + row)

        if tables:
            print(SUB)
            print("表重复间隔（TR 101 290 2.x / 3.x）")
            print(SUB)
            for t in sorted(tables, key=lambda x: (x.get("pid", 0), x.get("tid", 0))):
                print("  PID 0x%04X TID 0x%02X  重复 %.0f ms（%.0f~%.0f） 版本 %s"
                      % (t.get("pid", 0), t.get("tid", 0),
                         t.get("repetition-ms") or 0,
                         t.get("min-repetition-ms") or 0,
                         t.get("max-repetition-ms") or 0,
                         t.get("last-version")))

    # ---------------- 结论 ----------------
    ratio = (100.0 * cc_total / pkt_total) if pkt_total else 0.0
    if not a.quiet:
        print(LINE)
        print("判定")
        print(SUB)
        print(kv("CC 错误率", "%.6f%%（%d / %s）"
                 % (ratio, cc_total, format(pkt_total, ","))))
    if fails:
        for m in fails:
            print("  [FAIL] %s" % m)
    for m in warns:
        print("  [WARN] %s" % m)
    if not fails and not warns:
        print("  [PASS] TR 101 290 优先级 1/2 全部通过")
    elif not fails:
        print("  [PASS] 优先级 1 无错误（有 %d 条 2/3 级告警）" % len(warns))
    if not a.quiet:
        print(LINE)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
