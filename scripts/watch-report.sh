#!/usr/bin/env bash
# ==============================================================================
# 巡检结果上报 —— 决定开 PR 还是开 issue
#
# 由 .github/workflows/watch-upstream.yml 的 report job 调用。输入全走环境变量：
#   CUR       当前锁定版本，如 9.0.2
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
# 情况三：锚点全绿 —— 改版本号、开 PR
# ------------------------------------------------------------------------------
log "锚点全绿，走 PR"
BRANCH="chore/bump-ffmpeg-${VER}"

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git checkout -B "$BRANCH" >/dev/null 2>&1 || true

bump_version() {
  python3 - "$VER" <<'PY'
import re, sys, pathlib

ver = sys.argv[1]
# 只改 env.sh —— 版本号现在是单一来源。
# 刻意不碰 .github/workflows/*：GITHUB_TOKEN 没有 workflows 权限，
# 带 workflow 改动的 push 会被服务端直接拒绝，实测原文：
#   refusing to allow a GitHub App to create or update workflow
#   `.github/workflows/build.yml` without `workflows` permission
rules = [
    ("scripts/env.sh",
     r'^FFMPEG_VERSION="\$\{FFMPEG_VERSION:-[^}]*\}"$',
     'FFMPEG_VERSION="${FFMPEG_VERSION:-%s}"' % ver),
]
for path, pat, rep in rules:
    p = pathlib.Path(path)
    # newline='' 必须加，与 lib.sh 的 edit_exact 同理：
    # 否则在 Windows 上回写会把整篇文件改成 CRLF，configure 的 #!/bin/sh\r 直接崩
    with open(p, "r", encoding="utf-8", newline="") as f:
        s = f.read()
    s2, n = re.subn(pat, rep, s, count=1, flags=re.M)
    if n != 1:
        sys.exit("锚点未命中：%s（期望 1 处，实际 %d 处）" % (path, n))
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s2)
    print("  %s -> %s" % (path, rep))
PY
}

cat >pr-body.md <<EOF
上游发布 FFmpeg **${VER}**，当前锁定 **${CUR}**（类型 \`${KIND}\`）。

本 PR 由 \`.github/workflows/watch-upstream.yml\` 的例行巡检自动生成。

### 已经验证过的

- \`scripts/local-verify-patch.sh\` 在 ${VER} 源码的临时副本上跑通，10 项锚点全部命中（\`ALL_ANCHORS_OK\`）
- 改动只有一处：\`scripts/env.sh\` 的 \`FFMPEG_VERSION\`。版本号现在是单一来源，
  \`build.yml\` 里已不含任何版本字面量（linux job 现场从 env.sh 读）

### 没有验证过的

- **没有编译过。** 锚点匹配只证明「补丁能干净打上去」，不证明「能编出来」。跨 minor 时 API 变更只能靠实编暴露 —— 参考 6.1.6 → 9.0.2 那次 \`AVCodec.pix_fmts\` 被整个移除。
- 本仓库的 \`build.yml\` 只监听 \`main\` 与 \`v*\` tag，**PR 本身不触发构建**。merge 之后才会起一轮四平台构建（约 36~55 分钟），那才是真验证。

### 建议的处理顺序

1. 想先在自己机器上确认：\`FFMPEG_VERSION=${VER} ./scripts/local-verify-patch.sh\`
2. merge 到 main，等 \`build.yml\` 四平台全绿
3. 产物回来照老流程过一遍（色彩信令 / 逐帧像素 / 编码 MD5），再打 tag 出正式包
EOF

ERRLOG=$(mktemp)

# 1) 改版本号
if ! bump_version >"$ERRLOG" 2>&1; then
  log "改版本号失败"
  {
    printf '巡检发现 **FFmpeg %s**（当前锁定 **%s**），锚点验证全绿，\n' "$VER" "$CUR"
    printf '但**改版本号时锚点失配** —— `scripts/env.sh` 里那一行的写法变了。\n\n'
    printf '### 输出\n\n```\n'
    tail -20 "$ERRLOG" 2>/dev/null || printf '（无输出）\n'
    printf '```\n\n### 手改（就一行）\n\n```diff\n'
    printf -- '--- a/scripts/env.sh\n+++ b/scripts/env.sh\n'
    printf -- '-FFMPEG_VERSION="${FFMPEG_VERSION:-%s}"\n' "$CUR"
    printf -- '+FFMPEG_VERSION="${FFMPEG_VERSION:-%s}"\n' "$VER"
    printf '```\n'
    footer
  } >issue-body.md
  gh issue create --title "[上游巡检] FFmpeg ${VER} 可升级，但改版本号失败" \
    --body-file issue-body.md
  summary "### 需要人工：\`$VER\` 改版本号失败"
  rm -f "$ERRLOG"
  exit 0
