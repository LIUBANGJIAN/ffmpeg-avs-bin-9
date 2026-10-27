#!/usr/bin/env bash
# ==============================================================================
# Android —— NDK r25c，单文件可执行 ffmpeg
#
# 叫「单文件」而不是「全静态」，是因为 Android 的 libc 是 bionic：
#   - 可以把除 libc 以外的所有东西静态链进去（x264/x265/AVS 全套/openssl…）
#   - 但绝不能把 bionic 静态链进去（Android 上静态 bionic 会丢 TLS/atfork，
#     运行时随机崩，官方也不支持）
#   所以产物是「一个二进制 + 依赖系统自带的 libc/libm/libdl」，
#   在 4.4 及以上任何一台机器上都能直接跑，无需 root（放 /data/local/tmp 即可执行）。
#
# API level 为什么这么定：
#   - armv7 -> API 19：NDK r26 起官方不再支持 KitKat，最后一个支持 4.4.2 的是 r25c
#   - arm64 -> API 21：Android 5.0 才开始有 64 位
#
# 用法：
#   ANDROID_NDK_HOME=/opt/ndk/25.2.9519653 ./scripts/build-android.sh armv7
#   ANDROID_NDK_HOME=/opt/ndk/25.2.9519653 ./scripts/build-android.sh arm64
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

ABI_IN="${1:-${ABI_IN:-armv7}}"
: "${ANDROID_NDK_HOME:?必须指定 ANDROID_NDK_HOME（NDK r25c）}"

case "$ABI_IN" in
  armv7|armeabi-v7a)
    export ANDROID_ABI="armeabi-v7a"
    export ANDROID_API="${ANDROID_API:-19}"
    export TARGET_ARCH="arm"
    export HOST="arm-linux-androideabi"
    CLANG_TRIPLE="armv7a-linux-androideabi"
    FF_ARCH="arm"
    FF_CPU="armv7-a"
    MESON_CPU_FAMILY="arm"
    MESON_CPU="armv7-a"
    PKG_ABI_NAME="armv7"
    ;;
  arm64|arm64-v8a|aarch64)
    export ANDROID_ABI="arm64-v8a"
    export ANDROID_API="${ANDROID_API:-21}"
    export TARGET_ARCH="aarch64"
    export HOST="aarch64-linux-android"
    CLANG_TRIPLE="aarch64-linux-android"
    FF_ARCH="aarch64"
    FF_CPU="armv8-a"
    MESON_CPU_FAMILY="aarch64"
    MESON_CPU="armv8-a"
    PKG_ABI_NAME="arm64"
    ;;
  *) echo "未知 ABI: $ABI_IN（可用 armv7 / arm64）" >&2; exit 1 ;;
esac

export TARGET_OS=android
export EXE=

TC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
if [ ! -d "$TC" ]; then
  echo "找不到 NDK 工具链：$TC" >&2
  echo "确认 ANDROID_NDK_HOME 指向 NDK 根目录（不是 toolchains 目录）" >&2
  exit 1
fi

# openssl 3.x 的 Configurations/15-android.conf 只认 ANDROID_NDK_ROOT / ANDROID_NDK，
# 而且必须靠 `which clang` 解析出 $ndk/.../prebuilt/.../clang，才会走 NDK clang 分支。
# GitHub 的 ubuntu runner 预装了别的 NDK 并已设好 ANDROID_NDK_ROOT，不覆盖的话
# openssl 会去 r25c 里找早已被移除的 arm-linux-androideabi-gcc，报
#   "no NDK arm-linux-androideabi-gcc on $PATH"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export ANDROID_NDK="$ANDROID_NDK_HOME"
case ":$PATH:" in
  *":$TC/bin:"*) ;;
  *) export PATH="$TC/bin:$PATH" ;;
esac

