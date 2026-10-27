#!/usr/bin/env bash
# ==============================================================================
# 通用构建工具库 —— 由 build-*.sh source
#
# 设计要点：本文件不关心你在哪个平台。平台差异全部由调用方通过下面这些变量表达：
#   CC  CXX  AR  RANLIB  STRIP  NM  CFLAGS  CXXFLAGS  LDFLAGS  HOST
#   CMAKE_TOOLCHAIN  (cmake 的 -DCMAKE_TOOLCHAIN_FILE 路径)
#   ANDROID_ABI / ANDROID_PLATFORM  (仅 Android)
# 库脚本(scripts/libs/*.sh)只调用 autotools_build / cmake_build，不写平台判断。
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------
# 路径
# ------------------------------------------------------------------
: "${ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${WORK:=$ROOT/work}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

DL="$WORK/dl"
SRC="$WORK/src"
BLD="$WORK/build"
LOGS="$WORK/logs"
PREFIX="${PREFIX:-$WORK/prefix}"
export PREFIX

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$PREFIX/bin:$PATH"

mkdir -p "$DL" "$SRC" "$BLD" "$LOGS" "$PREFIX"

# ------------------------------------------------------------------
# 输出
# ------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_CYN=$'\033[1;36m'; C_GRN=$'\033[1;32m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_CYN=''; C_GRN=''; C_OFF=''
fi

# 日志一律走 stderr —— 因为 fetch() 用 stdout 回传路径，
# log() 若走 stdout 会被 $(fetch ...) 一起捕获进路径变量，排查起来极难。
log()  { printf '\n%s>>> %s%s\n' "$C_CYN" "$*" "$C_OFF" >&2; }
ok()   { printf '%s[OK] %s%s\n' "$C_GRN" "$*" "$C_OFF" >&2; }
warn() { printf '%s[WARN] %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; }
die()  { printf '%s[FATAL] %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

# 失败时把日志尾巴打出来，否则 CI 里只能看到"退出码 1"
dump_log() {
  local f="$1"
  [ -f "$f" ] || return 0

  # 只看「最后 60 行」是不够的：并行 make 会把真正的报错埋掉，
  # CMake 的 CMake Error 还可能因为 stdout/stderr 缓冲顺序跑到中间去。
  # 所以先在全文里把关键错误行捞出来，再补一段尾部。
  if grep -q "CMake Error" "$f" 2>/dev/null; then
    warn "----- CMake Error 上下文：$f -----"
    grep -n -A 8 "CMake Error" "$f" | head -n 60 >&2 || true
  fi

  warn "----- 关键错误行：$f -----"
  grep -n -E "error:|Error [0-9]+$|undefined reference|ld returned|No such file|cannot find|not found|Configuration failed" "$f" 2>/dev/null \
    | tail -n 30 >&2 || true

  warn "----- 日志尾部：$f -----"
  tail -n 60 "$f" >&2 || true
  warn "----- 日志结束 -----"
}

# ------------------------------------------------------------------
# 依赖清单查询
# ------------------------------------------------------------------
# dep_spec <name>  ->  "kind<TAB>url<TAB>ref"
dep_spec() {
  local want="$1" line rest kind url ref
  for line in "${DEPS[@]}"; do
    case "$line" in
      "$want|"*) ;;
      *) continue ;;
    esac
    # 不能用 set -- $line 拆分：tar 类依赖的 ref 字段是空的，
    # `set -- a|b|c|` 会把这个尾部空字段整个丢掉，
    # 在 set -u 下访问 $4 直接报 "unbound variable"。
    rest="${line#*|}"        # kind|url|ref
    kind="${rest%%|*}"
    rest="${rest#*|}"        # url|ref
    url="${rest%%|*}"
    ref="${rest#*|}"         # 只剩 ref（可能为空串）
    printf '%s\t%s\t%s\n' "$kind" "$url" "$ref"
    return 0
  done
  die "env.sh 里没有找到依赖：$want"
}

have_dep() {
  local line
  for line in "${DEPS[@]}"; do
    [ "${line%%|*}" = "$1" ] && return 0
  done
  return 1
}

