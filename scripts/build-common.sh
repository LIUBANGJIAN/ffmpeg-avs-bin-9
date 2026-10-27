#!/usr/bin/env bash
# ==============================================================================
# 三平台共用的构建流程
#
# 顺序不是随便排的，依赖关系如下（箭头 = 先于）：
#   zlib ──> freetype ──> fontconfig ──> libass
#   openssl ──> srt
#   ogg ──> vorbis
#   freetype ──> harfbuzz ──> libass
#   AVS 四件套 ──> FFmpeg
# 所以：zlib / openssl 最先行，FFmpeg 最后行。
# ==============================================================================

build_everything() {
  log "===== 目标：${TARGET_OS}/${TARGET_ARCH}  prefix=$PREFIX ====="

  # 1) 基础库（别人都依赖它）
  build_zlib
  build_openssl

  # 2) AVS 四件套（本项目核心，尽早暴露问题）
  build_avs_all

  # 2.5) AVS 四件套刚装完就做一次「pkg-config + 真编真链」自测。
  #      为什么要提前：这一步等价于 FFmpeg configure 里的 require_pkg_config，
  #      而它排在第 6 步（所有依赖之后）。若某个库静态链接缺符号，
  #      configure 会报一句没头没脑的 "xxx not found using pkg-config"，
  #      而且还要等 30 分钟才看到。挪到这里，3 分钟内就能定位。
  fix_android_pc_files
  # 先扫 MSVC 残留的「依赖库指令」，再自测链接：
  # 这类残留在 linux 上完全无害，只有 NDK 的 lld 会当真，
  # 而 configure 只会吐一句 "xxx not found using pkg-config"。
  scan_avs_deplib
  probe_avs_pc_links || warn "AVS 库链接自测未全部通过，FFmpeg configure 大概率会失败（原因见上）"

  # 3) 视频
  build_video_all

  # 4) 音频
  build_audio_all

  # 5) 字幕链 / 网络 / 平台专属
  build_freetype
  build_expat
  build_fontconfig
  build_fribidi
  build_harfbuzz
  build_libass
  build_zimg
  build_srt
  build_sdl2

  # 6) 本体
  build_ffmpeg
}

