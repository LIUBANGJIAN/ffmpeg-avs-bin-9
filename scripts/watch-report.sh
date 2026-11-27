#!/usr/bin/env bash
# ==============================================================================
# 巡检结果上报 —— 决定开 PR 还是开 issue
#
# 由 .github/workflows/watch-upstream.yml 的 report job 调用。输入全走环境变量：
#   CUR       当前锁定版本，如 9.1
#   VER       上游新版本，如 9.0.3
#   KIND      patch | minor | major
#   MANUAL    true/false —— major 时为 true（补丁护栏只认 9.*，必须人工接入）
#   VRESULT   verify job 的结果：success | failure | skipped
#   GH_TOKEN  gh 凭据，workflow 里从 secrets.GITHUB_TOKEN 注入
#
# 决策表：
#   major             -> issue    必须人工接入，不能自动改版本号了事
#   verify 失败       -> issue    附锚点失配摘录，其它什么都不做
#   verify 通过       -> PR       只改两处版本号；开不起来就降级成 issue + 手改指引
#   同版本已有未处理  -> 静默跳过  每周跑一次，不能每周刷一条
# ==============================================================================
set -uo pipefail

CUR="${CUR:-unknown}"
VER="${VER:-}"
KIND="${KIND:-unknown}"
MANUAL="${MANUAL:-false}"
VRESULT="${VRESULT:-skipped}"

log() { printf '%s\n' "$*"; }
summary() { printf '%s\n' "$*" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }

if [ -z "$VER" ]; then
  log "没有新版本，无需上报"
  exit 0
fi

log "当前 $CUR → 上游 $VER（$KIND），verify=$VRESULT"

