#!/usr/bin/env bash
# ==============================================================================
# 基础 / 字幕 / 网络依赖
#   zlib / openssl / expat / fontconfig / freetype / fribidi / harfbuzz
#   libass / zimg / srt / sdl2(Windows)
#
# 字幕这条链是有顺序的，不能乱：
#   freetype ─┬─> fontconfig ─┐
#   expat ────┘               ├─> libass
#   fribidi ──────────────────┤
#   harfbuzz(freetype) ───────┘
# libass 的字体提供者二选一：Windows 用 directwrite（零额外依赖），
# 其他平台必须 fontconfig，否则 configure 直接报「no font provider」。
# ==============================================================================

# ------------------------------------------------------------------------------
# zlib —— 压缩（mkv/png/字幕都靠它）
# zlib 的 configure 既不认 --host 也不认 --enable-static，必须走 custom_configure
# ------------------------------------------------------------------------------
build_zlib() {
  dep_needed zlib || return 0
  local dir; dir="$(fetch zlib)"

  # --static 必须加。Linux 那条线为了 musl 全静态产物给 LDFLAGS 塞了 -static，
  # 而 zlib 默认同时产出 libz.so，ld 在 -static 下建共享库会直接报
  #   relocation R_X86_64_32 against hidden symbol `__TMC_END__'
  #   can not be used when making a shared object
  # 我们只需要 libz.a，所以只建静态库，从根上避开这个组合。
  custom_configure "$dir" zlib configure "--prefix=$PREFIX" --static

  # zlib 的 .pc 依赖安装方式，缺了就自己补一个，
  # 否则 FFmpeg 的 --enable-zlib 会静默失效（configure 不报错，能力直接没有）。
  if ! pkg-config --exists zlib 2>/dev/null; then
    gen_pc zlib 1.3.1 "zlib compression library" "-lz"
  fi
  require_pc zlib
}

# ------------------------------------------------------------------------------
# openssl —— TLS（https / rtmps / srt 都依赖）
#
# 选 openssl 而不是 gnutls：musl 全静态下 gnutls 要拖 nettle + gmp + libidn2
# 一长串，失败面大；openssl 静态链接在 musl 上表现稳定。
# ------------------------------------------------------------------------------
openssl_target() {
  case "${TARGET_OS:-linux}/${TARGET_ARCH:-x86_64}" in
    windows/x86_64)              echo "mingw64" ;;
    linux/x86_64)                echo "linux-x86_64" ;;
    android/arm|android/armv7*)  echo "android-arm" ;;
    android/aarch64)             echo "android-arm64" ;;
    *) die "openssl: 未支持的 target ${TARGET_OS:-?}/${TARGET_ARCH:-?}" ;;
  esac
}

build_openssl() {
  dep_needed openssl || return 0
  local dir; dir="$(fetch openssl)"

  local args=(
    "--prefix=$PREFIX"
    # 必须显式 --libdir=lib。openssl 3.x 在 linux-x86_64 上默认装到
    # $PREFIX/lib64/pkgconfig，而我们的 PKG_CONFIG_PATH 只含 $PREFIX/lib/pkgconfig，
    # 结果 openssl 明明编好了却 pkg-config 找不到，--enable-openssl 会被静默关掉。
    "--libdir=lib"
    "--openssldir=$PREFIX/ssl"
    "$(openssl_target)"
    no-shared no-tests no-async no-ssl3 no-comp
  )
  if [ "${TARGET_OS:-}" = "android" ]; then
    # NDK 的 clang 需要显式 API level，否则默认按最低版本编
    args+=("-D__ANDROID_API__=${ANDROID_API:-19}")
  fi

  # openssl 用的是大写 Configure（perl 脚本）
  custom_configure "$dir" openssl Configure "${args[@]}"
  require_pc openssl
}

# ------------------------------------------------------------------------------
# expat —— fontconfig 的 XML 解析器
# ------------------------------------------------------------------------------
build_expat() {
  dep_needed expat || return 0
  local dir; dir="$(fetch expat)"

  autotools_build "$dir" expat \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    --without-docbook \
    --without-xmlwf

  require_pc expat
}

