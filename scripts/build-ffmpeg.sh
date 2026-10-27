#!/usr/bin/env bash
# ==============================================================================
# FFmpeg 本体构建
#
# 两个设计原则：
#   1) 所有外部库都按「pkg-config 里有才开」自动决定，不写死。
#      这样某个库编失败时，构建不会因为 --enable-xxx 找不到而整体崩掉，
#      而是那项能力缺失 —— 但会通过下面的断言把「缺了什么」喊出来。
#   2) configure 之后必须回读 config_components.h。
#      FFmpeg 的 --enable-xxx 找不到库时**不会报错**，只是把它关掉；
#      不检查的话产物看着正常，实际少一半能力。
# ==============================================================================

# 该 .pc 是否存在（供需要判断返回值的调用点使用）
_have_pc() {
  pkg-config --exists "$1" 2>/dev/null
}

# 复刻 FFmpeg require_pkg_config 的完整测试：pkg-config 取 flags + 真编真链。
#
# 为什么需要它：FFmpeg 的检测失败只会抛一句
#   ERROR: davs2 >= 1.6.0 not found using pkg-config
# 这一句什么信息都没有 —— 可能是 .pc 版本不达标、头文件没装到 Cflags 指的
# 位置、静态库里缺符号、缺 -lstdc++、甚至 pkg-config 自己报错。真实原因只
# 写在 ffbuild/config.log 里。这里在 configure 之前用**同样的参数**跑一遍，
# 失败时把编译器的原始 stderr 直接打进 CI 日志。
#
# probe_pc_link <pc 名> <版本约束> <头文件(可空格分隔)> <符号名>
probe_pc_link() {
  local pc="$1" ver="$2" hdrs="$3" func="$4"
  local td="$BLD/probe-$pc"
  rm -rf "$td"; mkdir -p "$td"

  local cflags libs
  if ! cflags="$(pkg-config --cflags --static "$pc" 2>"$td/pc.err")"; then
    warn "probe($pc): pkg-config --cflags --static 失败"
    sed -n '1,10p' "$td/pc.err" >&2 || true
    return 1
  fi
  if ! libs="$(pkg-config --libs --static "$pc" 2>>"$td/pc.err")"; then
    warn "probe($pc): pkg-config --libs --static 失败"
    sed -n '1,10p' "$td/pc.err" >&2 || true
    return 1
  fi
  printf '%s  probe(%s): cflags=[%s] libs=[%s]\n' "$C_CYN" "$pc" "$cflags" "$libs" >&2

  local h
  : > "$td/t.c"
  for h in $hdrs; do printf '#include <%s>\n' "$h" >> "$td/t.c"; done
  # 取地址强制产生符号引用，等价于 FFmpeg 的 check_func_headers。
  # 注意用 0 而不是 NULL —— 这里没有 <stddef.h>，用 NULL 会先炸在编译期，
  # 把真正的链接错误盖掉（第一版 probe 就是这么骗了自己一轮的）。
  printf 'int main(void){ return (void *)&%s == 0; }\n' "$func" >> "$td/t.c"

  local cc_bin="${CC:-cc}"
  # 这里就是要词分割，flags 必须拆成多个参数
  # shellcheck disable=SC2086
  if ! $cc_bin $cflags "$td/t.c" -o "$td/t" $libs ${EXTRA_LIBS:-} > "$td/cc.log" 2>&1; then
    warn "probe($pc): 真编真链失败（这就是 configure 里那句 not found 的真实原因）"
    printf '  cmd: %s %s t.c -o t %s %s\n' "$cc_bin" "$cflags" "$libs" "${EXTRA_LIBS:-}" >&2
    sed -n '1,30p' "$td/cc.log" >&2 || true
    return 1
  fi
  ok "probe($pc): pkg-config + 真编真链 通过"
  return 0
}

# 四个 AVS 库的「pkg-config + 真编真链」自测，供 build_everything 在
# AVS 阶段刚结束时就调用 —— 早 30 分钟发现缺符号，比 configure 末尾那句
# 误导性的 "not found using pkg-config" 有用得多。
probe_avs_pc_links() {
  local rc=0
  mkdir -p "$BLD"
  # `|| true` 是必须的：平台脚本带 set -e，探测失败正是我们想看见的，
  # 不该在这里就把脚本杀掉（那样连 dump_log 都来不及打）
  _have_pc davs2  && { probe_pc_link davs2  "1.6.0"  davs2.h             davs2_decoder_open || rc=1; }
  _have_pc xavs2  && { probe_pc_link xavs2  "1.3.0"  "stdint.h xavs2.h"  xavs2_api_get      || rc=1; }
  _have_pc uavs3d && { probe_pc_link uavs3d "1.1.41" uavs3d.h            uavs3d_decode      || rc=1; }
  _have_pc uavs3e && { probe_pc_link uavs3e ""       "uavs3e/uavs3e.h"   uavs3e_enc         || rc=1; }
  return "$rc"
}

