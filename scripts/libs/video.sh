#!/usr/bin/env bash
# ==============================================================================
# 视频编解码依赖
#   x264 / x265 / dav1d / libvpx        —— 默认构建
#   svtav1 / aom / webp                 —— 可选（ENABLE_xxx=1）
#
# 调用方需已 export：CC CXX AR RANLIB STRIP HOST TARGET_OS TARGET_ARCH
# ==============================================================================

# ------------------------------------------------------------------------------
# x264 —— H.264 编码（GPL v2）
# configure 是自研的，不是 autotools，但恰好接受 --prefix/--host/--enable-static，
# 所以能复用 autotools_build。
# ------------------------------------------------------------------------------
build_x264() {
  dep_needed x264 || return 0
  local dir; dir="$(fetch x264)"

  autotools_build "$dir" x264 \
    --enable-pic \
    --enable-strip \
    --disable-cli \
    --disable-opencl \
    --disable-avs \
    --disable-swscale \
    --disable-lavf \
    --disable-ffms \
    --disable-gpac \
    --disable-lsmash

  require_pc x264
}

# ------------------------------------------------------------------------------
# x265 —— HEVC 编码（GPL v2）
#
# 注意位深：x265 一个构建只出**一个**位深（8 或 10），和 davs2 是同一类限制。
#   -DHIGH_BIT_DEPTH=ON  -> 10bit only
#   默认（不加）          -> 8bit main
# gyan 那种「一个库同时支持 8/10/12bit」是 make multi-lib 把三份对象合并，
# 依赖 x265 自己的 multilib.mak，跨平台可用性差，v1 不做。
# 这里选 8bit main：覆盖面最广；10bit HEVC 需要另编一份，README 里已注明。
# ------------------------------------------------------------------------------
build_x265() {
  dep_needed x265 || return 0
  local dir; dir="$(fetch x265)"

  # 源码在 source/ 子目录，顶层没有 CMakeLists
  # ARM 上关汇编：x265 的 ARM 汇编依赖 gas-preprocessor，交叉编译环境里没有，
  # 开了必然失败。纯 C 慢一些，但能出产物（与 AVS 那几个库的处理保持一致）。
  local asm_opt=(-DENABLE_ASSEMBLY=ON)
  case "${TARGET_ARCH:-x86_64}" in
    arm*|aarch64) asm_opt=(-DENABLE_ASSEMBLY=OFF) ;;
  esac

  # 下面两处都是 CMake 4.x 才爆的问题（Alpine 的 cmake 3.29 全程无碍），
  # 所以 Windows / Android 会挂、Linux 反而好 —— 别被这个现象带偏。
  #
  # (1) 真正让 configure 失败的是这句：
  #       CMake Error ... The OLD behavior for policy CMP0054 has been removed ...
  #     对应 source/CMakeLists.txt 的 `cmake_policy(SET CMP0054 OLD)`：
  #     CMake 4 已经彻底删掉 CMP0054 的 OLD 行为，设 OLD 变成硬错误。
  #     改成 NEW（4.x 唯一允许的取值）；x265 里的 if() 都是
  #     `if("${var}" STREQUAL "...")` 这类写法，NEW 下语义不变。
  #     同一个文件开头还有 `cmake_policy(SET CMP0025 OLD)`（把 Apple Clang
  #     当成普通 Clang 报），CMake 4 同样不再接受 OLD —— 一并改 NEW；
  #     我们三个平台都没有 Apple 编译器，这条改了没有任何副作用。
  edit_exact "$dir/source/CMakeLists.txt" \
    'cmake_policy(SET CMP0025 OLD) # report Apple'"'"'s Clang as just Clang' \
    'cmake_policy(SET CMP0025 NEW) # CMake 4 已移除 OLD 行为'
  edit_exact "$dir/source/CMakeLists.txt" \
    'cmake_policy(SET CMP0054 OLD) # Only interpret if() arguments as variables or keywords when unquoted' \
    'cmake_policy(SET CMP0054 NEW) # CMake 4 已移除 OLD 行为'

  # (2) 顺手补的隐患（不是本次的报错原因，但同样是「奇数实参」问题）：
  #       set_source_files_properties(version.cpp PROPERTIES COMPILE_FLAGS ${VERSION_FLAGS})
  #     VERSION_FLAGS 没加引号，里面用空格拼了两段（-DX265_VERSION + -DENABLE_ASSEMBLY=1），
  #     展开成 3 个实参，而 PROPERTIES 之后要求「属性/值」成对。
  #     CMake 3.x 容忍多出来的尾巴，4.x 的解析更严格，加引号既避险又不改行为。
  edit_exact "$dir/source/common/CMakeLists.txt" \
    'set_source_files_properties(version.cpp PROPERTIES COMPILE_FLAGS ${VERSION_FLAGS})' \
    'set_source_files_properties(version.cpp PROPERTIES COMPILE_FLAGS "${VERSION_FLAGS}")'

  cmake_build "$dir/source" x265 \
    -DENABLE_SHARED=OFF \
    -DENABLE_CLI=OFF \
    -DENABLE_PIC=ON \
    "${asm_opt[@]}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc x265
}

# ------------------------------------------------------------------------------
# dav1d —— AV1 解码（BSD，纯汇编优化，比 aom 快得多）
# 只有 meson 构建。
# ------------------------------------------------------------------------------
build_dav1d() {
  dep_needed dav1d || return 0
  local dir; dir="$(fetch dav1d)"

  meson_build "$dir" dav1d \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false

  require_pc dav1d
}