# ------------------------------------------------------------------------------
# fontconfig —— libass 在非 Windows 平台的字体提供者
# 注意：它需要的字体目录在运行时确定，静态链接时把默认值写死进二进制
# ------------------------------------------------------------------------------
build_fontconfig() {
  dep_needed fontconfig || return 0
  local dir; dir="$(fetch fontconfig)"

  require_pc expat
  require_pc freetype2

  # ---- fontconfig 的 posix_fadvise 陷阱（只在 Android API 19 炸）----
  # ① 检测方式不靠谱：configure.ac 用 AC_CHECK_SYMBOL，而这个宏**只 grep 头文件、
  #    不试链接**。bionic 的 fcntl.h 在 API 19 里就有 posix_fadvise 的声明
  #    （带 __INTRODUCED_IN(21) 标注），于是检测判为「有」；
  #    可 21 以前的 libc 里根本没有这个符号 → 链接期 undefined symbol。
  # ② 守卫也写错了：AC_DEFINE_UNQUOTED(HAVE_POSIX_FADVISE, 0) 在值为 0 时
  #    依然是 defined，而 fccache.c 用的是 #if defined(HAVE_POSIX_FADVISE)，
  #    于是「检测为 0」也照样编译进去。
  # 试过用 ac_cv_func_posix_fadvise=0 绕开检测，结果更糟：缓存变量一旦预设，
  # AC_CHECK_SYMBOL 的成功/失败分支都不执行，fc_func_posix_fadvise 变成空串，
  # config.h 里就成了 `#define HAVE_POSIX_FADVISE`（无值），
  # 编译报 "invalid token at start of a preprocessor expression"。
  # 最终做法：直接删掉这 3 行。它只是 fc-cache 里一次 mmap 预读提示
  # （POSIX_FADV_WILLNEED），删掉只影响 fc-cache 自己的读盘策略，
  # 与 FFmpeg / libass 无任何关系。
  python3 - "$dir/src/fccache.c" <<'PY'
import sys
p = sys.argv[1]
with open(p, encoding='utf-8', errors='surrogateescape', newline='') as f:
    s = f.read()
old = ("#if defined(HAVE_POSIX_FADVISE) && defined(POSIX_FADV_WILLNEED)\n"
       "\tposix_fadvise (fd, 0, fd_stat->st_size, POSIX_FADV_WILLNEED);\n"
       "#endif\n")
new = ("/* posix_fadvise 已移除：Android API<21 的 bionic 只有声明没有符号，\n"
       " * 而 fontconfig 的 AC_CHECK_SYMBOL 只 grep 头文件、不试链接，防线全失。\n"
       " * 这只是一次 mmap 预读提示，删掉不影响功能。 */\n")
if s.count(old) != 1:
    sys.stderr.write("[fontconfig] posix_fadvise 锚点匹配 %d 次，期望 1 次\n" % s.count(old))
    sys.exit(1)
with open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
    f.write(s.replace(old, new))
PY
  ok "fontconfig: 移除 posix_fadvise 调用（fc-cache 的预读提示）"

  local fontdir="/usr/share/fonts"
  [ "${TARGET_OS:-}" = "android" ] && fontdir="/system/fonts"

  autotools_build "$dir" fontconfig \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    --disable-docs \
    --disable-nls \
    --sysconfdir="$PREFIX/etc" \
    --localstatedir="$PREFIX/var" \
    --with-default-fonts="$fontdir" \
    --with-cache-dir="$PREFIX/var/cache/fontconfig"

  require_pc fontconfig
}

# ------------------------------------------------------------------------------
# freetype —— 字体渲染
# GitHub 归档只有 CMakeLists，用 cmake（不依赖 autoreconf）
# harfbuzz / brotli / png / bzip2 全关：这些交给 libass 自己链 harfbuzz，
# 让 freetype 再依赖一遍只会增加失败面
# ------------------------------------------------------------------------------
build_freetype() {
  dep_needed freetype || return 0
  local dir; dir="$(fetch freetype)"

  cmake_build "$dir" freetype \
    -DFT_DISABLE_HARFBUZZ=TRUE \
    -DFT_DISABLE_BROTLI=TRUE \
    -DFT_DISABLE_PNG=TRUE \
    -DFT_DISABLE_BZIP2=TRUE \
    -DFT_DISABLE_ZLIB=FALSE \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc freetype2
}

# ------------------------------------------------------------------------------
# fribidi —— 双向文本（阿拉伯语/希伯来语字幕排版）
# ------------------------------------------------------------------------------
build_fribidi() {
  dep_needed fribidi || return 0
  local dir; dir="$(fetch fribidi)"

  autotools_build "$dir" fribidi \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    --disable-docs

  require_pc fribidi
}