# 扫 AVS 四个静态库里有没有 MSVC 的「依赖库指令」残留。
#
# 背景（run#17 / run#18 各踩一次，uavs3d 和 uavs3e 各一处）：
#   两者都把 `#pragma comment(lib, "pthreadVC2.lib")` 写在了 **非 Windows 分支**
#   （#else 之后），是上游的 copy-paste 事故。clang 会把这句编成目标文件里一个
#   叫 .linker-options 的段；段名本身就是字符串常量，所以直接 grep 归档文件
#   就能发现，不需要 objdump。
#   - GNU ld（linux / mingw）不认识这个段，当垃圾忽略 → 一路无事，所以从来没
#     在 linux/windows 上暴露过
#   - **NDK 的 lld 会照做**，于是任何链接该库的命令都报
#       ld: error: libuavs3d.a(uavs3d.c.o): unable to find library from
#                dependent library specifier: pthreadVC2.lib
#   - 而 FFmpeg configure 把这堆东西折叠成一句
#       ERROR: uavs3d >= 1.1.41 not found using pkg-config
#   一个 pthreadVC2 字样都看不到，排查成本极高。所以这里提前拦一道。
#
# 注意 probe_pc_link 抓不到这个坑（它今天两次都报了通过），别指望它。
scan_avs_deplib() {
  local lib f bad=0
  for lib in davs2 xavs2 uavs3d uavs3e; do
    f="$PREFIX/lib/lib$lib.a"
    [ -f "$f" ] || continue
    if grep -aq 'linker-options' "$f"; then
      warn "$(basename "$f") 里含 .linker-options 段：上游把 MSVC 的 #pragma comment(lib,…) 写进了非 Windows 分支"
      bad=1
    fi
  done
  if [ "$bad" = "1" ]; then
    warn "修法：在对应源码里删掉那行 #pragma comment（见 scripts/libs/avs.sh 里 uavs3d/uavs3e 两处 edit_exact）"
    if [ "${TARGET_OS:-}" = "android" ]; then
      die "lld 会按 .linker-options 去 -l pthreadVC2.lib，android 上必定链接失败，先修源码再来"
    fi
  fi
  return 0
}

# 只在该 .pc 存在时才追加 --enable-xxx
#
# 注意：这里**必须恒返回 0**。平台脚本都带 `set -euo pipefail`，
# 若在「找不到库」的分支 return 1，第一个缺库的点就会把整个脚本杀掉 ——
# 症状是只打出一条「跳过 --enable-libsvtav1」然后 exit 1，
# 后面的参数组装、configure 一个字都看不到（run#7 的 linux 就是这么挂的）。
# 需要判断成败的调用点请用 _have_pc，别依赖本函数的返回值。
_enable_if_pc() {
  local pc="$1" flag="$2"
  if _have_pc "$pc"; then
    FF_ARGS+=("$flag")
    return 0
  fi
  warn "跳过 $flag（pkg-config 找不到 $pc）"
  return 0
}

# 断言某个 CONFIG_xxx 在 configure 产出里为 1
assert_config() {
  local key="$1" desc="$2" hit=""
  local f
  for f in "$FF_DIR/config_components.h" "$FF_DIR/config.h"; do
    [ -f "$f" ] || continue
    if grep -qE "^#define ${key} 1$" "$f"; then hit="$f"; break; fi
  done
  [ -n "$hit" ] || die "断言失败：$desc（$key）没有被启用 —— configure 静默关掉了它，见 config.log"
  ok "断言通过：$desc"
}

