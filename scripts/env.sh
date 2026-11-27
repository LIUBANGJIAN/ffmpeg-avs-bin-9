#!/usr/bin/env bash
# ==============================================================================
# 版本锁 —— 所有外部依赖的版本集中在这里，升级只改这一个文件
#
# DEPS 每行格式：  name|kind|url_or_repo|ref
#   kind = tar | git
#   ref  = tar 忽略（留空）；git 填分支 / 标签 / commit
#
# 想单独覆盖某个版本又不想改文件：
#   FFMPEG_VERSION=9.0.2 ./scripts/build-linux.sh
# 想换跟随的主线（跨 major，需人工核对锚点）：
#   FFMPEG_SERIES=10 ./scripts/local-verify-patch.sh
# ==============================================================================

# ------------------------------------------------------------------
# FFmpeg 本体
#
# 这里有两个变量，职责严格分开，别混：
#
#   FFMPEG_SERIES   跟随哪条主线（当前 9.x）。**只有跨 major 才改这一行**，
#                   而跨 major 必须人工接入 —— 补丁锚点和封装代码都是按实际
#                   源码逐条核对过的，不能靠改版本号猜。
#
#   FFMPEG_VERSION  当前线上跑的那一版 = 上一次成功发布的那一版。
#                   ⚠️ 由 CI 自动维护，不是上限：
#                      build.yml 的 bump job 在「四平台全绿 + 发版成功」后
#                      会改写这一行并提交（带 [skip ci]）。
#                   每天 11:23（北京时间）巡检上游，出现新的 9.x 正式版就
#                   预验锚点 -> 四平台编译 -> 打 tag 发版 -> 回写这里。
#                   所以它回答的是「现在用的是哪一版」，不是「最多能到哪一版」。
# ------------------------------------------------------------------
FFMPEG_SERIES="${FFMPEG_SERIES:-9}"

# 为什么留一个字面量：本地构建 / 复现旧版 / 审计产物来源都需要一个确定值。
# 若这里留空，任何本地构建立刻都要联网问上游，构建变得不可复现。
#
# 与另一个仓库 ffmpeg-avs-bin-6 的 6.1.6 分开，本仓用来验证
# 「AVS 全家桶在 FFmpeg 9 上还能不能编出来」。
#
# AVS3 编码器 libuavs3e 至今仍未进入 FFmpeg 主线：9.1 的 EXTERNAL_LIBRARY_LIST
# 里只有 libdavs2 / libuavs3d / libxavs / libxavs2，没有任何 uavs3e 字样。
# 所以 5 处接线 + 1 个 libavcodec/libuavs3e.c 仍然要自己打。
#
# 9.0.2 → 9.1 这一版的核对记录（libavcodec MAJOR 保持 63，只升 MINOR 1→24，
# 按 FFmpeg 的规矩这意味着只加 API 不删 API）：
#   - 10 项锚点（configure 4 + Makefile 1 + allcodecs 1 + libdavs2 色彩 2 +
#     2 项存在性检查）在 n9.1 上全部精确匹配，零漂移
#   - patches/libuavs3e.c 无需改一行：CODEC_PIXFMTS / FF_CODEC_ENCODE_CB /
#     CODEC_LONG_NAME / FFCodecDefault / ff_alloc_packet 定义与 9.0.2 一致
#   - libdavs2.c / libuavs3d.c 在上游 9.0.2 → 9.1 之间**字节级完全相同**，
#     我们叠加的色彩补丁语义不受影响
#   - AMF 门槛仍是 0x1000500020000（MINOR>=5），现用的 1.5.2 继续够用
#   - libvpl 仍要求 vpl >= 2.6，无需升级
#   - drawvg / cairo 仍在（drawvg_filter_deps="cairo"），9 仓独有能力保住
#
# 已实编验证：9.1 在 CI 上四平台全绿（windows / linux / android-armv7 / arm64）。
#
# 想临时回到旧版（不用改文件）：
#   FFMPEG_VERSION=9.0.2 ./scripts/build-linux.sh
FFMPEG_VERSION="${FFMPEG_VERSION:-9.1}"

# 一致性护栏：版本必须落在声明的主线上。防的是「手改成 10.0 但 SERIES 还写 9」
# 这种半升级状态 —— 让它在这里就红，而不是打到第 3 个锚点才炸。
if [ "${FFMPEG_VERSION%%.*}" != "$FFMPEG_SERIES" ]; then
  echo "[env.sh] FFMPEG_VERSION=$FFMPEG_VERSION 与 FFMPEG_SERIES=$FFMPEG_SERIES 不一致" >&2
  echo "[env.sh] 跨 major 需人工接入：先核对锚点，再同时改这两行" >&2
  exit 1
