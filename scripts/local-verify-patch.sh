#!/usr/bin/env bash
# ==============================================================================
# 本地锚点验证 —— 不编译，只验证补丁能不能干净地打上去
#
# 用途：换 FFmpeg 版本（改 env.sh 里的 FFMPEG_VERSION）之后，先跑这个，
# 3 秒内告诉你 7 处锚点是否还匹配。比推 CI 等 50 分钟才发现锚点漂移划算得多。
#
# 用法：
#   ./scripts/local-verify-patch.sh /path/to/FFmpeg-n9.0.2
#   # 不给参数则自动下载当前 FFMPEG_VERSION 的源码到 work/ 下
#
# 退出码：0 全部命中；1 有锚点失配（会打印失配的文件与锚点）
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# shellcheck source=/dev/null
. "$ROOT/scripts/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/scripts/env.sh"
# shellcheck source=/dev/null
. "$ROOT/scripts/patch-ffmpeg.sh"

SRC="${1:-}"

if [ -z "$SRC" ]; then
  printf '未指定源码目录，按 FFMPEG_VERSION=%s 取一份\n' "$FFMPEG_VERSION"
  SRC="$ROOT/work/src-verify"
  if [ ! -d "$SRC" ]; then
    mkdir -p "$ROOT/work"
    command -v curl >/dev/null || { echo "需要 curl 来下载源码"; exit 1; }
    printf '下载 %s ...\n' "$FFMPEG_URL"
    curl -fsSL --retry 3 -m 300 -o "$ROOT/work/ffmpeg-verify.tar.gz" "$FFMPEG_URL" \
      || { echo "下载失败：$FFMPEG_URL"; exit 1; }
    mkdir -p "$SRC"
    tar xzf "$ROOT/work/ffmpeg-verify.tar.gz" -C "$SRC" --strip-components=1
  fi
fi

[ -d "$SRC" ] || { echo "源码目录不存在：$SRC"; exit 1; }

# 在临时副本上打，绝不动用户给的源码树
WD="$ROOT/work/verify-copy"
rm -rf "$WD"
mkdir -p "$WD"
cp -r "$SRC" "$WD/ff"

export BLD="$ROOT/work/verify-bld"
mkdir -p "$BLD"

printf '\n=================== 打补丁（FFmpeg %s）===================\n' "$FFMPEG_VERSION"
if ! apply_ffmpeg_avs3_patch "$WD/ff"; then
  printf '\n[X] 补丁失败 —— 上面那条 edit_exact 报的就是失配的锚点\n'
  exit 1
fi

# 打完后再确认关键片段真的就位（防止"替换成功但内容不对"）
printf '\n=================== 打完后的核对 ===================\n'
f="$WD/ff"
FAILED=0
check() {
  local desc="$1" file="$2" pat="$3" want="$4" n
  n=$(grep -c -- "$pat" "$file" 2>/dev/null || true)
  if [ "$n" = "$want" ]; then
    printf '  [OK]   %-40s (%s 次)\n' "$desc" "$n"
  else
    printf '  [FAIL] %-40s (期望 %s 次，实际 %s 次)\n' "$desc" "$want" "$n"
    FAILED=1
  fi
}

check "configure 帮助文本"    "$f/configure"              'enable-libuavs3e'                    1
check "configure 库清单"      "$f/configure"              '^    libuavs3e$'                     1
check "configure 编码器依赖"  "$f/configure"              'libuavs3e_encoder_deps="libuavs3e"'  1
check "configure pkg-config"  "$f/configure"              'enabled libuavs3e'                   1
check "Makefile 编译单元"     "$f/libavcodec/Makefile"    'CONFIG_LIBUAVS3E_ENCODER'            1
check "allcodecs extern"      "$f/libavcodec/allcodecs.c" 'ff_libuavs3e_encoder'                1
check "libuavs3e.c 已落地"    "$f/libavcodec/libuavs3e.c" 'ff_libuavs3e_encoder'               1
check "libdavs2.c 色彩表"     "$f/libavcodec/libdavs2.c"  'davs2_color_primaries_tab'           2
check "libdavs2.c 色彩赋值"   "$f/libavcodec/libdavs2.c"  'avctx->color_primaries = davs2'      1
# ⑧ 那条存在性检查：上游若改了 libuavs3d.c 的色彩搬运，这里会先发现
check "libuavs3d 色彩搬运"    "$f/libavcodec/libuavs3d.c" 'ff_avs3_color_primaries_tab'         1

rm -rf "$WD"
printf '\n'
if [ "$FAILED" = "0" ]; then
  echo "ALL_ANCHORS_OK"
  exit 0
else
  echo "SOME_ANCHOR_FAILED"
  exit 1
fi
