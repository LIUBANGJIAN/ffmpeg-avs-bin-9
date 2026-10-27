#!/usr/bin/env bash
# ==============================================================================
# 给 FFmpeg 9.x 补上 libuavs3e（AVS3 编码器）
#
# 为什么必须自己打：libuavs3e 从未进入 FFmpeg 主线。9.0.2 的 EXTERNAL_LIBRARY_LIST
# 里只有 libdavs2 / libuavs3d / libxavs / libxavs2，一个 uavs3e 字样都没有。
#
# 为什么只有 5 处接线：
#   - matroska.c 的 V_AVS2 / V_AVS3 标签早已自带（旧补丁那两行多余）
#   - allcodecs.c 里没有 REGISTER_* 宏，注册表由 configure 生成的
#     codec_list.c 决定。configure 是这么取编码器清单的：
#         ENCODER_LIST=$(find_things_extern encoder FFCodec libavcodec/allcodecs.c)
#     也就是说 allcodecs.c 里那行 extern 是**清单的唯一来源**，删掉它就等于
#     编码器不存在 —— 它不是装饰，是必需项。
#
# 锚点全部来自 n9.0.2 原文，用 edit_exact 严格匹配：锚点漂移会立刻失败，
# 不会出现"看起来打了补丁其实没打"的沉默故障。
# ==============================================================================

apply_ffmpeg_avs3_patch() {
  local dir="$1"
  [ -d "$dir" ] || die "apply_ffmpeg_avs3_patch: 目录不存在 $dir"

  # ---- 版本护栏：这套锚点在 9.0.2 上逐个核对过（6.1.6 的旧仓库另有分支）----
  # 6.1 之后 AVCodec 字段已全面搬进 .p.*，libuavs3e.c 用的正是新写法，
  # 所以 6.1 / 7.x / 8.x / 9.x 理论上同源；但锚点只在 9.0.2 实编验证过，
  # 换版本先跑一遍 scripts/local-verify-patch.sh。
  case "${FFMPEG_VERSION}" in
    9.*) ;;
    *) die "AVS3 补丁只在 FFmpeg 9.x 验证过（当前 ${FFMPEG_VERSION}）。换版本请先重新核对锚点。" ;;
  esac

  if [ -f "$dir/libavcodec/libuavs3e.c" ]; then
    warn "libavcodec/libuavs3e.c 已存在，跳过补丁（可能是重复构建）"
    return 0
  fi

  # ---- ① configure：帮助文本 ----
  edit_exact "$dir/configure" \
    '  --enable-libuavs3d       enable AVS3 decoding via libuavs3d [no]' \
    '  --enable-libuavs3d       enable AVS3 decoding via libuavs3d [no]
  --enable-libuavs3e       enable AVS3 encoding via libuavs3e [no]'

  # ---- ② configure：外部库清单（放在 generic 列表里，紧跟 libuavs3d）----
  edit_exact "$dir/configure" \
    '    libuavs3d
' \
    '    libuavs3d
    libuavs3e
'

  # ---- ③ configure：编码器依赖 ----
  edit_exact "$dir/configure" \
    'libuavs3d_decoder_deps="libuavs3d"' \
    'libuavs3d_decoder_deps="libuavs3d"
libuavs3e_encoder_deps="libuavs3e"'

  # ---- ④ configure：pkg-config 探测 ----
  edit_exact "$dir/configure" \
    'enabled libuavs3d         && require_pkg_config libuavs3d "uavs3d >= 1.1.41" uavs3d.h uavs3d_decode' \
    'enabled libuavs3d         && require_pkg_config libuavs3d "uavs3d >= 1.1.41" uavs3d.h uavs3d_decode
enabled libuavs3e         && require_pkg_config libuavs3e uavs3e "uavs3e/uavs3e.h" uavs3e_enc'

  # ---- ⑤ libavcodec/Makefile：编译单元 ----
  edit_exact "$dir/libavcodec/Makefile" \
    'OBJS-$(CONFIG_LIBUAVS3D_DECODER)          += libuavs3d.o' \
    'OBJS-$(CONFIG_LIBUAVS3D_DECODER)          += libuavs3d.o