build_ffmpeg() {
  dep_needed ffmpeg || return 0

  FF_DIR="$(fetch ffmpeg)"
  export FF_DIR

  # AVS3 编码器补丁必须在 configure 之前打 —— 否则 --enable-libuavs3e 是未知选项
  apply_ffmpeg_avs3_patch "$FF_DIR"

  FF_ARGS=(
    "--prefix=$PREFIX"
    --disable-doc
    --disable-debug
    --enable-static
    --disable-shared
    # 让 pkg-config 把 Libs.private 里的传递依赖也吐出来，
    # 否则静态链接会在最后一步报一堆 undefined reference
    --pkg-config-flags=--static
    --enable-gpl
    # OpenSSL 3.x 是 Apache-2.0，和 GPLv2 不兼容：FFmpeg 的 configure 碰到
    # "openssl >= 3.0.0" 会直接 die：
    #   ERROR: OpenSSL >=3.0.0 requires --enable-version3
    # 我们三平台都用自建的 OpenSSL 3.x，所以必须开 version3（= GPLv3）。
    # 这也是"完整版"路线上的必然选择：gyan.dev 的 full build 同样是 GPLv3。
    --enable-version3
    --enable-pic
    # 可复现构建：把构建路径信息压掉
    --disable-stripping
  )

  # ---------------- AVS 四件套 ----------------
  _enable_if_pc davs2   --enable-libdavs2
  _enable_if_pc xavs2   --enable-libxavs2
  _enable_if_pc uavs3d  --enable-libuavs3d
  _enable_if_pc uavs3e  --enable-libuavs3e

  # ---------------- 视频 ----------------
  _enable_if_pc x264    --enable-libx264
  _enable_if_pc x265    --enable-libx265
  _enable_if_pc dav1d   --enable-libdav1d
  _enable_if_pc vpx     --enable-libvpx
  _enable_if_pc SvtAv1Enc --enable-libsvtav1
  _enable_if_pc aom     --enable-libaom
  _enable_if_pc libwebp --enable-libwebp

  # ---------------- 音频 ----------------
  _enable_if_pc lame    --enable-libmp3lame
  _enable_if_pc vorbis  --enable-libvorbis
  _enable_if_pc opus    --enable-libopus

  # ---------------- 字幕 / 图像 / 缩放 ----------------
  _enable_if_pc libass   --enable-libass
  _enable_if_pc freetype2 --enable-libfreetype
  _enable_if_pc fribidi  --enable-libfribidi
  _enable_if_pc harfbuzz --enable-libharfbuzz
  _enable_if_pc zimg     --enable-libzimg
  # fontconfig：drawtext / subtitles 的字体选择。Windows 上我们没编它
  # （libass 走 directwrite），所以只在其它平台尝试开启。
  if [ "${TARGET_OS:-}" != "windows" ]; then
    _enable_if_pc fontconfig --enable-libfontconfig
  fi

  # ---------------- 网络 ----------------
  _enable_if_pc srt      --enable-libsrt
  _enable_if_pc openssl  --enable-openssl

  # ---------------- 平台专属 ----------------
  if [ "${TARGET_OS:-}" = "windows" ]; then
    # 硬件编码只装头文件，无运行库依赖；没装到就自动跳过。
    # 注意不要写 --enable-ffnvcodec：那不是文档化的开关，
    # nvenc 的依赖里已经含 ffnvcodec，会自动带上。
    # 注意不能写 `_enable_if_pc ... && FF_ARGS+=(...)`：_enable_if_pc 现在恒返回 0，
    # 那样 --enable-nvdec 会被无条件加上。用 _have_pc 显式判断。
    if _have_pc ffnvcodec; then
      FF_ARGS+=(--enable-nvenc --enable-nvdec)
    else
      warn "跳过 --enable-nvenc（pkg-config 找不到 ffnvcodec）"
    fi
    _enable_if_pc libvpl --enable-libvpl
    # AMF 没有 .pc，只能看头文件
    if [ -d "$PREFIX/include/AMF" ]; then
      FF_ARGS+=(--enable-amf)
    else
      warn "跳过 --enable-amf（$PREFIX/include/AMF 不存在）"
    fi
  fi

  if [ -n "${FF_EXTRA_ARGS:-}" ]; then
    # FF_EXTRA_ARGS 是**空格分隔的字符串**，不是数组。
    # 原因：bash 无法导出数组，而平台脚本需要把它传给被 source 的函数；
    # 一旦某处写成了数组，这里读到的就只剩第一个元素（静默丢参数）。
    read -r -a _ff_extra <<< "${FF_EXTRA_ARGS}"
    FF_ARGS+=("${_ff_extra[@]}")
  fi
  # 静态链接时，C++ 库（davs2/xavs2/zimg）的 libstdc++ 不会被 pkg-config 带出来，
  # 平台脚本通过 EXTRA_LIBS 补；openssl 在 mingw 上还要 ws2_32/crypt32 这类系统库
  if [ -n "${EXTRA_LIBS:-}" ]; then
    FF_ARGS+=("--extra-libs=$EXTRA_LIBS")
  fi
  if [ -n "${EXTRA_LDFLAGS:-}" ]; then
    FF_ARGS+=("--extra-ldflags=$EXTRA_LDFLAGS")
  fi
  if [ -n "${EXTRA_CFLAGS:-}" ]; then
    FF_ARGS+=("--extra-cflags=$EXTRA_CFLAGS")
  fi

  local logf="$LOGS/ffmpeg-configure.log"
  CURRENT_LOGFILE="$logf"

  # 把最终参数串打出来：configure 失败时这是第一手证据
  log "FF_ARGS(${#FF_ARGS[@]} 项): ${FF_ARGS[*]}"

  # configure 之前先自测四个 AVS 库 —— 它们的 require_pkg_config 报错信息
  # 等于没有信息，与其等 configure 抛一句 not found，不如现在就把真实原因喊出来
  # 兜底再测一次（正常情况下 build_everything 在 AVS 阶段已经测过了；
  # 这里保留是因为单独跑 build_ffmpeg 时也要有防护）
  fix_android_pc_files
  probe_avs_pc_links || true

  log "configure FFmpeg ${FFMPEG_VERSION} (${TARGET_OS}/${TARGET_ARCH})"
  (
    cd "$FF_DIR"
    ./configure "${FF_ARGS[@]}"
  ) > "$logf" 2>&1 || {
    # require_pkg_config / check_lib 的真实原因只写在 ffbuild/config.log 最后的段落里，
    # 而 configure 自己只抛一句 "ERROR: xxx not found using pkg-config"。
    # 不把这段挖出来，等于每次都只能靠猜。
    local cfglog="$FF_DIR/ffbuild/config.log"
    if [ -f "$cfglog" ]; then
      warn "----- config.log 尾部（失败的那次检测就在这里）-----"
      tail -n 45 "$cfglog" >&2 || true
      warn "----- config.log 结束 -----"
    fi
    dump_log "$logf"
    die "FFmpeg configure 失败"
  }

  # ---------------- 防静默失败断言 ----------------
  # 这四项是本项目的存在理由，任何一个没开成，产物就没有意义
  assert_config CONFIG_LIBDAVS2_DECODER   "AVS2 解码 (libdavs2)"
  assert_config CONFIG_LIBUAVS3D_DECODER  "AVS3 解码 (libuavs3d)"
  assert_config CONFIG_LIBUAVS3E_ENCODER  "AVS3 编码 (libuavs3e)"
  assert_config CONFIG_LIBXAVS2_ENCODER   "AVS2 编码 (libxavs2)"

  if pkg-config --exists sdl2 2>/dev/null; then
    ok "SDL2 就位，ffplay 会一起编"
  fi

  # 记下 capacity 里有没有 ffmpeg/ffprobe 两个程序
  for p in ffmpeg ffprobe; do
    grep -q "^CONFIG_$(echo "$p" | tr a-z A-Z)=yes" "$FF_DIR/ffbuild/config.mak" \
      || die "$p 未被启用（config.mak 里没有 CONFIG_$(echo "$p" | tr a-z A-Z)=yes）"
  done

  log "build FFmpeg"
  local blogf="$LOGS/ffmpeg-build.log"
  ( cd "$FF_DIR" && make -j"$JOBS" ) > "$blogf" 2>&1 \
    || { dump_log "$blogf"; die "FFmpeg 编译失败"; }

  ( cd "$FF_DIR" && make install ) >> "$blogf" 2>&1 \
    || { dump_log "$blogf"; die "FFmpeg 安装失败"; }

  ok "FFmpeg 构建完成"

  # 产物存在性检查：configure 说启用了，不代表真的落地了
  local miss=""
  for p in ffmpeg ffprobe; do
    [ -f "$PREFIX/bin/$p${EXE:-}" ] || miss="$miss $p"
  done
  [ -z "$miss" ] || die "构建结束但缺少可执行文件：$miss"
  ok "产物齐备：ffmpeg${EXE:-} ffprobe${EXE:-}"

  ( "$PREFIX/bin/ffmpeg${EXE:-}" -hide_banner -version | head -3 ) >&2 || true
}