export CC="$TC/bin/${CLANG_TRIPLE}${ANDROID_API}-clang"
export CXX="$TC/bin/${CLANG_TRIPLE}${ANDROID_API}-clang++"
export AR="$TC/bin/llvm-ar"
export RANLIB="$TC/bin/llvm-ranlib"
export STRIP="$TC/bin/llvm-strip"
export NM="$TC/bin/llvm-nm"
[ -x "$CC" ] || { echo "编译器不存在：$CC" >&2; exit 1; }

export CFLAGS="-O2 -fPIC -D__ANDROID_API__=${ANDROID_API}"
export CXXFLAGS="$CFLAGS"
export LDFLAGS=""
# davs2 / xavs2 / zimg 是 C++，用 clang 驱动链接时必须显式带 NDK 的静态 C++ 运行库。
# `-lm` 也必须在：与 glibc/musl/mingw 不同，bionic 的 libm 是**独立库**，
# `sin/cos/modf/expf/powf/logf/log10f/nextafter` 不会从 libc 解析出来。
# 而 zimg 上游的 zimg.pc.in 是 `Libs.private: @STL_LIBS@`，**从来不写 -lm**
# （glibc/musl 下靠 libc 或 libstdc++ 就能过，所以 linux/windows 一直没事），
# 于是 android 上 configure 检查 zimg 时满屏
#   ld: error: undefined symbol: modf / nextafter / expf / sin / cos
# 折叠成一句 `ERROR: zimg >= 2.7.0 not found using pkg-config`（run#20）。
export EXTRA_LIBS="-lc++_static -lc++abi -lm"

# 防止跨平台污染：ubuntu runner 上装了 libssl-dev/zlib1g-dev 时，
# pkg-config 会找到 **x86 主机版** .pc，然后把 x86 的库链进 ARM 产物。
# 限定 LIBDIR 是唯一可靠的做法（只改 PATH 不够）。真正的值在 source lib.sh 后设置。
unset PKG_CONFIG_PATH || true

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

# lib.sh 定义了 PREFIX，现在才能设 pkg-config 搜索路径
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# 交叉编译时**所有**依赖都装在我们自己的前缀里，没有任何一个在 toolchain 的
# 默认搜索路径中。带 .pc 的库（davs2/xavs2/uavs3d/uavs3e/x264/...）会把
# -L$PREFIX/lib 一起带出来，所以它们没事；但**没有 .pc 的库**（最典型是
# libmp3lame，lame 3.100 根本不装 .pc）走的是 FFmpeg configure 里的
#   check_lib libmp3lame lame/lame.h lame_set_VBR_quality -lmp3lame -lm
# 这条路径只用 configure 的全局 cflags/ldflags，于是链接行是
#   clang ... -o test test.o -lmp3lame -lm -lc++_static -lc++abi
# 一个 -L 都没有 →  ld: error: unable to find library -lmp3lame
#     →  ERROR: libmp3lame >= 3.98.3 not found   （run#16 android-arm64）
# 头文件能编过是因为 -I 早被前面几次 pkg-config 检测攒进 cflags 了，
# 所以只有链接这一半会炸，现象很误导。
# 注意 --extra-ldflags 是加进 $ldflags 的，configure 的测试链接和最终链接
# 都会带上，两边都需要它。
export EXTRA_LDFLAGS="-L$PREFIX/lib"
export EXTRA_CFLAGS="-I$PREFIX/include"