# ------------------------------------------------------------------------------
# 打包
#
# 只用 zip：MSYS2 / Alpine / ubuntu 三处都能一条命令装到 zip，
# 而 7z/tar.xz 在不同 runner 上的可用性不一致。
# ------------------------------------------------------------------------------
package_output() {
  local outdir="$ROOT/out"
  local name="$1"
  local stage="$BLD/pkg-$name"
  mkdir -p "$outdir"
  rm -rf "$stage"; mkdir -p "$stage"

  local bins=(ffmpeg ffprobe)
  [ "${TARGET_OS:-}" = "windows" ] && bins+=(ffplay)

  local b
  for b in "${bins[@]}"; do
    local f="$PREFIX/bin/$b${EXE:-}"
    [ -f "$f" ] || die "打包失败：找不到 $f"
    cp -f "$f" "$stage/"
    # strip 在这里做，而不是编译期（--disable-stripping），
    # 这样编译失败时还能拿到带符号的二进制来定位
    if [ -n "${STRIP:-}" ] && [ "${TARGET_OS:-}" != "windows" ]; then
      "$STRIP" "$stage/$b" 2>/dev/null || warn "strip 跳过：$b"
    fi
  done

  # 许可证与说明必须随产物走 —— GPL 二进制分发的硬要求。
  # 协议全文不自己抄：FFmpeg 源码树里就带着 COPYING.GPLv2 / COPYING.LGPLv2.1，
  # 直接拷过来，保证与上游逐字一致。
  #
  # ⚠️ 协议版本必须跟**实际配置**一致，不能凭印象写死。
  # 我们为了自建 OpenSSL 3.x（Apache-2.0，与 GPLv2 不兼容）开了 --enable-version3，
  # 产物因此是 **GPLv3 or later**；此时只附 GPLv2 文本是错的。
  local _v3=0 _a _gpl _lgpl _tag
  for _a in ${FF_ARGS[@]+"${FF_ARGS[@]}"}; do
    [ "$_a" = "--enable-version3" ] && _v3=1
  done
  cp -f "$ROOT/README.md" "$stage/" 2>/dev/null || true
  if [ "$_v3" = "1" ]; then
    _gpl="COPYING.GPLv3"; _lgpl="COPYING.LGPLv3"; _tag="GPLv3（--enable-version3）"
  else
    _gpl="COPYING.GPLv2"; _lgpl="COPYING.LGPLv2.1"; _tag="GPLv2"
  fi
  if [ -n "${FF_DIR:-}" ] && [ -f "$FF_DIR/$_gpl" ]; then
    cp -f "$FF_DIR/$_gpl" "$stage/LICENSE.${_gpl#COPYING.}.txt"
    [ -f "$FF_DIR/$_lgpl" ] && cp -f "$FF_DIR/$_lgpl" "$stage/LICENSE.${_lgpl#COPYING.}.txt"
    # 两版一并发出去也不算错，只是多了个文件；真正要对的是「主协议」那张。
    cp -f "$FF_DIR/COPYING.GPLv2"   "$stage/LICENSE.GPLv2.txt"   2>/dev/null || true
    cp -f "$FF_DIR/COPYING.LGPLv2.1" "$stage/LICENSE.LGPLv2.1.txt" 2>/dev/null || true
    ok "已随包附带 $_tag 协议全文"
  else
    warn "没找到 FFmpeg 源码里的 $_gpl —— 分发包会缺协议全文，发布前必须补上"
  fi

  local zip="$outdir/$name.zip"
  rm -f "$zip"
  ( cd "$stage" && zip -q -r "$zip" . ) || die "打包失败：$zip"
  ok "产物：$zip ($(du -h "$zip" | cut -f1))"
}

# ------------------------------------------------------------------------------
# 冒烟测试 —— 只证明「能跑」是不够的，必须证明「AVS 真的在」
# 这里是本地/CI 通用的断言，CI 里还会额外用真实素材再跑一遍
# ------------------------------------------------------------------------------
smoke_test() {
  local bin="$PREFIX/bin/ffmpeg${EXE:-}"
  [ -x "$bin" ] || die "冒烟测试：找不到 $bin"

  log "冒烟测试：AVS 编解码器是否就位"
  local caps
  caps="$("$bin" -hide_banner -codecs 2>/dev/null)"

  # 这里**绝不能**锚定 `D.V.L.` 这类标志位列。一旦 avs3 有了编码器，
  # 同一行的标志就会从 `D.V.L.`（只有解码）变成 `DEV.L.`（解+编），
  # 锚死列宽会把「明明四个库全都在」的构建误判成失败 —— run#19 的 windows
  # 就是这么挂的（linux 那次同轮全绿）。要证明的只有一件事：
  # avs2 / avs3 这两行里分别出现了 libdavs2、libxavs2、libuavs3d、libuavs3e。
  echo "$caps" | grep -E '[[:space:]]avs2[[:space:]]' | grep -q 'libdavs2' \
    || die "冒烟失败：avs2 解码未链接 libdavs2"
  echo "$caps" | grep -E '[[:space:]]avs2[[:space:]]' | grep -q 'libxavs2' \
    || die "冒烟失败：avs2 编码未链接 libxavs2"
  echo "$caps" | grep -E '[[:space:]]avs3[[:space:]]' | grep -q 'libuavs3d' \
    || die "冒烟失败：avs3 解码未链接 libuavs3d"
  echo "$caps" | grep -E '[[:space:]]avs3[[:space:]]' | grep -q 'libuavs3e' \
    || die "冒烟失败：avs3 编码未链接 libuavs3e（补丁没生效？）"

  ok "AVS2/AVS3 编解码器全部就位"

  log "冒烟测试：AVS3 编码真跑一次"
  local tmp="$BLD/smoke-$$"
  mkdir -p "$tmp"
  # 这里用 info 而不是 error：libuavs3e 的封装在 init/encode 两侧都打了进度日志，
  # 万一再出现段错误（run#21 linux），至少能从日志看出死在 create 前还是 encode 里。
  "$bin" -hide_banner -loglevel info -y \
    -f lavfi -i "testsrc2=size=320x240:rate=25:duration=1" \
    -c:v libuavs3e -qp 32 "$tmp/t.avs3" \
    || die "冒烟失败：libuavs3e 编码报错"
  [ -s "$tmp/t.avs3" ] || die "冒烟失败：编码输出为空"
  ok "AVS3 编码产出 $(du -h "$tmp/t.avs3" | cut -f1)"

  log "冒烟测试：解回来验证帧数"
  # 这里**不能**写成 `"$bin" ... 2>&1 | wc -l`：段错误时管道把一切都吞掉，
  # 日志里只剩一句 "Process completed with exit code 139"，连是哪个命令挂了
  # 都看不出来（run#22 linux 就是这样白烧了一轮）。改成落盘 + 显式查退出码。
  local dlog="$tmp/dec.log" rc=0
  "$bin" -hide_banner -loglevel error -y -i "$tmp/t.avs3" -f null - >"$dlog" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "AVS3 解码退出码 $rc（139 = SIGSEGV，134 = SIGABRT）—— 解码端输出如下："
    tail -n 30 "$dlog" >&2 || true
    die "冒烟失败：AVS3 解码失败"
  fi
  ok "AVS3 解码无异常（stderr 行数 $(wc -l < "$dlog")）"

  rm -rf "$tmp"
}

