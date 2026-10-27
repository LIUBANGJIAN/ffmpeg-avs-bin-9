#!/usr/bin/env bash
# ==============================================================================
# Windows x86_64 —— MSYS2 UCRT64
#
# 用法（MSYS2 UCRT64 终端里）：
#   pacman -S --needed base-devel mingw-w64-ucrt-x86_64-toolchain \
#       mingw-w64-ucrt-x86_64-nasm mingw-w64-ucrt-x86_64-cmake \
#       mingw-w64-ucrt-x86_64-meson mingw-w64-ucrt-x86_64-ninja \
#       mingw-w64-ucrt-x86_64-pkgconf zip
#   ./scripts/build-windows.sh
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

export TARGET_OS=windows
export TARGET_ARCH=x86_64
export EXE=.exe

# ---------------- 工具链 ----------------
export PATH="${MINGW_PREFIX:-/ucrt64}/bin:/usr/bin:$PATH"
export CC=gcc
export CXX=g++
export AR=ar
export RANLIB=ranlib
export STRIP=strip
export NM=nm
export PKG_CONFIG=pkg-config

# -static 让 exe 不依赖 libgcc_s_seh-1.dll / libwinpthread-1.dll / libstdc++-6.dll，
# 这才是真正能拷走就用的单文件
#
# 后面四个 -Wno-* 是「老代码 x 新 GCC」的止血带，不是我们代码有问题：
#   GCC 14 把 -Wimplicit-function-declaration / -Wint-conversion /
#   -Wincompatible-pointer-types / -Wreturn-mismatch 从警告提升成了默认错误，
#   而 x264/lame/libvorbis/fontconfig 这些 2015~2018 年的代码大量踩中。
#   关掉诊断 = 回到 GCC 13 的行为，不改变任何生成代码。
export CFLAGS="-O2 -pipe -fno-ident \
  -Wno-incompatible-pointer-types -Wno-implicit-function-declaration \
  -Wno-int-conversion -Wno-return-mismatch"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-static -static-libgcc -static-libstdc++"
export EXTRA_CFLAGS="-D__USE_MINGW_ANSI_STDIO=1"

# C++ 运行库由 gcc 驱动时需要显式带；其余是 openssl/SDL2 静态链接要用到的 win32 系统库
export EXTRA_LIBS="-lstdc++ -lws2_32 -lcrypt32 -lbcrypt -lsecur32 -luserenv -lgdi32 -lwinmm -lole32 -loleaut32 -luuid -lshell32 -limm32 -lversion -lshlwapi -lpsapi"

# ---------------- 载入构建系统 ----------------
source "$ROOT/scripts/env.sh"
source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/patch-ffmpeg.sh"
source "$ROOT/scripts/libs/avs.sh"
source "$ROOT/scripts/libs/video.sh"
source "$ROOT/scripts/libs/audio.sh"
source "$ROOT/scripts/libs/misc.sh"
source "$ROOT/scripts/build-ffmpeg.sh"
source "$ROOT/scripts/build-common.sh"

# 所有依赖都自建在 $PREFIX 下，不在 MSYS2 的默认搜索路径里。
# 带 .pc 的库会自己带出 -L$PREFIX/lib，但**没有 .pc 的库**（lame 3.100 就是一个，
# 我们是在 audio.sh 里给它补了个 lame.pc，可 FFmpeg 对 libmp3lame 走的是
# 裸 check_lib 而不是 pkg-config）只有全局 ldflags 里的 -L 可依赖，
# 否则报 cannot find -lmp3lame → `ERROR: libmp3lame >= 3.98.3 not found`。
# android-arm64 上已经实测踩到（run#16），windows 同理先堵住。
# 必须放在 source lib.sh 之后：PREFIX 定义在那里，提前引用会触发 set -u。
export EXTRA_LDFLAGS="-L$PREFIX/lib"

# ---------------- 干活 ----------------
build_everything
smoke_test
package_output "ffmpeg-${FFMPEG_VERSION}-avs-win64-static"