# ---------------- API < 21 的 libc++ locale 垫片 ----------------
# NDK r25c 里的 libc++_static.a 是**面向 API 21 编的**：它的 locale.o 直接
# 引用 bionic 直到 21 才提供的那批 locale 函数。于是 armv7（API 19）在
# FFmpeg configure 的第一次 C++ 链接就炸（run#22）：
#   ld: error: undefined symbol: mbsnrtowcs
#   >>> referenced by __bsd_locale_fallbacks.h:67
#   >>>      locale.o:(__libcpp_mbsnrtowcs_l(...)) in archive libc++_static.a
#   ... 还有 mbtowc / localeconv / strtoll_l / strtoull_l / strtold_l /
#       wcstoll / wcstoull / wcstof，一共 9 个
# 同一份代码 arm64（API 21）一把过，可见与我们自己的代码无关，是「静态
# C++ 运行库在 API 19 上不可用」这个既定事实。
# 解法：给这 9 个符号补一份最小实现（scripts/android-api19-compat/），
# 编成静态库挂到 --extra-libs 的**最后**（必须在 -lc++_static 之后，
# 否则 locale.o 里的未定义引用还没出现，没人去拉它）。
if [ "${ANDROID_API:-21}" -lt 21 ]; then
  API19_COMPAT_DIR="$WORK/api19compat"
  mkdir -p "$API19_COMPAT_DIR"
  log "android: API $ANDROID_API < 21，编 libc++ locale 垫片（9 个符号）"
  # 不再额外传 -D__ANDROID_API__：版本化的 wrapper（…androideabi19-clang）
  # 已经通过 -target 定义了它，重复定义只会多一条 macro redefined 警告。
  "$CC" -c -O2 -fPIC -o "$API19_COMPAT_DIR/api19_compat.o" \
    "$ROOT/scripts/android-api19-compat/api19_compat.c" \
    || die "API19 兼容垫片编译失败"
  "$AR" rcs "$API19_COMPAT_DIR/libapi19compat.a" "$API19_COMPAT_DIR/api19_compat.o" \
    || die "API19 兼容垫片打包失败"
  export EXTRA_LIBS="$EXTRA_LIBS -L$API19_COMPAT_DIR -lapi19compat"
  ok "android: 垫片就绪 → $API19_COMPAT_DIR/libapi19compat.a"
fi

# meson 没有 --host 那套，跨平台必须给 cross file
export MESON_CROSS_FILE="$WORK/meson-${PKG_ABI_NAME}.ini"

# ---- harfbuzz 在 API<21 上会引用 bionic 21 才有的 locale 函数 ----
# harfbuzz 10.x 的 hb.hh 里有这么一段：
#   #if !defined(HB_NO_SETLOCALE) && (!defined(HAVE_NEWLOCALE) || !defined(HAVE_USELOCALE))
#   #define HB_NO_SETLOCALE 1
#   #endif
#   #ifndef HB_NO_SETLOCALE
#     #define hb_locale_t locale_t
#     #define hb_uselocale uselocale
#   #else
#     #define hb_locale_t void *
#     #define hb_uselocale(Locale) ((hb_locale_t) 0)   <-- 连参数都不展开
#   #endif
# 也就是说只要 HAVE_NEWLOCALE + HAVE_USELOCALE 都被探测到，它就会去调
# newlocale/freelocale/uselocale，而这三个是 bionic API 21 才有的符号。
# 坑在于 meson 的 has_function 探测能过（它链接时用的是通用 stub），
# 真正按 API19 链接时才炸：
#   ld: error: undefined symbol: newlocale / freelocale / uselocale
#   ERROR: harfbuzz not found using pkg-config     （run#17 android-armv7）
# 官方开关 HB_NO_SETLOCALE 正好关掉这块；注意上面的宏定义是**不展开参数**的，
# 所以 hb-common.cc 里 get_C_locale() 消失也不会影响编译。
# 只对 API<21 打开 —— 21 及以上没有任何理由牺牲 locale 行为。
MESON_API19_EXTRA=""
if [ "$ANDROID_API" -lt 21 ]; then
  MESON_API19_EXTRA=", '-DHB_NO_SETLOCALE'"
fi

cat > "$MESON_CROSS_FILE" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkgconfig = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'