# ------------------------------------------------------------------
# 下载 / 解包
# ------------------------------------------------------------------
download() {
  local url="$1" out="$2"
  [ -s "$out" ] && { return 0; }
  log "下载 $(basename "$out")"
  # -f 让 4xx/5xx 直接失败，避免把错误页面当压缩包存下来
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
       -o "$out.part" "$url" || { rm -f "$out.part"; die "下载失败：$url"; }
  mv "$out.part" "$out"
}

# fetch <name>  -> 打印源码目录路径
fetch() {
  local name="$1"
  local spec kind url ref
  IFS=$'\t' read -r kind url ref <<< "$(dep_spec "$name")"
  local dir="$SRC/$name"

  if [ "$kind" = "git" ]; then
    if [ ! -d "$dir/.git" ]; then
      log "克隆 $name ($ref)"
      rm -rf "$dir"
      git clone --quiet "$url" "$dir" || die "克隆失败：$url"
    fi
    ( cd "$dir" && git fetch --quiet origin && git checkout --quiet "$ref" ) \
      || die "$name 切到 $ref 失败"
    printf '%s\n' "$dir"
    return 0
  fi

  # ---- tar ----
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    local base="${url%%\?*}"
    local fname="$DL/$name--${base##*/}"
    download "$url" "$fname"
    log "解包 $name"
    mkdir -p "$dir"
    case "$fname" in
      *.tar.xz|*.txz) tar -xJf "$fname" -C "$dir" --strip-components=1 ;;
      *.tar.gz|*.tgz) tar -xzf "$fname" -C "$dir" --strip-components=1 ;;
      *.zip)          unzip -q  "$fname" -d "$dir" && \
                      { local one; one=$(ls -A "$dir"); \
                        [ -d "$dir/$one" ] && mv "$dir/$one"/* "$dir/" && rmdir "$dir/$one"; } ;;
      *) die "不认识的压缩格式：$fname" ;;
    esac
  fi
  printf '%s\n' "$dir"
}

# ------------------------------------------------------------------
# autotools / configure 系
# ------------------------------------------------------------------
# ------------------------------------------------------------------
# 确保源码里有 configure
#
# 为什么需要：GitHub 的 refs/tags/*.tar.gz 归档里只有 configure.ac，
# 没有生成好的 configure（发行版 tarball 才有）。ogg / vorbis / opus / zimg
# 都属于这类，直接 ./configure 会报 "No such file or directory"。
# ------------------------------------------------------------------
ensure_configure() {
  local dir="$1" tag="$2"
  [ -f "$dir/configure" ] && return 0

  local logf="$LOGS/${tag}-autoreconf.log"
  if [ -f "$dir/autogen.sh" ]; then
    log "生成 configure：./autogen.sh ($tag)"
    ( cd "$dir" && NOCONFIGURE=1 ./autogen.sh ) > "$logf" 2>&1 \
      || { dump_log "$logf"; die "$tag: autogen.sh 失败"; }
  elif [ -f "$dir/configure.ac" ] || [ -f "$dir/configure.in" ]; then
    log "生成 configure：autoreconf -fiv ($tag)"
    ( cd "$dir" && autoreconf -fiv ) > "$logf" 2>&1 \
      || { dump_log "$logf"; die "$tag: autoreconf 失败"; }
  else
    die "$tag: 源码里既没有 configure 也没有 configure.ac"
  fi

  [ -f "$dir/configure" ] || die "$tag: autoreconf 之后仍然没有 configure"
  ok "$tag: configure 已生成"
}

# autotools_build <源码目录> <日志后缀> [configure 额外参数...]
CURRENT_LOGFILE=""
autotools_build() {
  local dir="$1"; shift
  local tag="$1"; shift
  local logf="$LOGS/${tag}.log"
  CURRENT_LOGFILE="$logf"

  ensure_configure "$dir" "$tag"

  log "configure $tag"
  (
    cd "$dir"
    ./configure \
      --prefix="$PREFIX" \
      --enable-static \
      --disable-shared \
      ${HOST:+--host="$HOST"} \
      "$@"
  ) > "$logf" 2>&1 || { dump_log "$logf"; die "$tag: configure 失败"; }
  ok "$tag: configure 完成"

  log "make $tag"
  ( cd "$dir" && make -j"$JOBS" >> "$logf" 2>&1 ) \
    || { dump_log "$logf"; die "$tag: make 失败"; }
  ( cd "$dir" && make install >> "$logf" 2>&1 ) \
    || { dump_log "$logf"; die "$tag: make install 失败"; }
  ok "$tag: 安装完成"
}

# 只跑 make/make install（已经手工 configure 过的场景）
make_install() {
  local dir="$1" tag="$2"
  local logf="$LOGS/${tag}.log"
  CURRENT_LOGFILE="$logf"
  log "make $tag"
  ( cd "$dir" && make -j"$JOBS" >> "$logf" 2>&1 ) \
    || { dump_log "$logf"; die "$tag: make 失败"; }
  ( cd "$dir" && make install >> "$logf" 2>&1 ) \
    || { dump_log "$logf"; die "$tag: make install 失败"; }
  ok "$tag: 安装完成"
}

# ------------------------------------------------------------------
# 自定义 configure（不是 autotools 的项目）
#
# 为什么不能复用 autotools_build：autotools_build 会硬塞 --enable-static
# --disable-shared，而 zlib / libvpx / openssl / davs2 的 configure 各有各的
# 脾气（openssl 甚至用大写 ./Configure + perl）。这里只保证：
#   - 参数由调用方全权决定
#   - 日志落盘、失败打印尾巴
# ------------------------------------------------------------------
# custom_configure <源码目录> <日志后缀> <可执行文件> [参数...]
custom_configure() {
  local dir="$1"; shift
  local tag="$1"; shift
  local prog="$1"; shift
  local logf="$LOGS/${tag}.log"
  CURRENT_LOGFILE="$logf"

  log "configure $tag"
  ( cd "$dir" && "./$prog" "$@" ) > "$logf" 2>&1 \
    || { dump_log "$logf"; die "$tag: configure 失败"; }
  ok "$tag: configure 完成"

  log "make $tag"
  ( cd "$dir" && make -j"$JOBS" >> "$logf" 2>&1 ) \
    || { dump_log "$logf"; die "$tag: make 失败"; }
  ( cd "$dir" && make install >> "$logf" 2>&1 ) \
    || { dump_log "$logf"; die "$tag: make install 失败"; }
  ok "$tag: 安装完成"
}

# ------------------------------------------------------------------
# meson 系（dav1d / harfbuzz）
# ------------------------------------------------------------------
# meson_build <源码目录> <日志后缀> [meson 参数...]
meson_build() {
  local dir="$1"; shift
  local tag="$1"; shift
  local bdir="$BLD/$tag"
  local logf="$LOGS/${tag}.log"
  CURRENT_LOGFILE="$logf"

  local cross=()
  if [ -n "${MESON_CROSS_FILE:-}" ] && [ -f "${MESON_CROSS_FILE}" ]; then
    cross+=("--cross-file=$MESON_CROSS_FILE")
  fi

  log "meson setup $tag"
  meson setup "$bdir" "$dir" \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        "${cross[@]}" \
        "$@" > "$logf" 2>&1 || { dump_log "$logf"; die "$tag: meson setup 失败"; }

  log "ninja $tag"
  ninja -C "$bdir" -j "$JOBS" >> "$logf" 2>&1 \
    || { dump_log "$logf"; die "$tag: ninja 失败"; }
  ninja -C "$bdir" install >> "$logf" 2>&1 \
    || { dump_log "$logf"; die "$tag: ninja install 失败"; }
  ok "$tag: 安装完成"
}

# ------------------------------------------------------------------
# cmake 系
# ------------------------------------------------------------------
# cmake_build <源码目录> <日志后缀> [cmake 额外参数...]
cmake_build() {
  local dir="$1"; shift
  local tag="$1"; shift
  local bdir="$BLD/$tag"
  local logf="$LOGS/${tag}.log"
  CURRENT_LOGFILE="$logf"

  local tc_args=()
  if [ -n "${CMAKE_TOOLCHAIN:-}" ]; then
    tc_args+=("-DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN")
  fi
  if [ -n "${ANDROID_ABI:-}" ]; then
    tc_args+=("-DANDROID_ABI=$ANDROID_ABI" "-DANDROID_PLATFORM=${ANDROID_PLATFORM:-android-19}")
  fi

  log "cmake configure $tag"
  cmake -S "$dir" -B "$bdir" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        "${tc_args[@]}" \
        "$@" > "$logf" 2>&1 || { dump_log "$logf"; die "$tag: cmake configure 失败"; }

  log "cmake build $tag"
  # CMAKE_BUILD_TARGET：只编指定目标。
  # 用来跳过那些「我们根本不需要、但在交叉环境里必炸」的命令行程序
  # （uavs3d/uavs3e 的 test/utest.c 会 target_link_libraries(… pthread)，
  #  而 bionic 把 pthread 并进了 libc，没有单独的 -lpthread → ld 报
  #  "unable to find library -lpthread"）。
  if [ -n "${CMAKE_BUILD_TARGET:-}" ]; then
    cmake --build "$bdir" --target "$CMAKE_BUILD_TARGET" -j "$JOBS" >> "$logf" 2>&1 \
      || { dump_log "$logf"; die "$tag: cmake build 失败（target=$CMAKE_BUILD_TARGET）"; }
  else
    cmake --build "$bdir" -j "$JOBS" >> "$logf" 2>&1 \
      || { dump_log "$logf"; die "$tag: cmake build 失败"; }
  fi
  cmake --install "$bdir" >> "$logf" 2>&1 \
    || { dump_log "$logf"; die "$tag: cmake install 失败"; }
  ok "$tag: 安装完成"
}

# ------------------------------------------------------------------
# 手工安装兜底
# 为什么需要：davs2 / xavs2 这类老项目，makefile 里往往没有 install 目标，
# 或者只把产物丢在当前目录。与其赌，不如自己拷 + 自己写 .pc，行为完全确定。
# ------------------------------------------------------------------
# gen_pc <名字> <版本> <描述> <Libs> <Cflags相对prefix的头目录>
gen_pc() {
  local name="$1" ver="$2" desc="$3" libs="$4" incdir="${5:-include}"
  local pcdir="$PREFIX/lib/pkgconfig"
  mkdir -p "$pcdir"
  cat > "$pcdir/$name.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/$incdir

Name: $name
Description: $desc
Version: $ver
Libs: -L\${libdir} $libs
Libs.private: $libs
Cflags: -I\${includedir}
EOF
  ok "生成 $pcdir/$name.pc"
}

# ------------------------------------------------------------------
# Android：把 .pc 里的 -lpthread / -ldl 摘掉
#
# bionic 没有独立的 libpthread.so / libdl.so —— pthread_* 与 dl* 的符号全在
# libc 里，链接 `-lpthread` 直接 "unable to find library -lpthread"。
# 而大量上游 .pc（uavs3d / uavs3e / srt / zimg …）在 Linux 上探测到 pthread 后
# 就无条件写进 Libs，跨到 Android 就全是雷。
#
# 影响面：FFmpeg 的 require_pkg_config 会用这些 flags 真链一次，链接失败后
# 只报一句 "xxx not found using pkg-config"，能力被静默关掉
# （run#12 android-arm64 的 uavs3d / uavs3e 就是）。所以必须在 configure 前清掉。
# ------------------------------------------------------------------
fix_android_pc_files() {
  [ "${TARGET_OS:-}" = "android" ] || return 0
  local pc n=0 hit
  for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
    [ -f "$pc" ] || continue
    hit=0
    if grep -q -- '-lpthread\|-ldl' "$pc"; then
      sed -i -E 's/[[:space:]]*-lpthread//g; s/[[:space:]]*-ldl//g' "$pc"
      hit=1
    fi
    # x265 的 .pc 不是手写的，而是 CMake 拿 CMAKE_CXX_IMPLICIT_LINK_LIBRARIES
    # 一项一项拼出来的（x265 3.4 source/CMakeLists.txt:696
    #   list(APPEND PLIBLIST "-l${LIB}")），而 NDK 的 clang 驱动把这个
    # `-l:libunwind.a` 原样塞进了那个列表 → 拼出 `-l-l:libunwind.a`。
    # GNU ld 只把它当「找名为 lib-l:libunwind.a 的库」，直接报
    #   ld: error: unable to find library -l-l:libunwind.a
    # 而 configure 会折叠成一句 `ERROR: x265 not found using pkg-config`，
    # 完全看不出真因（run#19 android-arm64/armv7 都是这么挂的）。
    # libunwind 本来就由 clang 驱动自动链接（正因为它出现在 implicit link
    # libs 里），所以整条删掉最安全；先删重复的，再删单份的。
    if grep -q -- '-l-l:libunwind' "$pc"; then
      sed -i -E 's/[[:space:]]*-l-l:libunwind\.a//g' "$pc"
      hit=1
    fi
    if grep -q -- '-l:libunwind' "$pc"; then
      sed -i -E 's/[[:space:]]*-l:libunwind\.a//g' "$pc"
      hit=1
    fi
    # NDK 里的 `libstdc++.so` / `libc++.so` 不是真库，而是指向 **动态** 运行库的
    # 兼容脚本（`INPUT(-lc++_shared)`）。任何 .pc 只要写了 `-lstdc++` 或 `-lc++`，
    # 最终产物就会多出一条 `NEEDED: libc++_shared.so` —— 单文件静态发布直接废掉。
    # zimg 的上游 zimg.pc.in 就是 `Libs.private: @STL_LIBS@`，默认 `-lstdc++`；
    # x265 的 CMake 会从 CMAKE_CXX_IMPLICIT_LINK_LIBRARIES 里捡出 `c++`。
    # 静态 C++ 运行库我们已经在 EXTRA_LIBS 里统一给了 `-lc++_static -lc++abi`，
    # 所以这里把这两条**裸**名字清掉即可（不能碰 -lc++_static / -lc++abi）。
    if grep -qE -- '(^|[[:space:]])-l(stdc\+\+|c\+\+)([[:space:]]|$)' "$pc"; then
      sed -i -E 's/(^|[[:space:]])-lstdc\+\+([[:space:]]|$)/\1\2/g; s/(^|[[:space:]])-lc\+\+([[:space:]]|$)/\1\2/g' "$pc"
      hit=1
    fi
    if [ "$hit" = "1" ]; then n=$((n + 1)); fi
  done
  if [ "$n" -gt 0 ]; then
    ok "android: 已清理 $n 个 .pc 里的 -lpthread/-ldl/-l:libunwind.a（bionic 里前两者在 libc，unwind 由驱动自带）"
  fi
  return 0
}

# install_static_lib <静态库路径> <目标名(不含lib前缀和.a后缀)>
install_static_lib() {
  local src="$1" name="$2"
  [ -f "$src" ] || die "找不到静态库：$src"
  mkdir -p "$PREFIX/lib"
  cp -f "$src" "$PREFIX/lib/lib${name}.a"
  ok "安装 lib/lib${name}.a"
}

# install_header <源文件> [目标子目录]
install_header() {
  local src="$1" sub="${2:-include}"
  [ -f "$src" ] || die "找不到头文件：$src"
  mkdir -p "$PREFIX/$sub"
  cp -f "$src" "$PREFIX/$sub/"
  ok "安装 $sub/$(basename "$src")"
}

# ------------------------------------------------------------------
# 严格文本替换（补丁的唯一手段）
#
# 为什么不用 patch(1)：
#   .diff 依赖上下文行和行号，上游稍微挪动一行就会 fuzz 或者 --forward 静默跳过，
#   留下一个"看起来打了其实没打"的构建产物。这里改成「锚点必须精确匹配 N 次」：
#   匹配数不对直接退出，绝不会产出半残状态。
#
# 用法： edit_exact <文件> <旧串> <新串> [期望匹配次数=1]
# ------------------------------------------------------------------
edit_exact() {
  local file="$1" old="$2" new="$3" want="${4:-1}"
  [ -f "$file" ] || die "edit_exact: 文件不存在 $file"
  python3 - "$file" "$old" "$new" "$want" <<'PY'
import sys
path, old, new, want = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
# newline='' 必须加：Windows 上的 Python 默认会把 LF 翻译成 CRLF，
# 整篇文件被改写后 configure 的 #!/bin/sh\r 会让 shell 直接报错。
with open(path, 'r', encoding='utf-8', errors='surrogateescape', newline='') as f:
    s = f.read()
n = s.count(old)
if n != want:
    sys.stderr.write(
        "\n[edit_exact] 锚点匹配 %d 次，期望 %d 次\n  文件: %s\n  锚点: %r\n" % (n, want, path, old[:200])
    )
    sys.exit(1)
with open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
    f.write(s.replace(old, new))
PY
  ok "替换成功 ($(basename "$file"))"
}

# ------------------------------------------------------------------
# 严格文本替换（自动适配 CRLF）
#
# edit_exact 要求锚点逐字节匹配，而 davs2 的源码是 **100% CRLF**：锚点里只要
# 写一个 \n 就永远匹配不上（run#14 踩过）。手工在 shell 字符串里敲 \r 又极易
# 出错、且看不出来。这里把锚点和替换文本都按文件自身的行尾风格归一化：
#   文件里 CRLF 占多数  -> 锚点/替换里的 \n 全部换成 \r\n
#   否则                -> 原样（LF）
# 这样补丁脚本里所有锚点都可以按"人类习惯的 LF"来写。
#
# 用法： edit_crlf <文件> <旧串> <新串> [期望匹配次数=1]
# ------------------------------------------------------------------
edit_crlf() {
  local file="$1" old="$2" new="$3" want="${4:-1}"
  [ -f "$file" ] || die "edit_crlf: 文件不存在 $file"
  python3 - "$file" "$old" "$new" "$want" <<'PY'
import sys
path, old, new, want = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(path, 'r', encoding='utf-8', errors='surrogateescape', newline='') as f:
    s = f.read()
nl = '\r\n' if s.count('\r\n') * 2 > s.count('\n') else '\n'
o = old.replace('\n', nl)
w = new.replace('\n', nl)
n = s.count(o)
if n != want:
    sys.stderr.write(
        "\n[edit_crlf] 锚点匹配 %d 次，期望 %d 次（行尾=%s）\n  文件: %s\n  锚点: %r\n"
        % (n, want, 'CRLF' if nl == '\r\n' else 'LF', path, o[:200])
    )
    sys.exit(1)
with open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
    f.write(s.replace(o, w))
PY
  ok "替换成功 ($(basename "$file"))"
}

# ------------------------------------------------------------------
# 校验：确认某个库确实装进了 prefix（防止 --enable-xxx 静默失效）
# ------------------------------------------------------------------
require_pc() {
  local pc="$1"
  if ! pkg-config --exists "$pc" 2>/dev/null; then
    [ -n "${CURRENT_LOGFILE:-}" ] && dump_log "$CURRENT_LOGFILE"
    die "pkg-config 找不到 $pc —— 该库没装成，或 .pc 路径不对"
  fi
  ok "pkg-config 已识别 $pc ($(pkg-config --modversion "$pc"))"
}

# ------------------------------------------------------------------
# 修复 .pc 里的版本号下限
# 场景：FFmpeg configure 写死了 "uavs3d >= 1.1.41"，而上游 version.sh 用
# git describe 生成的版本串可能只是 "1.1"。版本不达标时 configure 会直接拒绝，
# 但库本身的功能是够的（我们拉的就是最新 master）。这里只改声明，不动库。
# ------------------------------------------------------------------
pc_ensure_version() {
  local name="$1" minver="$2"
  local pc
  pc="$(pkg-config --variable=pcfiledir "$name" 2>/dev/null)/$name.pc"
  [ -f "$pc" ] || die "pc_ensure_version: 找不到 $name.pc"

  python3 - "$pc" "$name" "$minver" <<'PY'
import sys, re
path, name, minver = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8', errors='surrogateescape', newline='') as f:
    s = f.read()
m = re.search(r'^Version:\s*(\S+)', s, re.M)
cur = m.group(1) if m else "0"

def tup(v):
    out = []
    for p in re.split(r'[.\-+]', v):
        out.append(int(p) if p.isdigit() else 0)
    while len(out) < 4:
        out.append(0)
    return tuple(out[:4])

if tup(cur) < tup(minver):
    s = re.sub(r'^Version:.*$', 'Version: %s' % minver, s, count=1, flags=re.M)
    with open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
        f.write(s)
    print("[pc_ensure_version] %s: %s -> %s" % (name, cur, minver), file=sys.stderr)
else:
    print("[pc_ensure_version] %s: %s (已达标)" % (name, cur), file=sys.stderr)
PY
}
