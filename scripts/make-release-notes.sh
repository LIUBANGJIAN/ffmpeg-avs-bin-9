#!/usr/bin/env bash
# ==============================================================================
# 生成 Release 正文 / tag 附注
#
# 为什么需要它：
#   以前 workflow 里只有 `generate_release_notes: true`，GitHub 会用自动生成的
#   「What's Changed」**整个覆盖** tag 附注消息 —— 实测 v9.0.2-avs.2 的 tag 里
#   写了完整的升级说明，Release 页面上一个字都没出现。
#   现在把正文写成文件传给 action（body_path），自动生成的 notes 会追加在后面，
#   两者都在。
#
# 调用方（.github/workflows/build.yml 的 release job）通过环境变量传入：
#   TAG        本次 tag 名，如 v9.1-avs.2
#   VER        本次 FFmpeg 版本，如 9.1
#   TRIGGER    触发方式说明，如「推 main 后自动发布」
#   RUN_URL    本次构建链接
#   BUMP_FROM  从哪个版本升上来的（schedule 自动升级时才有值，否则为空）
#
# 输出：markdown 到 stdout
# ==============================================================================
set -uo pipefail

TAG="${TAG:?TAG 未设置}"
VER="${VER:?VER 未设置}"
TRIGGER="${TRIGGER:-手动触发}"
RUN_URL="${RUN_URL:-}"
BUMP_FROM="${BUMP_FROM:-}"
# 产物链接要用完整仓库路径。CI 里直接用 github.repository，本地跑给个默认值。
REPO_SLUG="${GITHUB_REPOSITORY:-LIUBANGJIAN/ffmpeg-avs-bin-9}"
DL_BASE="https://github.com/${REPO_SLUG}/releases/download/${TAG}"
FAST_BASE="https://gh-proxy.com/${DL_BASE}"

# 上一个 tag：排除当前这个。creatordate 只对附注 tag 有效，
# 本仓库的正式包全是 `git tag -a` 打的，所以可用。
PREV=$(git tag --sort=-creatordate 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+' | grep -vxF "$TAG" | head -1 || true)

echo "## FFmpeg ${VER} + AVS2/AVS3 完整编解码"
echo
echo "| 项 | 值 |"
echo "|---|---|"
echo "| FFmpeg | **${VER}** |"
echo "| 触发方式 | ${TRIGGER} |"
if [ -n "$BUMP_FROM" ]; then
  echo "| 版本变更 | \`${BUMP_FROM}\` → \`${VER}\`（上游巡检自动追平） |"
fi
if [ -n "$PREV" ]; then
  echo "| 上一个版本 | \`${PREV}\` |"
fi
if [ -n "$RUN_URL" ]; then
  echo "| 构建记录 | [run](${RUN_URL}) |"
fi
echo

# ------------------------------------------------------------------------------
# 变更
# ------------------------------------------------------------------------------
echo "### 变更"
echo
if [ -n "$PREV" ]; then
  LOG=$(git log --no-merges --format='- %s（`%h`）' "${PREV}..HEAD" 2>/dev/null | head -30 || true)
  if [ -n "$LOG" ]; then
    echo "$LOG"
  else
    echo "- 无代码变更（版本号或构建配置调整）"
  fi
else
  echo "- 首次发布，无历史可比"
fi
echo

# ------------------------------------------------------------------------------
# 产物
# ------------------------------------------------------------------------------
echo "### 产物"
echo
echo "| 平台 | 文件 | 大小 | 下载 | 说明 |"
echo "|---|---|---|---|---|"
for f in artifacts/*.zip; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  case "$b" in
    *win64*)   plat="Windows x86_64"    ; note="MSYS2 UCRT64 构建，全静态" ;;
    *linux64*) plat="Linux x86_64"      ; note="musl 全静态，无 glibc 依赖" ;;
    *armv7*)   plat="Android armv7"     ; note="armeabi-v7a，最低 API 19（4.4 KitKat）" ;;
    *arm64*)   plat="Android arm64"     ; note="arm64-v8a，最低 API 21（5.0）" ;;
    *)         plat="${b%%.zip}"        ; note="" ;;
  esac
  # wc -c 而不是 du -h：du 受块大小与稀疏文件影响，不同平台会四舍五入出不同结果
  sz=$(awk -v b="$(wc -c <"$f")" 'BEGIN{printf "%.1f MiB", b/1048576}')
  # 链接直接给死：填 TAG 和真实文件名，读者点一下就能下，不用自己拼
  echo "| ${plat} | \`${b}\` | ${sz} | [下载](${FAST_BASE}/${b}) | ${note} |"
done
echo
echo "\`SHA256SUMS.txt\` 为全部产物的 SHA-256 校验和：[下载](${FAST_BASE}/SHA256SUMS.txt)"
echo

# ------------------------------------------------------------------------------
# 能力与边界
# ------------------------------------------------------------------------------
cat <<'EOF'
### 能力

- **解码**：AVS2（libdavs2）、AVS3（libuavs3d）、H.264 / HEVC / AV1 等 FFmpeg 原生格式
- **编码**：AVS3（libuavs3e，自带封装补丁）、AVS2（libxavs2）、AVS(1)（libxavs / libxavs2）
- **硬件编码**：NVENC / QSV(oneVPL) / AMF
- **滤镜**：drawvg（cairo / pixman）
- **AVS2 色彩信令**：从序列显示扩展（`0xB5` + `extension_start_code_identifier == 2`）解析
  `colour_description`，不再一律当 BT.709 处理

所有依赖静态链入，产物不依赖系统里的 libx264 / libx265 / openssl。

### 已知边界

- **Android 包未在真机 4.4.2 上验证过**。CI 只做结构验证（架构、依赖白名单、AVS 符号、体积），
  x86 runner 跑不了 ARM 二进制。
- 只出 armv7 / arm64，**没有 x86 / x86_64 安卓包**。
- Linux 产物是 musl 静态，Alpine / Debian / CentOS 都能直接跑，但**不能用系统 glibc 的 dlopen 插件**。

EOF

# ------------------------------------------------------------------------------
# 下载加速 —— 给完整可点的链接，不留 TAG / 文件名占位符
# ------------------------------------------------------------------------------
echo "### 下载加速"
echo
echo "上面每个「下载」已经走 \`gh-proxy.com\` 镜像。想用直连，去掉前缀即可，指向同一个文件："
echo
echo "- 加速：${FAST_BASE}/ffmpeg-${VER}-avs-win64-static.zip"
echo "- 直连：${DL_BASE}/ffmpeg-${VER}-avs-win64-static.zip"
echo
echo "命令行批量下 + 校验："
echo
echo '```bash'
echo "for f in \\
  ffmpeg-${VER}-avs-win64-static.zip \\
  ffmpeg-${VER}-avs-linux64-static.zip \\
  ffmpeg-${VER}-avs-android-armv7-api19.zip \\
  ffmpeg-${VER}-avs-android-arm64-api21.zip \\
  SHA256SUMS.txt; do"
echo "  curl -LO --retry 3 \"https://gh-proxy.com/https://github.com/${REPO_SLUG}/releases/download/${TAG}/\$f\""
echo "done"
echo "sha256sum -c SHA256SUMS.txt      # macOS: shasum -a 256 -c"
echo '```'
echo
echo "> 镜像只搬运字节、不做校验。校验和一定从这个 Release 取，别信第三方页面自己列的。"