OBJS-$(CONFIG_LIBUAVS3E_ENCODER)          += libuavs3e.o'

  # ---- ⑥ libavcodec/allcodecs.c：extern 声明（与其它外挂库保持一致）----
  edit_exact "$dir/libavcodec/allcodecs.c" \
    'extern const FFCodec ff_libxavs2_encoder;' \
    'extern const FFCodec ff_libxavs2_encoder;
extern const FFCodec ff_libuavs3e_encoder;'

  # ---- ⑦ 放入封装实现 ----
  local src="$ROOT/patches/libuavs3e.c"
  [ -f "$src" ] || die "找不到 patches/libuavs3e.c（封装实现必须随仓库一起走）"
  cp -f "$src" "$dir/libavcodec/libuavs3e.c"
  ok "已放入 libavcodec/libuavs3e.c"

  # ---- ⑧ libavcodec/libuavs3d.c：不需要再打补丁了 ----
  #
  # 曾经这里有一块「把 seqh->colour_description 那 17 行搬运逻辑摘掉」的补丁，
  # 因为 uavs3d v1.1 的 uavs3d_com_seqh_t 里没有这四个成员（run#18）。
  # 现在 scripts/libs/avs.sh 的 patch_uavs3d_colour() 给 v1.1 补上了同名同序
  # 的四个字段，FFmpeg 自带的这段搬运逻辑可以原样保留 —— AVS3 的色彩信息
  # 就自动进 AVCodecContext 了。这里只剩一个锚点存在性检查，防止上游改动。
  grep -q 'ff_avs3_color_primaries_tab\[seqh->colour_primaries\]' "$dir/libavcodec/libuavs3d.c" \
    || die "libuavs3d.c 里找不到色彩搬运逻辑（上游改了），需要重新核对 ⑧"

  # ---- ⑨ libavcodec/libdavs2.c：把 AVS2 的色彩描述写进 AVCodecContext ----
  #
  # davs2 只把序列信息（宽高/位深/帧率）交出来，原本没有色彩字段；
  # scripts/libs/avs.sh 的 patch_davs2_colour() 让它在 davs2_seq_info_t 末尾
  # 多带 6 个字段。这里把它们映射成 AVCOL_* 常量。
  #
  # 三张表与 libavcodec/avs3.h 里的 ff_avs3_color_*_tab 完全一致 —— AVS2 与
  # AVS3 的 colour_primaries / transfer_characteristics / matrix_coefficients
  # 取值表是同一套（这也是有据可查的：AVS2 HDR10 用 9/12/8，HLG 用 9/14/8，
  # 而 12 在表里是 SMPTE2084(PQ)、14 是 ARIB_STD_B67(HLG)）。为了不让
  # libdavs2.c 依赖 avs3.h，这里各写一份带 AVS2 命名的静态表。
  edit_exact "$dir/libavcodec/libdavs2.c" \
'typedef struct DAVS2Context {' \
'/* AVS2 的 colour_primaries / transfer_characteristics / matrix_coefficients
 * 取值表，与 AVS3 共用同一套编号（见 libavcodec/avs3.h）。 */
static const int davs2_color_primaries_tab[10] = {
    AVCOL_PRI_RESERVED0   ,    /* 0 */
    AVCOL_PRI_BT709       ,    /* 1 */
    AVCOL_PRI_UNSPECIFIED ,    /* 2 */
    AVCOL_PRI_RESERVED    ,    /* 3 */
    AVCOL_PRI_BT470M      ,    /* 4 */
    AVCOL_PRI_BT470BG     ,    /* 5 */
    AVCOL_PRI_SMPTE170M   ,    /* 6 */
    AVCOL_PRI_SMPTE240M   ,    /* 7 */
    AVCOL_PRI_FILM        ,    /* 8 */
    AVCOL_PRI_BT2020           /* 9 */
};

