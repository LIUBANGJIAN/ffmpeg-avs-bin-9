#!/usr/bin/env bash
# ==============================================================================
# 构建决策 —— 决定「这次编什么版本、要不要发布、tag 叫什么」
#
# 由 .github/workflows/build.yml 的 resolve job 调用。它是四种触发方式的唯一
# 收敛点，后面的 windows / linux / android / release / bump 全部只看它的输出。
#
# 输入（环境变量）：
#   EVENT           github.event_name：push | schedule | workflow_dispatch
#   REF             github.ref
#   INPUT_VERSION   workflow_dispatch 的 version 输入
#   GITHUB_OUTPUT   有则写入 workflow 用的键
#   GH_TOKEN        有则允许失败时开 issue（CI 里注入）
#
# 输出（写入 $GITHUB_OUTPUT）：
#   version     本次要编的 FFmpeg 版本，如 9.2
#   tag         要打的 tag，如 v9.2-avs.1；publish=false 时为空
#   publish     true/false —— 后续所有编译与发布 job 的总开关
#   bump        true/false —— 是否要把新版本回写进 scripts/env.sh
#   bump_from   回写前 env.sh 里的版本
#   trigger     人读的触发说明
#   reason      人读的决策理由
#
# 退出码：0 决策完成；1 参数/环境有问题（不是「有新版本」这种业务结论）
# ==============================================================================
set -uo pipefail

EVENT="${EVENT:-workflow_dispatch}"
REF="${REF:-refs/heads/main}"
INPUT_VERSION="${INPUT_VERSION:-}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

say() { printf '%s\n' "$*"; }
put() { printf '%s=%s\n' "$1" "$2" >>"$OUT"; }

# ------------------------------------------------------------------------------
# 当前锁定版本：先 unset，否则外部同名变量会盖掉 env.sh 里的默认值，
# 读出来的就是「我们想编的」而不是「env.sh 锁的」，bump 判断会永远为 false。
# ------------------------------------------------------------------------------
CUR=$(env -u FFMPEG_VERSION bash -c '. ./scripts/env.sh; printf "%s" "$FFMPEG_VERSION"' 2>/dev/null || true)
if [ -z "$CUR" ]; then
  say "[error] 从 scripts/env.sh 读不到 FFMPEG_VERSION"
  exit 1
fi
say "env.sh 锁定版本：$CUR"

VER=""
TAG=""
PUBLISH="false"
BUMP="false"
BUMP_FROM=""
TRIGGER=""
REASON=""

# ------------------------------------------------------------------------------
# 失败上报：锚点失配 / 新 major 时需要人看，开 issue 但不阻断后续 job
# ------------------------------------------------------------------------------
notify_issue() {
  local title="$1" body="$2"
  say "[notify] $title"
  if [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    # 同一标题已有 open issue 就不重复开
    if gh issue list --state open --limit 200 --json title \
        --jq '.[].title' 2>/dev/null | grep -qxF "$title"; then
      say "[notify] 已有同名 open issue，跳过"
      return 0
    fi
    printf '%s\n' "$body" >/tmp/issue-body.md
    gh issue create --title "$title" --body-file /tmp/issue-body.md >/dev/null 2>&1 \
      && say "[notify] issue 已创建" \
      || say "[warn] issue 创建失败（缺权限或 gh 不可用）"
  else
    say "[warn] 没有 GH_TOKEN 或 gh，跳过 issue 上报"
  fi
}

case "$EVENT" in
  # ============================================================================
  # 推 main / 推 tag
  # ============================================================================
  push)
    case "$REF" in
      refs/tags/v*)
        TAG="${REF#refs/tags/}"
        # v9.1-avs.1 -> 9.1；v9.0.2-avs.3 -> 9.0.2
        VER=$(printf '%s' "$TAG" | sed -nE 's/^v([0-9]+\.[0-9]+(\.[0-9]+)?)-avs\..*$/\1/p')
        if [ -z "$VER" ]; then
          say "[error] tag 名不是 v<版本>-avs.<序号> 格式：$TAG"
          exit 1
        fi
        PUBLISH="true"
        TRIGGER="推送 tag $TAG"
        REASON="tag 触发，编完直接发布到该 tag"
        ;;
      *)
        VER="$CUR"
        PUBLISH="true"
        TRIGGER="推 main 后自动发布"
        REASON="main 四平台全绿即视为一个可发布版本"
        ;;
    esac
    ;;

  # ============================================================================
  # 每日巡检 —— 有新的 9.x 正式版才继续，否则整轮几十秒结束
  # ============================================================================
  schedule)
    TRIGGER="定时巡检"
    say ""
    say "== 巡检上游 =="
    # runner 上是 python3，本地 Windows 只有 python，两者都认
    PY=$(command -v python3 || command -v python || true)
    if [ -z "$PY" ]; then
      say "[warn] 找不到 python，本轮无法判断上游"
    fi
    WOUT=$(mktemp)
    if [ -n "$PY" ]; then
      GITHUB_OUTPUT="$WOUT" "$PY" scripts/watch-upstream.py --current "$CUR" || true
    fi
    HAS=$(sed -n 's/^has_update=//p' "$WOUT" | tail -1)
    LATEST=$(sed -n 's/^latest=//p' "$WOUT" | tail -1)
    KIND=$(sed -n 's/^kind=//p' "$WOUT" | tail -1)
    MANUAL=$(sed -n 's/^needs_manual=//p' "$WOUT" | tail -1)
    NOTE=$(sed -n 's/^note=//p' "$WOUT" | tail -1)
    rm -f "$WOUT"

    if [ -z "$HAS" ]; then
      # 缺 python、网络不通、API 限流都落到这里。宁可不动，也不能瞎编。
      VER="$CUR"
      PUBLISH="false"
      REASON="巡检没能得出结论（依赖或网络问题），本轮不动作"
    elif [ "$HAS" != "true" ]; then
      VER="$CUR"
      PUBLISH="false"
      REASON="上游无新版本，本轮不编译${NOTE:+（$NOTE）}"
    elif [ "$MANUAL" = "true" ]; then
      # 跨 major：patch-ffmpeg.sh 的护栏只认 9.*，硬上只会四个 job 一起红
      VER="$CUR"
      PUBLISH="false"
      REASON="上游出现新 major $LATEST，需人工接入，不自动跟进"
      notify_issue "[自动升级] FFmpeg ${LATEST} 是新 major，需人工接入" \