# ------------------------------------------------------------------------------
# libvpx —— VP8/VP9 编解码
# configure 用的是 --target= 而不是 --host=，且不接受 --enable-static 那套，
# 所以必须走 custom_configure。
# ------------------------------------------------------------------------------
vpx_target() {
  case "${TARGET_OS:-linux}/${TARGET_ARCH:-x86_64}" in
    windows/x86_64)        echo "x86_64-win64-gcc" ;;
    linux/x86_64)          echo "x86_64-linux-gcc" ;;
    android/armv7*|android/arm) echo "armv7-android-gcc" ;;
    android/aarch64)       echo "arm64-android-gcc" ;;
    *) die "libvpx: 未支持的 target ${TARGET_OS:-?}/${TARGET_ARCH:-?}" ;;
  esac
}

build_libvpx() {
  dep_needed libvpx || return 0
  local dir; dir="$(fetch libvpx)"

  local args=(
    "--prefix=$PREFIX"
    "--target=$(vpx_target)"
    --disable-shared --enable-static
    --disable-examples --disable-tools --disable-docs --disable-unit-tests
    --enable-vp9-highbitdepth
    --enable-pic
  )
  # Android：libvpx 1.15 已经不认 --sdk-path（那是 1.9~1.11 的老写法，
  # 现在传会直接 "Unknown option"）。它对 android 目标的策略变成了
  # 「standalone NDK toolchain」：build/make/configure.sh 里写着
  #   android*) echo "Assuming standalone build with NDK toolchain."
  # 也就是完全信任外部传进来的工具链 —— build-android.sh 已经导出了
  # CC/CXX/AR/RANLIB/STRIP/NM，但**没有 AS 和 LD**，这两个必须在这里补：
  #
  #   AS：arm 汇编（vpx_dsp/arm/*.asm → ads2gas.pl → .S）是用 $(AS) 编的
  #       （build/make/Makefile: `$(AS) $(ASFLAGS) -o $@ $<`）。
  #       configure 里 AS 默认是 ${CROSS}as，CROSS 为空 ⇒ 宿主的 x86_64 GNU as，
  #       它不认识 AArch64 指令。指成 clang 之后，configure.sh 的 android 分支
  #       会命中 `case "$AS" in *clang) add_asflags -c`（不加 -c 会去链接）。
  #   LD：默认 LD=${CROSS}${link_with_cc} ⇒ 宿主 gcc，拿它链 AArch64 目标文件
  #       会失败，而 configure 的 check_lib/check_header 全是「失败就静默降级」，
  #       结果就是编出来一个偷偷关掉全部汇编的 libvpx —— 不报错，但慢一半。
  local _lvp_as_old="" _lvp_ld_old=""
  if [ "${TARGET_OS:-}" = "android" ]; then
    [ -n "${ANDROID_NDK_HOME:-}" ] || die "libvpx(android): 缺少 ANDROID_NDK_HOME"
    [ -n "${CC:-}" ] || die "libvpx(android): CC 未导出，无法推导 AS/LD"
    _lvp_as_old="${AS:-}"
    _lvp_ld_old="${LD:-}"
    export AS="$CC"
    export LD="$CC"
  fi

  custom_configure "$dir" libvpx configure "${args[@]}"

  # 恢复环境，别把 android 的 AS/LD 泄漏给后面的库
  if [ "${TARGET_OS:-}" = "android" ]; then
    if [ -n "$_lvp_as_old" ]; then export AS="$_lvp_as_old"; else unset AS; fi
    if [ -n "$_lvp_ld_old" ]; then export LD="$_lvp_ld_old"; else unset LD; fi
  fi
  require_pc vpx
}

# ------------------------------------------------------------------------------
# SVT-AV1 —— AV1 编码（可选）
# ------------------------------------------------------------------------------
build_svtav1() {
  dep_needed svtav1 || return 0
  local dir; dir="$(fetch svtav1)"

  cmake_build "$dir" svtav1 \
    -DBUILD_APPS=OFF \
    -DBUILD_DEC=ON \
    -DBUILD_ENC=ON \
    -DCOMPILE_10BIT=1 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc SvtAv1Enc
}

# ------------------------------------------------------------------------------
# aom —— AV1 编解码（可选）
# ------------------------------------------------------------------------------
build_aom() {
  dep_needed aom || return 0
  local dir; dir="$(fetch aom)"

  local extra=()
  case "${TARGET_ARCH:-x86_64}" in
    arm*|aarch64) extra+=(-DAOM_TARGET_CPU=arm64) ;;
    *)            extra+=(-DAOM_TARGET_CPU=x86_64) ;;
  esac

  cmake_build "$dir" aom \
    -DENABLE_CCACHE=0 \
    -DENABLE_TESTS=0 \
    -DENABLE_EXAMPLES=0 \
    -DENABLE_TOOLS=0 \
    -DENABLE_DOCS=0 \
    -DCONFIG_AV1_HIGHBITDEPTH=1 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "${extra[@]}"

  require_pc aom
}

# ------------------------------------------------------------------------------
# libwebp —— WebP 编解码（可选）
# ------------------------------------------------------------------------------
build_webp() {
  dep_needed webp || return 0
  local dir; dir="$(fetch webp)"

  autotools_build "$dir" webp \
    --disable-shared --enable-static \
    --disable-everything \
    --enable-libwebpdecoder \
    --enable-libwebpdemux \
    --enable-libwebpmux

  require_pc libwebp
}

# ------------------------------------------------------------------------------
build_video_all() {
  build_x264
  build_x265
  build_dav1d
  build_libvpx
  build_svtav1
  build_aom
  build_webp
}