# ------------------------------------------------------------------------------
# 去重：同一版本已经有未处理的 issue/PR 就什么都不做
# （gh issue list 会把 PR 一起列出来，所以只查一处即可覆盖两种）
# ------------------------------------------------------------------------------
ALREADY=$(gh issue list --state open --limit 200 --json number,title 2>/dev/null \
  | python3 -c '
import json, sys
ver = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
print(sum(1 for r in rows if ver in (r.get("title") or "")))
' "$VER" 2>/dev/null || echo 0)

if [ "${ALREADY:-0}" -gt 0 ] 2>/dev/null; then
  log "已有 $ALREADY 条未处理记录提到 $VER，本次不重复创建"
  summary "### 跳过：\`$VER\` 已有未处理的 issue/PR（$ALREADY 条）"
  exit 0
fi

# ------------------------------------------------------------------------------
# 验证日志摘录
# ------------------------------------------------------------------------------
LOG=$(ls verify.log verify-log/verify.log 2>/dev/null | head -1 || true)

excerpt() {
  if [ -z "${LOG:-}" ] || [ ! -f "$LOG" ]; then
    printf '（没拿到验证日志，可能 verify job 在下载源码阶段就失败了）\n'
    return
  fi
  if grep -aqE '\[X\]|\[FAIL\]|锚点匹配|SOME_ANCHOR_FAILED' "$LOG"; then
    grep -aE '\[X\]|\[FAIL\]|锚点匹配|SOME_ANCHOR_FAILED' "$LOG" | head -30
  else
    printf '（没有锚点失配行，最后 25 行如下）\n'
    tail -25 "$LOG"
  fi
}

run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

footer() {
  printf '\n---\n'
  printf '巡检工作流 [%s #%s](%s) 自动生成。\n' \
    "${GITHUB_WORKFLOW:-watch-upstream}" "${GITHUB_RUN_NUMBER:-?}" "$run_url"
  printf '只在本版本没有未处理记录时才会创建，重跑不会刷屏。\n'
}

# ------------------------------------------------------------------------------
# 情况一：出现了新 major —— 护栏 9.* 会直接拦住，必须人工
# ------------------------------------------------------------------------------
if [ "$KIND" = "major" ]; then
  log "新 major，走 issue"
  {
    printf '上游出现 **FFmpeg %s**，当前锁定 **%s**。\n\n' "$VER" "$CUR"
    printf '这是**跨 major** 的升级，不能按常规点版本处理：\n\n'
    printf -- '- `scripts/patch-ffmpeg.sh` 里的版本护栏是 `case "${FFMPEG_VERSION}" in 9.*)`，直接改版本号会被拦下\n'
    printf -- '- 跨 major 通常伴随 API 删除，6.1.6 → 9.0.2 那次就碰上 `AVCodec.pix_fmts` 被整个移除\n'
    printf -- '- 10 项锚点里至少「configure 库清单」「libuavs3d 色彩搬运」两处需要重新核对\n\n'
    printf '### 建议步骤\n\n'
    printf '1. 先在独立分支上改掉护栏与版本号，**不要动 main**\n'
    printf '2. `FFMPEG_VERSION=%s ./scripts/local-verify-patch.sh` 看哪几项锚点失配\n' "$VER"
    printf '3. 按失配点改 `scripts/patch-ffmpeg.sh` 与 `patches/libuavs3e.c`，重跑到 `ALL_ANCHORS_OK`\n'
    printf '4. 四平台编过之后，再按 9.0.2 那次的老流程做一遍能力回归（色彩 / 逐帧像素 / 编码 MD5）\n'
    footer
  } >issue-body.md

  gh issue create \
    --title "[上游巡检] FFmpeg ${VER} 是新 major，需要人工接入" \
    --body-file issue-body.md
  summary "### 需要人工：\`$VER\` 是新 major"
  exit 0
fi

# ------------------------------------------------------------------------------
# 情况二：锚点验证没过 —— 报 issue，别动版本号
# ------------------------------------------------------------------------------
if [ "$VRESULT" != "success" ]; then
  log "verify 没通过（${VRESULT}），走 issue"
  {
    printf '巡检发现上游有 **FFmpeg %s**（当前锁定 **%s**，类型 `%s`），\n' "$VER" "$CUR" "$KIND"
    printf '但补丁锚点在它上面**没能全部命中**，所以没有自动开 PR。\n\n'
    printf '这不代表新版本有问题 —— 只代表我们的补丁写死了上游的某些结构，上游挪了位置。\n\n'
    printf '### 验证输出摘录\n\n```\n'
    excerpt
    printf '```\n\n'
    printf '### 建议步骤\n\n'
    printf '1. `FFMPEG_VERSION=%s ./scripts/local-verify-patch.sh` 复现（3 秒出结果）\n' "$VER"
    printf '2. 按 `[FAIL]` 那一行去改 `scripts/patch-ffmpeg.sh` 里对应的 `edit_exact`\n'
    printf '3. 重跑到 `ALL_ANCHORS_OK`，再手动开 PR\n'
    footer
  } >issue-body.md

  gh issue create \
    --title "[上游巡检] FFmpeg ${VER} 锚点失配，暂不能自动升级" \
    --body-file issue-body.md
  summary "### 需要人工：\`$VER\` 锚点失配"
  exit 0
fi

# ------------------------------------------------------------------------------
# 情况三：锚点全绿 —— 不开 PR
#
# 以前这里会改 scripts/env.sh 并开 PR。现在升级与发布已经由 build.yml 的每日
# 巡检自动完成，再开 PR 只会两边抢着改同一个文件。这里只留个摘要，告诉人
# 「锚点没问题，日常不用管」。
# ------------------------------------------------------------------------------
log "锚点全绿，不开 PR（升级由 build.yml 自动完成）"
{
  printf '### 锚点全绿：`%s`（当前锁定 `%s`）\n\n' "$VER" "$CUR"
  printf '补丁在 **%s** 上全部命中，没有任何锚点漂移。\n\n' "$VER"
  printf '**日常升级不需要手动操作。** `build.yml` 每天 11:23（北京时间）巡检一次，\n'
  printf '发现新的 9.x 正式版会自动走完：\n\n'
  printf '1. 预验锚点（`local-verify-patch.sh`）\n'
  printf '2. 四平台编译\n'
  printf '3. 打 tag 并发布 Release\n'
  printf '4. 把新版本回写到 `scripts/env.sh`\n\n'
  printf '想让上游立刻升级，去 Actions 手动跑 `build`，版本填 `%s` 即可。\n' "$VER"
  footer
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
exit 0
