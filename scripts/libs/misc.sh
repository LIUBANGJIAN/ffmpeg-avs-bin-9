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
# pixman + cairo —— 唯一目的是开出 FFmpeg 的 drawvg 滤镜
#
# configure 里就一行：drawvg_filter_deps="cairo"，检测走 require_pkg_config cairo。
# 所以只要有 cairo.pc 就行，不关心后端。
#
# 关掉全部可选后端（xlib/xcb/glib/freetype/fontconfig/png/zlib/quartz/dwrite），
# 原因：
#   - 我们只用 cairo 画 SVG，image surface 足够，不需要任何 windowing 后端
#   - glib 会拖进 pkg-config + libffi 一整条链；freetype/fontconfig 我们虽然
#     编了但那套是给 libass 用的，跟 drawvg 无关，交叉编译时反而容易连错
#   - spectre 默认开，它需要 pixman 的私有结构，关掉更稳
# ------------------------------------------------------------------------------
build_pixman() {
  dep_needed pixman || return 0
  local dir; dir="$(fetch pixman)"

  local extra=()
  # Android 的 ARM 上 pixman-arm.c 会 #include <cpu-features.h>，
  # 而 NDK 不给这个头文件开 -I（它属于 libandroid，API 19 桥接层）。
  # 实测报错：pixman-arm.c:98:10: fatal error: 'cpu-features.h' file not found
  # pixman 为此专门留了 cpu-features-path 选项：指向含 cpu-features.[ch] 的目录，
  # 它会把这俩源文件直接编进自己的静态库，不依赖 libandroid。
  # NDK 里这份源码在 $ANDROID_NDK_HOME/sources/android/cpufeatures/。
  case "${TARGET_OS:-}/${TARGET_ARCH:-}" in
    android/arm*)
      local cf="${ANDROID_NDK_HOME:-}/sources/android/cpufeatures"
      if [ -f "$cf/cpu-features.h" ]; then
        extra+=("-Dcpu-features-path=$cf")
        log "pixman: 使用 NDK 的 cpu-features（$cf）"
      else
        # 兜底：不编 NEON/ARM SIMD 路径，纯 C 也能出正确结果，只是慢。
        # 这比整个构建失败好，但要让它在日志里可见。
        warn "pixman: 找不到 NDK 的 cpufeatures，关掉 NEON/ARM-SIMD（纯 C）"
        extra+=("-Dneon=disabled" "-Darm-simd=disabled" "-Da64-neon=disabled")
      fi
      ;;
  esac

  # 注意 pixman 的选项类型不统一：gnuplot / timers 是 boolean，
  # 其余（tests/demos/gtk/libpng/openmp）是 feature。给 boolean 传 'disabled'
  # 会让 meson setup 直接报 "Option "gnuplot" value disabled is not boolean"。
  meson_build "$dir" pixman \
    -Dtests=disabled \
    -Ddemos=disabled \
    -Dgtk=disabled \
    -Dlibpng=disabled \
    -Dopenmp=disabled \
    -Dgnuplot=false \
    -Dtimers=false \
    "${extra[@]}"

  require_pc pixman-1
}