"每日巡检发现上游发布 **FFmpeg ${LATEST}**（当前锁定 **${CUR}**）。

这是**跨 major** 升级，自动链路已主动停在决策阶段，没有编译、没有发版。

### 为什么不能自动跟

- \`scripts/patch-ffmpeg.sh\` 的版本护栏是 \`case \"\${FFMPEG_VERSION}\" in 9.*)\`，直接改版本号会被拦下
- 跨 major 通常伴随 API 删除：6.1.6 → 9.0.2 那次就碰上 \`AVCodec.pix_fmts\` 被整个移除
- 冒烟能过的前提下，还需要过一遍色彩信令 / 逐帧像素 / 编码 MD5 的能力回归

### 建议步骤

1. 先单独分支改护栏与版本号，**不要动 main**
2. \`FFMPEG_VERSION=${LATEST} ./scripts/local-verify-patch.sh\` 看哪几项锚点失配
3. 按失配点改 \`scripts/patch-ffmpeg.sh\` 与 \`patches/libuavs3e.c\`，跑到 \`ALL_ANCHORS_OK\`
4. 四平台编过、能力回归完成后再合并 main（合并会自动发版）"
    else
      VER="$LATEST"
      BUMP_FROM="$CUR"
      BUMP="true"
      REASON="上游发布 ${LATEST}（${KIND}），锚点预验通过后自动追平"

      # 预验锚点：1~2 分钟，能省掉「四平台各红一次」的 40 分钟。
      # 环境变量优先于 env.sh 默认值，所以不用改文件就能验新版本。
      say ""
      say "== 锚点预验（$LATEST）=="
      if FFMPEG_VERSION="$VER" bash scripts/local-verify-patch.sh >/tmp/verify.log 2>&1; then
        say "[ok] 锚点全绿"
        PUBLISH="true"
      else
        say "[fail] 锚点失配，停止自动升级"
        tail -20 /tmp/verify.log || true
        PUBLISH="false"
        REASON="上游发布 ${LATEST}，但补丁锚点失配，已停止自动升级"
        FAILED=$(grep -aE '\[X\]|\[FAIL\]|SOME_ANCHOR_FAILED' /tmp/verify.log | head -20 || true)
        notify_issue "[自动升级] FFmpeg ${LATEST} 锚点失配，未能自动升级" \
"每日巡检发现上游发布 **FFmpeg ${LATEST}**（当前锁定 **${CUR}**），
但补丁锚点在它上面没能全部命中，**已停止，没有编译也没有发版**。

这不代表新版本有问题 —— 只代表补丁写死了上游的某些结构，上游挪了位置。

### 验证输出摘录

\`\`\`
${FAILED:-（没有锚点失配行，完整日志见 run 页面）}
\`\`\`

### 建议步骤

1. \`FFMPEG_VERSION=${LATEST} ./scripts/local-verify-patch.sh\` 本地复现（3 秒出结果）
2. 按 \`[FAIL]\` 那一行改 \`scripts/patch-ffmpeg.sh\` 里对应的 \`edit_exact\`
3. 跑到 \`ALL_ANCHORS_OK\` 后推 main，会自动编译并发布"
      fi
    fi
    ;;

  # ============================================================================
  # 手动
  # ============================================================================
  *)
    VER="${INPUT_VERSION:-$CUR}"
    PUBLISH="true"
    TRIGGER="手动触发"
    if [ -n "${INPUT_VERSION:-}" ] && [ "$INPUT_VERSION" != "$CUR" ]; then
      BUMP_FROM="$CUR"
      BUMP="true"
      REASON="手动指定版本 $INPUT_VERSION"
    else
      REASON="手动触发，按 env.sh 锁定版本编"
    fi
    ;;
esac

# ------------------------------------------------------------------------------
# tag 名：非 tag 触发时自己算。同版本已发过就往后顺延序号，
# 所以「推两次 main」会得到 v9.1-avs.2 / v9.1-avs.3，不会撞车。
# ------------------------------------------------------------------------------
if [ "$PUBLISH" = "true" ] && [ -z "$TAG" ]; then
  MAXN=$(git tag -l "v${VER}-avs.*" 2>/dev/null \
        | awk -F'-avs\\.' '{print $NF}' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  TAG="v${VER}-avs.$(( ${MAXN:-0} + 1 ))"
fi

if [ "$PUBLISH" != "true" ]; then
  TAG=""
  BUMP="false"
fi

say ""
say "=========================================================="
say "  版本    : $VER（env.sh 锁定 $CUR）"
say "  触发    : $TRIGGER"
say "  发布    : $PUBLISH${TAG:+  ->  $TAG}"
say "  理由    : $REASON"
say "=========================================================="

put version "$VER"
put tag "$TAG"
put publish "$PUBLISH"
put bump "$BUMP"
put bump_from "$BUMP_FROM"
put trigger "$TRIGGER"
put reason "$REASON"
exit 0