static const int davs2_color_transfer_tab[15] = {
    AVCOL_TRC_RESERVED0    ,   /* 0 */
    AVCOL_TRC_BT709        ,   /* 1 */
    AVCOL_TRC_UNSPECIFIED  ,   /* 2 */
    AVCOL_TRC_RESERVED     ,   /* 3 */
    AVCOL_TRC_GAMMA22      ,   /* 4 */
    AVCOL_TRC_GAMMA28      ,   /* 5 */
    AVCOL_TRC_SMPTE170M    ,   /* 6 */
    AVCOL_TRC_SMPTE240M    ,   /* 7 */
    AVCOL_TRC_LINEAR       ,   /* 8 */
    AVCOL_TRC_LOG          ,   /* 9 */
    AVCOL_TRC_LOG_SQRT     ,   /* 10 */
    AVCOL_TRC_BT2020_12    ,   /* 11 */
    AVCOL_TRC_SMPTE2084    ,   /* 12: HDR10 (PQ) */
    AVCOL_TRC_UNSPECIFIED  ,   /* 13 */
    AVCOL_TRC_ARIB_STD_B67     /* 14: HLG */
};

static const int davs2_color_matrix_tab[12] = {
    AVCOL_SPC_RESERVED     ,   /* 0 */
    AVCOL_SPC_BT709        ,   /* 1 */
    AVCOL_SPC_UNSPECIFIED  ,   /* 2 */
    AVCOL_SPC_RESERVED     ,   /* 3 */
    AVCOL_SPC_FCC          ,   /* 4 */
    AVCOL_SPC_BT470BG      ,   /* 5 */
    AVCOL_SPC_SMPTE170M    ,   /* 6 */
    AVCOL_SPC_SMPTE240M    ,   /* 7 */
    AVCOL_SPC_BT2020_NCL   ,   /* 8 */
    AVCOL_SPC_BT2020_CL    ,   /* 9 */
    AVCOL_SPC_UNSPECIFIED  ,   /* 10 */
    AVCOL_SPC_UNSPECIFIED      /* 11 */
};

typedef struct DAVS2Context {'

  edit_exact "$dir/libavcodec/libdavs2.c" \
'        if (headerset->frame_rate_id < 16)
            avctx->framerate = ff_avs2_frame_rate_tab[headerset->frame_rate_id];
        *got_frame = 0;' \
'        if (headerset->frame_rate_id < 16)
            avctx->framerate = ff_avs2_frame_rate_tab[headerset->frame_rate_id];

        /* 色彩描述来自序列显示扩展（0xB5, id=2），davs2 原本整段跳过、
         * 我们打的补丁把它读了出来（见 scripts/libs/avs.sh）。
         * 没有 colour_description 时三个值都保持 unknown，与以前一致。 */
        if (headerset->colour_description) {
            /* 上界就是三张表的长度：primaries 0..9（10 项）、
             * transfer 0..14（15 项）、matrix 0..11（12 项） */
            if (headerset->colour_primaries         < 10 &&
                headerset->transfer_characteristics < 15 &&
                headerset->matrix_coefficients      < 12) {
                avctx->color_primaries = davs2_color_primaries_tab[headerset->colour_primaries];
                avctx->color_trc       = davs2_color_transfer_tab [headerset->transfer_characteristics];
                avctx->colorspace      = davs2_color_matrix_tab   [headerset->matrix_coefficients];
            } else {
                av_log(avctx, AV_LOG_WARNING,
                       "Invalid colour description: primaries: %d"
                       " transfer characteristics: %d"
                       " matrix coefficients: %d.\n",
                       (int)headerset->colour_primaries,
                       (int)headerset->transfer_characteristics,
                       (int)headerset->matrix_coefficients);
            }
        }
        *got_frame = 0;'

  ok "FFmpeg AVS 补丁应用完成（configure 4 处 + Makefile 1 处 + allcodecs 1 处 + libuavs3e.c 1 个文件 + libdavs2.c 色彩 2 处）"
}