build_cairo() {
  dep_needed cairo || return 0
  local dir; dir="$(fetch cairo)"

  # cairo 1.18.6 的 meson.build 写死 meson_version: '>= 1.3.0'，
  # 而且用的是新版 `meson.options` 文件名（旧版 meson 只认 meson_options.txt，
  # 会把所有选项当成未知选项直接报错）。这里提前拦，比让 ninja 跑到一半再炸省事。
  local mv lowest
  mv="$(meson --version 2>/dev/null || echo 0)"
  # sort -V 升序取第一个 = 两者中较小的那个。若较小的不是 1.3.0，说明 mv < 1.3.0。
  # （不能直接用 sort -V -C 的退出码：那是判断"是否已有序"，方向容易搞反。）
  lowest=$(printf '%s\n' "$mv" 1.3.0 | sort -V | head -1)
  if [ "$lowest" != "1.3.0" ]; then
    die "cairo 1.18.6 需要 meson >= 1.3.0，当前是 $mv"
  fi
  ok "meson $mv 满足 cairo 的要求"

  # pixman 必须已经在 prefix 里，否则 meson 会退回 subproject wrap 联网拉取
  require_pc pixman-1

  # Windows：cairo 无条件编 win32 后端（meson.build 里是
  #   `if host_machine.system() == 'windows'`，没有开关能关掉），
  # 而 cairo-win32-system.c 用了 Windows 8+ 的 COM API CoIncrementMTAUsage，
  # 它依赖 objbase.h 里的 CO_MTA_USAGE_COOKIE。MinGW 的 objbase.h 没这个 typedef，
  # 实测报错：
  #   error: unknown type name 'CO_MTA_USAGE_COOKIE'
  #   error: unknown type name 'pCoIncrementMTAUsage_t'
  #
  # 它只是个不透明句柄，语义上等价于 PVOID，补一个 typedef 即可。
  # 用 edit_exact 而不是 patch(1)：锚点必须精确匹配 1 次，上游改了会立刻报错，
  # 不会出现"看起来打了其实没打"的半残产物。
  if [ "${TARGET_OS:-}" = "windows" ]; then
    local sysc="$dir/src/win32/cairo-win32-system.c"
    [ -f "$sysc" ] || die "cairo: 找不到 src/win32/cairo-win32-system.c"
    edit_exact "$sysc" \
'#include <stdbool.h>

typedef HRESULT (__stdcall *pCoIncrementMTAUsage_t) (CO_MTA_USAGE_COOKIE*);' \
'#include <stdbool.h>

/* MinGW 的 objbase.h 没有 CO_MTA_USAGE_COOKIE（Windows 8+ 的 COM API）。
 * 它只是个不透明句柄，语义等价于 PVOID，补上即可。
 * 只在 MinGW 下补：MSVC 的 SDK 头文件里本来就有，重复定义会冲突。 */
#if defined(__MINGW32__) && !defined(CO_MTA_USAGE_COOKIE)
typedef PVOID CO_MTA_USAGE_COOKIE;
#endif

typedef HRESULT (__stdcall *pCoIncrementMTAUsage_t) (CO_MTA_USAGE_COOKIE*);'
  fi

  # cairo 的选项类型也不统一：只有 gtk_doc 是 boolean，其余都是 feature。
  # （spectre / symbol-lookup 是 feature，写成 false 会让 meson setup 直接报错。）
  meson_build "$dir" cairo \
    -Dxlib=disabled \
    -Dxcb=disabled \
    -Dxlib-xcb=disabled \
    -Dglib=disabled \
    -Dfreetype=disabled \
    -Dfontconfig=disabled \
    -Dpng=disabled \
    -Dzlib=disabled \
    -Dquartz=disabled \
    -Ddwrite=disabled \
    -Dgtk2-utils=disabled \
    -Dgtk_doc=false \
    -Dtests=disabled \
    -Dlzo=disabled \
    -Dtee=disabled \
    -Dspectre=disabled \
    -Dsymbol-lookup=disabled

  # Windows 静态库的 dllimport 问题。
  #
  # cairo 的 src/meson.build 里有这么一段：
  #   if get_option('default_library') == 'static' and host_machine.system() == 'windows'
  #     add_project_arguments('-DCAIRO_WIN32_STATIC_BUILD', language: 'c')
  #   endif
  # 这个宏让 cairo 自己的头文件不再给函数加 __declspec(dllimport)，
  # 静态库里才会是 cairo_create 而不是 __imp_cairo_create。
  #
  # 但 add_project_arguments **只作用于编 cairo 自己**，
  # 而 pkgmod.generate(libcairo, ...) 没有传 extra_cflags，
  # 所以 cairo.pc 的 Cflags 里没有这个宏 —— 使用方（FFmpeg configure 的
  # require_pkg_config cairo）拿到的仍是 dllimport 声明，链接时变成：
  #   undefined reference to `__imp_cairo_create'
  #
  # 实测就是这个错，且 Windows 才会犯（非 Windows 无 dllimport 概念）。
  # 修法：给装好的 cairo.pc 的 Cflags 补上该宏。
  if [ "${TARGET_OS:-}" = "windows" ]; then
    local pc="$PREFIX/lib/pkgconfig/cairo.pc"
    [ -f "$pc" ] || die "cairo: 找不到 $pc"
    if ! grep -q 'CAIRO_WIN32_STATIC_BUILD' "$pc"; then
      # 用 python 改，避免 sed -i 在不同平台上的行为差异。
      # 注意：这里**不能** print 中文 —— MSYS2 的 Python 默认 stdout 是 cp1252，
      # 输出中文会抛 UnicodeEncodeError 把整个构建打挂（实测踩过一次）。
      # 需要提示就交给外面的 ok/warn 打（bash 侧没这个问题）。
      python3 - "$pc" <<'PY'
import sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8', newline='') as f:
    s = f.read()
lines = s.splitlines(True)
out = []
done = False
for ln in lines:
    if ln.startswith('Cflags:') and not done:
        out.append(ln.rstrip('\n') + ' -DCAIRO_WIN32_STATIC_BUILD\n')
        done = True
    else:
        out.append(ln)
if not done:
    sys.stderr.write("cairo.pc has no Cflags line\n")
    sys.exit(1)
with open(p, 'w', encoding='utf-8', newline='') as f:
    f.write(''.join(out))
PY
      [ $? -eq 0 ] || die "cairo: 给 cairo.pc 注入 CAIRO_WIN32_STATIC_BUILD 失败"
    fi
    ok "cairo.pc 已带 CAIRO_WIN32_STATIC_BUILD"

    # 把 pkg-config 实际吐出来的 flags 打进日志。
    # 之前 CI 上链接仍然缺这个宏，但日志里看不出 pkg-config 到底给了什么，
    # 只能靠猜。这行是排查用的：下轮若还失败，直接看这里就知道是
    # 「pc 没写进去」还是「pkg-config 没把它吐出来」。
    log "cairo.pc Cflags 行：$(grep -a '^Cflags:' "$pc" || echo '(无)')"
    log "pkg-config --cflags cairo 输出：$(pkg-config --cflags cairo 2>&1)"
  fi

  require_pc cairo
}