fi

# 2) 提交
git add scripts/env.sh
if ! git commit -q -m "chore: 追平 FFmpeg ${VER}（锚点已验证，待 CI 实编）" >>"$ERRLOG" 2>&1; then
  log "commit 失败"
  {
    printf '巡检发现 **FFmpeg %s**（当前锁定 **%s**），锚点全绿，但本地提交失败。\n\n' "$VER" "$CUR"
    printf '### 输出\n\n```\n'
    tail -20 "$ERRLOG" 2>/dev/null || printf '（无输出）\n'
    printf '```\n'
    footer
  } >issue-body.md
  gh issue create --title "[上游巡检] FFmpeg ${VER} 可升级，但提交失败" \
    --body-file issue-body.md
  summary "### 需要人工：\`$VER\` 提交失败"
  rm -f "$ERRLOG"
  exit 0
fi

# 3) 推分支 —— 单独判，因为「推成功但建 PR 被拒」和「推就失败」是两回事，
#    前者其实已经完成 99%，只需要人点一下
PUSH_OK=0
if git push -q -f -u origin "$BRANCH" >>"$ERRLOG" 2>&1; then
  PUSH_OK=1
  log "分支已推送：$BRANCH"
else
  log "分支推送失败"
fi

# 4) 开 PR
PR_OK=0
if [ "$PUSH_OK" = "1" ]; then
  if gh pr create --base main --head "$BRANCH" \
      --title "chore: 追平 FFmpeg ${VER}" \
      --body-file pr-body.md >>"$ERRLOG" 2>&1; then
    PR_OK=1
  fi
fi

if [ "$PR_OK" = "1" ]; then
  log "PR 已创建：$BRANCH"
  summary "### 已自动开 PR：\`$VER\`（锚点全绿）"
  rm -f "$ERRLOG"
  exit 0
fi

# ------------------------------------------------------------------------------
# 情况四：分支推好了，但 PR 建不起来 —— 给一键链接，人只差一次点击
# ------------------------------------------------------------------------------
PRURL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/pull/new/${BRANCH}"

if [ "$PUSH_OK" = "1" ]; then
  log "分支已就绪，只差建 PR（仓库没开 Actions 创建 PR 的开关）"
  {
    printf '巡检发现 **FFmpeg %s**（当前锁定 **%s**），锚点验证全绿，\n' "$VER" "$CUR"
    printf '分支 `%s` **已经推好了**，只差一个 PR。\n\n' "$BRANCH"
    printf '### 点这里创建 PR\n\n'
    printf '**<%s>**\n\n' "$PRURL"
    printf '点进去 Create pull request → Merge 即可。merge 到 main 会自动触发四平台构建。\n\n'
    printf '### 为什么没自动开\n\n'
    printf '仓库没允许 Actions 创建 PR。`GET /actions/permissions/workflow` 当前返回\n'
    printf '`can_approve_pull_request_reviews: false`。这个开关 `permissions:` 里声明不了，只能改仓库设置：\n\n'
    printf '> Settings → Actions → General → Workflow permissions → 勾选\n'
    printf '> **Allow GitHub Actions to create and approve pull requests**\n\n'
    printf '勾上之后每周巡检就能全自动，不用再点这里了。\n\n'
    printf '### 失败输出\n\n```\n'
    tail -15 "$ERRLOG" 2>/dev/null || printf '（无输出）\n'
    printf '```\n'
    footer
  } >issue-body.md
  gh issue create --title "[上游巡检] FFmpeg ${VER} 分支已就绪，点一下开 PR" \
    --body-file issue-body.md
  summary "### 分支已推送：\`$BRANCH\`（需点一下开 PR）"
else
  log "分支推送失败"
  {
    printf '巡检发现 **FFmpeg %s**（当前锁定 **%s**），锚点验证全绿，\n' "$VER" "$CUR"
    printf '但**分支推送失败**了，仓库里什么都没改。\n\n'
    printf '### 失败输出\n\n```\n'
    tail -20 "$ERRLOG" 2>/dev/null || printf '（无输出）\n'
    printf '```\n\n'
    printf '### 手改（就一行）\n\n```diff\n'
    printf -- '--- a/scripts/env.sh\n+++ b/scripts/env.sh\n'
    printf -- '-FFMPEG_VERSION="${FFMPEG_VERSION:-%s}"\n' "$CUR"
    printf -- '+FFMPEG_VERSION="${FFMPEG_VERSION:-%s}"\n' "$VER"
    printf '```\n'
    footer
  } >issue-body.md
  gh issue create --title "[上游巡检] FFmpeg ${VER} 可升级，但分支推送失败" \
    --body-file issue-body.md
  summary "### 需要人工：\`$VER\` 分支推送失败"
fi

rm -f "$ERRLOG"
exit 0