fi
FFMPEG_TAG="n${FFMPEG_VERSION}"
FFMPEG_URL="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${FFMPEG_TAG}.tar.gz"

# ------------------------------------------------------------------
# 许可证
# ------------------------------------------------------------------
# GPL v2（不带 nonfree）：
#   x264 / x265 / xavs2 / davs2 都是 GPL v2，不 --enable-gpl 就用不了。
#   fdk-aac 的许可与 GPL 不兼容，必须 --enable-nonfree 才能编，
#   而 nonfree 产物不可再分发 —— 所以这里不引入 fdk-aac，AAC 用 FFmpeg 自带编码器。
LICENSE_GPL="${LICENSE_GPL:-1}"

# ------------------------------------------------------------------
# 依赖清单
# ------------------------------------------------------------------
# shellcheck disable=SC2034
DEPS=(
  # ========== FFmpeg 本体 ==========
  "ffmpeg|tar|${FFMPEG_URL}|"

  # ========== AVS 家族（本项目核心） ==========
  # davs2 上游（pkuvcl）是「编译期单一位深」，build/linux/configure 里
  #   --bit-depth=9 或 10  ->  echo "not supported currently"; exit 1
  # xatabhk/davs2-10bit 把源码改成了 10bit 可用（补了 x86 的 10bit SSE/AVX 例程），
  # 但没改 build/linux/configure —— 所以 avs.sh 里用 edit_exact 放开那个限制。
  # ARM 平台没有 10bit 汇编（整个仓库 source/common 下只有 x86 和 vec），走纯 C：
  # 结果正确，只是没有 SIMD 加速，慢 3~5 倍。
  "davs2|git|https://github.com/xatabhk/davs2-10bit.git|master"
  # xavs2 只有 8bit 编码能力，这是上游硬限制，不是我们的选择
  "xavs2|tar|https://github.com/pkuvcl/xavs2/archive/refs/tags/1.4.tar.gz|"
  "uavs3d|git|https://github.com/uavs3/uavs3d.git|v1.1"
  # AVS3 编码器。三个必改点（见 scripts/libs/avs.sh）：
  #   1) cmake_minimum_required(VERSION 2.8) —— CMake 4.x 移除 <3.5 兼容，直接报错
  #   2) src/CMakeLists.txt 的 else() 会给 ARM 拉 x86 sse/avx2 源文件
  #   3) inc/com_api.h 用 #if defined(__linux__) 门控 10bit，MinGW 上把
  #      COMPILE_10BIT 强制归零 —— Windows 不打这个补丁就只有 8bit
  "uavs3e|git|https://github.com/uavs3/uavs3e.git|master"

  # ========== 视频编码 / 解码 ==========
  "x264|git|https://code.videolan.org/videolan/x264.git|stable"
  "x265|tar|https://github.com/videolan/x265/archive/refs/tags/3.4.tar.gz|"
  "dav1d|tar|https://github.com/videolan/dav1d/archive/refs/tags/1.5.4.tar.gz|"
  "libvpx|tar|https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.0.tar.gz|"

  # ========== 音频 ==========
  "lame|tar|https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz|"
  # xiph 官方站从国内常常极慢；用 GitHub 归档 + autoreconf（lib.sh 自动处理）
  "ogg|tar|https://github.com/xiph/ogg/archive/refs/tags/v1.3.5.tar.gz|"
  "vorbis|tar|https://github.com/xiph/vorbis/archive/refs/tags/v1.3.7.tar.gz|"
  "opus|tar|https://github.com/xiph/opus/archive/refs/tags/v1.5.2.tar.gz|"

  # ========== 基础 / 字幕 / 网络 ==========
  "zlib|tar|https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz|"
  "freetype|tar|https://github.com/freetype/freetype/archive/refs/tags/VER-2-13-3.tar.gz|"
  "fribidi|tar|https://github.com/fribidi/fribidi/releases/download/v1.0.15/fribidi-1.0.15.tar.xz|"
  "harfbuzz|tar|https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz|"
  "libass|tar|https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz|"
  "zimg|tar|https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.5.tar.gz|"
  "srt|tar|https://github.com/Haivision/srt/archive/refs/tags/v1.5.4.tar.gz|"
  "openssl|tar|https://github.com/openssl/openssl/releases/download/openssl-3.0.15/openssl-3.0.15.tar.gz|"
  # libass 在非 Windows 平台必须有字体提供者，fontconfig 依赖 expat
  "expat|tar|https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.gz|"
  # fontconfig 的 GitHub Releases 没有资产（只有 tag），必须走官方发行目录；
  # 这个 tarball 自带 configure，正好省掉 autoreconf
  "fontconfig|tar|https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.14.2.tar.xz|"

  # cairo：唯一用途是 FFmpeg 的 drawvg 滤镜（drawvg_filter_deps="cairo"）。
  # 走 cairographics 官方发行目录 —— freedesktop 的 GitLab 没有 GitHub release 资产，
  # download.gnome.org 上也没有 cairo。
  # 只需要 pixman 一个传递依赖，见下面那条（显式装，不走 meson wrap）。
  # 其余后端全部显式关掉，避免拖进 glib/gtk/fontconfig 一整条 GNOME 链。
  # pixman：cairo 的必需依赖（cairo 要求 >= 0.42.3）。
  # 为什么不依赖 cairo 自带的 meson subproject wrap：那会在 build 时联网拉
  # pixman-0.44.2.tar.gz（wrap 里写死了版本和 hash），CI 上多一个网络单点，
  # 而且版本被锁在旧版。这里显式装 0.46.4 到 prefix，meson 会优先用已安装的。
  "pixman|tar|https://cairographics.org/releases/pixman-0.46.4.tar.xz|"
  "cairo|tar|https://cairographics.org/releases/cairo-1.18.6.tar.xz|"

  # ========== Windows 专属 ==========
  # 硬件编码器头文件：只要头文件，不需要 CUDA / 运行库
  "nvcodec|tar|https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/n12.2.72.0.tar.gz|"
  # AMF 1.4.33 太旧：FFmpeg 9.0 的 configure 里写死了
  #   (AMF_VERSION_MAJOR << 48 | MINOR << 32 | RELEASE << 16 | BUILD) >= 0x1000500020000
  # 即要求 MINOR >= 5。1.4.33 是 0x1000400210000，不达标 ⇒ amf 被静默 disable，
  # 随后 "ERROR: amf requested but not found"。
  # 1.5.2 算出正好 0x1000500020000，卡在下限上。
  "amf|tar|https://github.com/GPUOpen-LibrariesAndSDKs/AMF/archive/refs/tags/v1.5.2.tar.gz|"
  "libvpl|tar|https://github.com/intel/libvpl/archive/refs/tags/v2.13.0.tar.gz|"
  # ffplay 需要 SDL2
  "sdl2|tar|https://github.com/libsdl-org/SDL/archive/refs/tags/release-2.30.9.tar.gz|"

  # ========== 可选（默认关，用 ENABLE_xxx=1 打开） ==========
  "svtav1|tar|https://github.com/AOMediaCodec/SVT-AV1/archive/refs/tags/v2.3.0.tar.gz|"
  # aom 走 git：googlesource 的 +archive 包没有单一顶层目录，tar 解包不便。
  # 官方源在中国大陆经常不可达（本机实测 curl 失败），但 GitHub runner 是境外节点，
  # 正常可达。它是可选库（默认关），真编不过就保持关闭，不影响 AVS 能力。
  "aom|git|https://aomedia.googlesource.com/aom|v3.10.0"
  "webp|tar|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0.tar.gz|"
)

# ------------------------------------------------------------------
# 可选库开关（默认全关）
# ------------------------------------------------------------------
ENABLE_SVTAV1="${ENABLE_SVTAV1:-0}"
ENABLE_AOM="${ENABLE_AOM:-0}"
ENABLE_WEBP="${ENABLE_WEBP:-0}"

# ------------------------------------------------------------------
# 平台裁剪：某些依赖只在特定平台有意义
# ------------------------------------------------------------------
# 这些库只在 Windows 编（Linux/Android 上编了也用不到，白等）
WINDOWS_ONLY_DEPS="nvcodec amf libvpl sdl2"

# 判定某个依赖是否要装：libs_needed <name>
dep_needed() {
  local n="$1"
  case " $WINDOWS_ONLY_DEPS " in
    *" $n "*) [ "${TARGET_OS:-}" = "windows" ] || return 1 ;;
  esac
  case "$n" in
    svtav1) [ "$ENABLE_SVTAV1" = "1" ] || return 1 ;;
    aom)    [ "$ENABLE_AOM"    = "1" ] || return 1 ;;
    webp)   [ "$ENABLE_WEBP"   = "1" ] || return 1 ;;
  esac
  return 0
}