# ------------------------------------------------------------------------------
# 硬件编解码头文件 / 库（Windows 专属）
#
# 这三个曾经只在 env.sh 的 DEPS 里登记，**没有对应的 build 函数**，
# 于是从来没有被安装过；build-ffmpeg.sh 里的 _have_pc 探测必然失败，
# 一路 WARN 跳过，构建照样全绿 —— 结果是产物里 nvenc / qsv / amf 一个都没有。
# 属于安静型故障：CI 不红，但功能缺失。下面补齐。
#
# 分工要分清：
#   nvcodec (ffnvcodec)  只有头文件，没有 .a。它给 nvenc/nvdec/cuvid 提供 ABI 声明，
#                        真正的实现在 NVIDIA 驱动里，运行时动态加载 ⇒ 静态链接照样能用。
#   libvpl               Intel oneVPL，有静态库 + .pc。
#   amf                  AMD，无 .pc、无库，只装头文件目录 AMF/。
# ------------------------------------------------------------------------------
build_nvcodec() {
  dep_needed nvcodec || return 0
  local dir; dir="$(fetch nvcodec)"
  local logf="$LOGS/nvcodec.log"
  CURRENT_LOGFILE="$logf"

  # 它没有任何编译单元，install 只是拷头文件 + 由 ffnvcodec.pc.in 生成 .pc。
  # 用 PREFIX 而不是 DESTDIR 覆盖：Makefile 里是 `PREFIX ?= /usr/local`。
  make -C "$dir" install "PREFIX=$PREFIX" > "$logf" 2>&1 \
    || { dump_log "$logf"; die "nvcodec: make install 失败"; }

  require_pc ffnvcodec
}