# ------------------------------------------------------------------------------
# 交叉编译产物的结构验证
#
# 为什么不能跑 smoke_test：ARM 二进制在 x86 runner 上根本执行不了，
# 硬要跑只会得到 "Exec format error"，看起来像构建失败。
# 这里改用静态取证：
#   - ELF 架构对不对（防止 --arch 传错，产出一个 x86 二进制冒充 ARM）
#   - NEEDED 里有没有混进非 bionic 的库（跨平台 pkg-config 污染就是这样暴露的）
#   - AVS 相关符号有没有真的链进去
# ------------------------------------------------------------------------------
verify_cross_binary() {
  local bin="$1" arch="$2"
  [ -f "$bin" ] || die "结构验证：找不到 $bin"

  local info; info="$(file -b "$bin")"
  echo "  file: $info" >&2
  case "$arch" in
    arm)     echo "$info" | grep -qE 'ELF 32-bit LSB.*ARM'   || die "结构验证：期望 32 位 ARM，实际是 $info" ;;
    aarch64) echo "$info" | grep -qE 'ELF 64-bit LSB.*aarch64' || die "结构验证：期望 AArch64，实际是 $info" ;;
  esac
  ok "ELF 架构匹配（$arch）"

  local need
  need="$(readelf -d "$bin" 2>/dev/null | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | sort -u || true)"
  echo "  NEEDED: ${need:-<无，全静态>}" >&2
  local l
  for l in $need; do
    case "$l" in
      libc.so|libm.so|libdl.so|liblog.so|libz.so|libstdc++.so|libandroid.so)
        ;;
      *) die "结构验证：出现意外的动态依赖 $l —— 很可能链接到了主机（x86）的库" ;;
    esac
  done
  ok "动态依赖仅限 bionic 系统库"

  # 符号/字符串取证：补丁没生效时这里会立刻暴露
  strings "$bin" | grep -q 'libuavs3e' || die "结构验证：二进制里找不到 libuavs3e（AVS3 编码器没编进去）"
  strings "$bin" | grep -q 'libdavs2'  || die "结构验证：二进制里找不到 libdavs2（AVS2 解码器没编进去）"
  ok "AVS2 解码 / AVS3 编码符号都在"

  local size; size="$(du -h "$bin" | cut -f1)"
  ok "产物大小 $size"
}
