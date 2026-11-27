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
echo "| 平台 | 文件 | 说明 |"
echo "|---|---|---|"
for f in artifacts/*.zip; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  case "$b" in
    *win64*)   note="Windows x86_64，MSYS2 UCRT64 构建" ;;
    *linux64*) note="Linux x86_64，musl 全静态，无 glibc 依赖" ;;
    *armv7*)   note="Android armeabi-v7a，最低 API 19（4.4 KitKat）" ;;
    *arm64*)   note="Android arm64-v8a，最低 API 21（5.0）" ;;
    *)         note="" ;;
  esac
  echo "| ${b%%.zip} | \`${b}\` | ${note} |"
done
echo
echo "\`SHA256SUMS.txt\` 为全部产物的 SHA-256 校验和。"
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

### 下载加速

GitHub Release 直连不畅时，在链接前加 `https://gh-proxy.com/` 前缀：

```
https://gh-proxy.com/https://github.com/LIUBANGJIAN/ffmpeg-avs-bin-9/releases/download/TAG/文件名
```
EOF