build_libvpl() {
  dep_needed libvpl || return 0
  local dir; dir="$(fetch libvpl)"

  # Windows/MinGW：libvpl 的 mfx_dispatcher_defs.h 写了
  #     #if _MSC_VER < 1400
  #         #define wcscpy_s(to,to_size,from) \
  #             (void)(to_size); \
  #             wcscpy(to, from)
  #     ...
  #     #endif
  # MinGW 不定义 _MSC_VER，预处理器按 0 处理 ⇒ 0 < 1400 成立 ⇒ 走进这个分支。
  # 而这个多行宏本身是坏的：调用处是 `return 0 == wcscpy_s(...)`，
  # 展开后变成 `return 0 == (void)(n); wcscpy(...);`，语法直接崩：
  #     error: expected ')' before ';' token
  #     error: stray declaration / void value not ignored
  # 连带把 mingw 的 stralign.h 也拖下水（208 行）。
  #
  # 上游 2.13 / 2.14 / 2.15 都没修，升级版本没用，只能本地改。
  # 改法：让 MinGW 不进那个分支（它本来就不该进 —— MinGW 没有 wcscpy_s），
  # 另给一个语义等价的 inline 实现（返回 errno_t，0 = 成功，与调用处的
  # `return 0 == wcscpy_s(...)` 判据一致）。
  if [ "${TARGET_OS:-}" = "windows" ]; then
    local defs="$dir/libvpl/src/windows/mfx_dispatcher_defs.h"
    [ -f "$defs" ] || die "libvpl: 找不到 libvpl/src/windows/mfx_dispatcher_defs.h"

    # 用 heredoc 存新旧两段，避免 C 源码里的单引号与 bash 的 '...' 打架
    local vpl_old vpl_new
    vpl_old=$(cat <<'VPLOLD'
#if _MSC_VER < 1400
    #define wcscpy_s(to, to_size, from) \
        (void)(to_size);                \
        wcscpy(to, from)
    #define wcscat_s(to, to_size, from) \
        (void)(to_size);                \
        wcscat(to, from)
#endif
VPLOLD
)
    vpl_new=$(cat <<'VPLNEW'
#if !defined(__MINGW32__) && _MSC_VER < 1400
    #define wcscpy_s(to, to_size, from) \
        (void)(to_size);                \
        wcscpy(to, from)
    #define wcscat_s(to, to_size, from) \
        (void)(to_size);                \
        wcscat(to, from)
#endif

/* MinGW 没有 wcscpy_s / wcscat_s（MSVC CRT 专有），但调用处会检查返回值：
 *     return 0 == wcscpy_s(pPath, pathSize, name) ? MFX_ERR_NONE : ...
 * 所以给语义一致的实现：成功返回 0，超长返回 ERANGE 并截断置零。 */
#if defined(__MINGW32__)
#include <cerrno>
#include <cwchar>
static inline errno_t vpl_wcscpy_s(wchar_t *dst, size_t dstsz, const wchar_t *src)
{
    if (!dst || dstsz == 0) return EINVAL;
    size_t i = 0;
    for (; src && src[i] && i + 1 < dstsz; i++) dst[i] = src[i];
    bool truncated = (src && src[i] != 0);
    dst[i] = 0;
    return truncated ? ERANGE : 0;
}
static inline errno_t vpl_wcscat_s(wchar_t *dst, size_t dstsz, const wchar_t *src)
{
    if (!dst || dstsz == 0) return EINVAL;
    size_t i = 0;
    while (i < dstsz && dst[i]) i++;
    if (i >= dstsz) return EINVAL;
    return vpl_wcscpy_s(dst + i, dstsz - i, src);
}
#define wcscpy_s vpl_wcscpy_s
#define wcscat_s vpl_wcscat_s
#endif
VPLNEW
)
    edit_exact "$defs" "$vpl_old" "$vpl_new"
  fi

  # 只要 dispatcher 那个静态库，不要 examples / tools / 测试
  cmake_build "$dir" libvpl \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TOOLS=OFF \
    -DBUILD_TESTS=OFF

  # 注意 pkg-config 名是 **vpl** 而不是 libvpl —— 上游 libvpl/pkgconfig/vpl.pc.in
  # 生成的产物就叫 vpl.pc。这也正好对上 FFmpeg configure 里那句：
  #   check_pkg_config libmfx "vpl >= 2.6" "mfxvideo.h mfxdispatcher.h" MFXLoad
  require_pc vpl
}

build_amf() {
  dep_needed amf || return 0
  local dir; dir="$(fetch amf)"

  # AMF 只有头文件，没有 .pc。FFmpeg configure 的检测写死了
  #   test_cc ... -I$prefix/include/AMF
  # 所以必须装到 $PREFIX/include/AMF/ 这一层，不能多一层也不能少一层。
  [ -d "$dir/amf/public/include" ] \
    || die "amf: 找不到 amf/public/include（上游目录结构变了）"

  mkdir -p "$PREFIX/include"
  cp -rf "$dir/amf/public/include" "$PREFIX/include/AMF"
  ok "安装 include/AMF（$(ls "$PREFIX/include/AMF" | wc -l) 个头文件）"
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
  build_pixman
  build_cairo
  # 硬件编解码（Windows 专属，dep_needed 内部按 TARGET_OS 过滤）
  build_nvcodec
  build_libvpl
  build_amf
}
