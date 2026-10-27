#!/usr/bin/env bash
# ==============================================================================
# 音频编解码依赖
#   lame / ogg / vorbis / opus
#
# 为什么没有 fdk-aac：
#   fdk-aac 的许可与 GPL 不兼容，必须 --enable-nonfree 才能编进 FFmpeg，
#   而 nonfree 产物不可再分发。本项目选 GPL v2，所以 AAC 用 FFmpeg 自带编码器。
#   若你要 fdk-aac，把 env.sh 里 LICENSE_GPL 改 0 并放开 --enable-nonfree，
#   但那份产物只能自用。
# ==============================================================================

# ------------------------------------------------------------------------------
# lame —— MP3 编码
# 发行版 tarball 自带 configure，可直接 autotools_build
# ------------------------------------------------------------------------------
build_lame() {
  dep_needed lame || return 0
  local dir; dir="$(fetch lame)"

  autotools_build "$dir" lame \
    --disable-shared --enable-static \
    --disable-frontend \
    --disable-dependency-tracking

  # lame 3.100 **根本不提供 .pc**（上游从 3.98 到现在都没加过）。
  # v2/openssl 那样「装了但 pkg-config 找不到」会让 FFmpeg 的
  # --enable-libmp3lame 静默失效，所以这里自己补一个。
  # -lm 不能省：libmp3lame 用到 math 函数，静态链接时没人替它带。
  if ! pkg-config --exists lame 2>/dev/null; then
    gen_pc lame 3.100 "LAME MP3 encoder" "-lmp3lame -lm"
  fi

  require_pc lame
}

# ------------------------------------------------------------------------------
# libogg —— 容器（vorbis / opus 的基础）
# GitHub 归档没有预置 configure，ensure_configure 会自动跑 autoreconf
# ------------------------------------------------------------------------------
build_ogg() {
  dep_needed ogg || return 0
  local dir; dir="$(fetch ogg)"

  autotools_build "$dir" ogg \
    --disable-shared --enable-static \
    --disable-dependency-tracking

  require_pc ogg
}

# ------------------------------------------------------------------------------
# libvorbis —— Vorbis 编解码，依赖 libogg
# ------------------------------------------------------------------------------
build_vorbis() {
  dep_needed vorbis || return 0
  local dir; dir="$(fetch vorbis)"

  # vorbis 通过 pkg-config 找 ogg；缺了会在 configure 阶段报错
  require_pc ogg

  autotools_build "$dir" vorbis \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    --disable-examples

  require_pc vorbis
}

# ------------------------------------------------------------------------------
# libopus —— Opus 编解码
# ------------------------------------------------------------------------------
build_opus() {
  dep_needed opus || return 0
  local dir; dir="$(fetch opus)"

  autotools_build "$dir" opus \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    --disable-extra-programs \
    --disable-doc

  require_pc opus
}

# ------------------------------------------------------------------------------
build_audio_all() {
  build_lame
  build_ogg
  build_vorbis
  build_opus
}