[properties]
needs_exe_wrapper = true
# 这里**故意不设 sys_root**。设了之后 meson 会把 pkg-config 输出里的绝对
# include 路径当作「目标机路径」，在前面再拼一次 sys_root，得到
#   -I/opt/ndk.../sysroot/home/runner/work/.../prefix/include/freetype2
# 于是 harfbuzz 编到 hb-ft.cc 就 'ft2build.h' file not found（run#9 android）。
# NDK 的 clang wrapper（aarch64-linux-android21-clang）自带 sysroot，
# 根本不需要 meson 再补；设了纯属帮倒忙。

# 交叉编译时 meson 会忽略环境里的 CFLAGS，必须在这里显式给，
# 否则 -fPIC / -D__ANDROID_API__ 全丢，dav1d 这类库会按 host 默认值编。
[built-in options]
c_args = ['-O2', '-fPIC', '-D__ANDROID_API__=$ANDROID_API'$MESON_API19_EXTRA]
c_link_args = ['-D__ANDROID_API__=$ANDROID_API']
cpp_args = ['-O2', '-fPIC', '-D__ANDROID_API__=$ANDROID_API'$MESON_API19_EXTRA]
cpp_link_args = ['-D__ANDROID_API__=$ANDROID_API']
EOF

# cmake 必须显式给 NDK 的 toolchain 文件。
# 只传 -DANDROID_ABI 而不给 toolchain 时 cmake 不会进入交叉编译模式，
# 结果是**按 host 编出 x86_64 的 .a**，直到链接 ffmpeg 才报架构不匹配，
# 错误信息离真正原因很远，所以必须在这里堵住。
export CMAKE_TOOLCHAIN="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
export ANDROID_PLATFORM="android-${ANDROID_API}"
[ -f "$CMAKE_TOOLCHAIN" ] || { echo "找不到 NDK cmake toolchain：$CMAKE_TOOLCHAIN" >&2; exit 1; }

# libvpx 的 configure 需要 NDK 根目录（它自己会去找 sysroot / 工具链规则）
export ANDROID_NDK_HOME

# ---------------- FFmpeg 专属参数 ----------------
# 注意是**字符串**而不是数组：bash 无法导出数组，build-ffmpeg.sh 按空格拆
#
# 为什么必须显式给 --cc / --cxx / --ar / --nm / --ranlib / --strip：
# FFmpeg 的 configure **不读 CC 环境变量**，而且对 android 还有一段硬编码
#   if test "$target_os" = android; then cc_default="clang"; fi
# 于是它拿 PATH 里那个**没有 -target**的裸 clang 去编：
#   clang --sysroot=... -march=armv8-a -c ...  →  error: unknown target CPU 'armv8-a'
# 因为裸 clang 默认按宿主机 x86_64 出活，-march=armv8-a 对 x86_64 是非法值。
# 就算侥幸过了这一关，编出来的也会是 x86_64 目标文件，直到最后链接才发现。
# 显式把 NDK 的 wrapper 传进去，target 才真的是 aarch64/armv7-linux-androidNN。
FF_EXTRA_ARGS="--target-os=android --arch=${FF_ARCH} --cpu=${FF_CPU} --enable-cross-compile --sysroot=${TC}/sysroot"
FF_EXTRA_ARGS+=" --cc=${CC} --cxx=${CXX} --ar=${AR} --nm=${NM} --ranlib=${RANLIB} --strip=${STRIP}"
# API 19 的 bionic 没有 iconv，留着会让 configure 探测出一堆假阳性
if [ "$ANDROID_API" -lt 21 ]; then
  FF_EXTRA_ARGS+=" --disable-iconv"
fi
export FF_EXTRA_ARGS

# ---------------- 干活 ----------------
build_everything

# 交叉编译出的 ARM 二进制无法在 x86 runner 上执行，
# 所以这里做「结构验证」而不是「运行验证」：ELF 架构、动态依赖、AVS 符号都在
verify_cross_binary "$PREFIX/bin/ffmpeg" "$TARGET_ARCH"

package_output "ffmpeg-${FFMPEG_VERSION}-avs-android-${PKG_ABI_NAME}-api${ANDROID_API}"