# ------------------------------------------------------------------------------
# harfbuzz —— 复杂文本整形（字幕排版质量的关键）
# 依赖 freetype；glib/gobject/icu/cairo 全关，避免拖进一整套 GNOME 依赖
# ------------------------------------------------------------------------------
build_harfbuzz() {
  dep_needed harfbuzz || return 0
  local dir; dir="$(fetch harfbuzz)"

  require_pc freetype2

  meson_build "$dir" harfbuzz \
    -Dglib=disabled \
    -Dgobject=disabled \
    -Dicu=disabled \
    -Dcairo=disabled \
    -Dfreetype=enabled \
    -Dtests=disabled \
    -Ddocs=disabled \
    -Dintrospection=disabled

  require_pc harfbuzz
}

# ------------------------------------------------------------------------------
# libass —— ASS/SSA 字幕渲染
# Windows 用 directwrite 当字体提供者（系统自带，零额外依赖）
# 其他平台必须有 fontconfig
# ------------------------------------------------------------------------------
build_libass() {
  dep_needed libass || return 0
  local dir; dir="$(fetch libass)"

  require_pc freetype2
  require_pc fribidi
  require_pc harfbuzz

  local args=(
    --disable-shared --enable-static
    --disable-dependency-tracking
    --disable-test
  )
  if [ "${TARGET_OS:-}" = "windows" ]; then
    args+=(--enable-directwrite --disable-fontconfig)
  else
    require_pc fontconfig
    args+=(--enable-fontconfig)
  fi

  autotools_build "$dir" libass "${args[@]}"
  require_pc libass
}

# ------------------------------------------------------------------------------
# zimg —— 高质量色彩空间/缩放（FFmpeg 的 zscale 滤镜）
# 纯 C++，GitHub 归档没有 configure，靠 autoreconf 生成
# ------------------------------------------------------------------------------
build_zimg() {
  dep_needed zimg || return 0
  local dir; dir="$(fetch zimg)"

  local extra=()
  case "${TARGET_ARCH:-x86_64}" in
    x86_64|i?86) extra+=(--enable-x86simd) ;;
  esac

  autotools_build "$dir" zimg \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    "${extra[@]}"

  require_pc zimg
}

# ------------------------------------------------------------------------------
# srt —— SRT 传输协议（低延迟直播/回传）
# 加密库指定 openssl，否则它会去找 mbedtls 然后失败
# ------------------------------------------------------------------------------
build_srt() {
  dep_needed srt || return 0
  local dir; dir="$(fetch srt)"

  require_pc openssl

  local extra=()
  # Android API<21（armv7）的 bionic 没有 pthread_condattr_setclock（21 才加）。
  # srt 的 sync.h 只要有 ENABLE_MONOTONIC_CLOCK 就会走
  #   pthread_condattr_setclock(&CondAttribs, CLOCK_MONOTONIC)
  # 这条路径，而 srt 的 cmake 探测的是 clock_gettime（API19 确实有），
  # 于是它自信地打开 monotonic，编译期就报
  #   error: use of undeclared identifier 'pthread_condattr_setclock'
  # srt 官方给了开关：关掉后退回 CLOCK_REALTIME 的 condvar 超时，
  # 对 FFmpeg 用到的 srt 协议无实际影响。API>=21 保持默认（更精确）。
  if [ "${TARGET_OS:-}" = "android" ] && [ "${ANDROID_API:-99}" -lt 21 ]; then
    extra+=("-DENABLE_MONOTONIC_CLOCK=OFF")
    warn "srt: Android API ${ANDROID_API} 无 pthread_condattr_setclock，关闭 monotonic clock"
  fi

  cmake_build "$dir" srt \
    -DENABLE_APPS=OFF \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DUSE_ENCLIB=openssl \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "${extra[@]}"

  require_pc srt
}

# ------------------------------------------------------------------------------
# SDL2 —— 只给 ffplay 用（Windows 专属）
# ------------------------------------------------------------------------------
build_sdl2() {
  dep_needed sdl2 || return 0
  local dir; dir="$(fetch sdl2)"

  autotools_build "$dir" sdl2 \
    --disable-shared --enable-static \
    --disable-dependency-tracking

  require_pc sdl2
}

# ------------------------------------------------------------------------------
build_misc_all() {
  build_zlib
  build_openssl
  build_freetype
  build_expat
  build_fontconfig
  build_fribidi
  build_harfbuzz
  build_libass
  build_zimg
  build_srt
  build_sdl2
}
