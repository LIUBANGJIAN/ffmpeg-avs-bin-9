#!/usr/bin/env bash
# ==============================================================================
# AVS 四件套
#   davs2  —— AVS2 解码（10bit，xatabhk fork）
#   xavs2  —— AVS2 编码（上游仅 8bit，这是硬限制）
#   uavs3d —— AVS3 解码（10bit）
#   uavs3e —— AVS3 编码（10bit）★ 需要配合 scripts/patch-ffmpeg.sh 才有 FFmpeg 接口
#
# 调用方需已 export：
#   CC CXX AR RANLIB STRIP HOST TARGET_ARCH IS_ANDROID CMAKE_TOOLCHAIN
# ==============================================================================

# ------------------------------------------------------------------------------
# davs2 —— 把「序列显示扩展」里的色彩描述读出来（上游从来没读过）
#
# 背景：AVS2 的序列头（0xB0）**没有** colour_description 这类语法，色彩/HDR
# 描述被放在序列显示扩展里（0xB5，extension_start_code_identifier == 2）：
#
#     sequence_display_extension() {
#         extension_start_code_identifier   u(4)   // == 2
#         video_format                      u(3)
#         sample_range                      u(1)
#         colour_description                u(1)
#         if (colour_description) {
#             colour_primaries              u(8)
#             transfer_characteristics      u(8)
#             matrix_coefficients           u(8)
#         }
#         display_horizontal_size          u(14)
#         ...
#     }
#
# 但 davs2 的 parse_header() 里 SC_EXTENSION 走的是 `/* skip this unit */`，
# 于是这些字段从来没有进过 davs2_seq_info_t，FFmpeg 的 libdavs2.c 也就没有
# 任何东西可写进 AVCodecContext —— 结果 ffprobe 对**所有** AVS2 流一律报
# color_space/primaries/transfer = unknown。
#
# 实测这条组播（SZTV-4K-AVS2）序列显示扩展里是
#     colour_description=1  primaries=9  transfer=14  matrix=8
# 即 BT.2020 + HLG（9=BT.2020，14=HLG，8=BT.2020_NCL；与 FFmpeg avs3.h 的
# ff_avs3_color_transfer_tab[14]=AVCOL_TRC_ARIB_STD_B67 一致，也与
# 《IPTV 集成播控平台 4K 超高清节目视音频格式要求》B.2.2 的 AVS2 HLG 表一致：
# primaries=9 / transfer=14 / matrix=8；同文档 B.2.1 的 HDR10 是 9/12/8，
# 12 在 AVS3 表里正是 AVCOL_TRC_SMPTE2084）。也就是说这条流本来就是 HDR，
# 只是解码链路把信令丢了，播放器按 BT.709 SDR 去解释。
#
# 改动分四处，都不改解码行为，只把已有的数据搬出来：
#   ① davs2.h  : davs2_seq_info_t 追加 6 个字段（公开结构，追加在末尾）
#   ② common.h : davs2_mgr_t 追加同样的字段（序列信息会随新序列头被 memcpy
#                覆盖成 0，而扩展段在序列头之后才到，必须独立存一份）
#   ③ header.cc: parse_header() 里识别 id==2 的扩展并解析
#   ④ davs2.cc : 输出序列信息时把色彩字段补进 headerset
# ------------------------------------------------------------------------------
patch_davs2_colour() {
  local dir="$1"

  # ① 公开结构追加字段（末尾追加，不影响已有成员的偏移）
  edit_crlf "$dir/source/davs2.h" \
'    uint32_t        frame_rate_id;      /* frame rate code, mpeg12 [1...8] */
} davs2_seq_info_t;' \
'    uint32_t        frame_rate_id;      /* frame rate code, mpeg12 [1...8] */

    /* --- colour description, from sequence display extension (0xB5, id=2) --- */
    uint32_t        colour_description;      /* 1: the following three are valid */
    uint32_t        colour_primaries;        /* 9: BT.2020                     */
    uint32_t        transfer_characteristics;/* 12: PQ, 14: HLG                */
    uint32_t        matrix_coefficients;     /* 8: BT.2020 non-constant        */
    uint32_t        video_format;            /* 1: progressive                 */
    uint32_t        sample_range;            /* 0: limited range               */
} davs2_seq_info_t;'

  # ② 解码器管理器里独立保存一份（见上面②的说明）
  edit_crlf "$dir/source/common/common.h" \
'    davs2_seq_t         seq_info;     /* latest sequence head */' \
'    davs2_seq_t         seq_info;     /* latest sequence head */

    /* --- colour description, parsed from sequence display extension(0xB5, id=2).
     * 序列信息会在每个新序列头处被整体 memcpy 覆盖成 0，而扩展段在序列头
     * 之后才到，所以必须单独存，不能只放在 seq_info.head 里。 --- */
    uint32_t            colour_description;
    uint32_t            colour_primaries;
    uint32_t            transfer_characteristics;
    uint32_t            matrix_coefficients;
    uint32_t            video_format;
    uint32_t            sample_range;'

  # ③ 解析函数：放在 parse_header() 之前（u_v / u_flag 来自 vlc.h，已包含）
  edit_crlf "$dir/source/common/header.cc" \
' */
int parse_header(davs2_t *h, davs2_bs_t *p_bs)' \
' */

/* ---------------------------------------------------------------------------
 * 序列显示扩展（0xB5，extension_start_code_identifier == 2）
 *
 * 只在 bs 的**副本**上读，不动 bs->i_bit_pos：整段的跳过仍由 parse_header()
 * 统一处理，解码流程一行都不变。只在值是 id==2 时才写 manager，其它扩展
 * （3=时序分级 / 4=版权 / 7=图像显示 / 11=摄像机参数 / 15=定位数据）忽略。
 * --------------------------------------------------------------------------- */
static void parse_sequence_display_extension(davs2_mgr_t *mgr, davs2_bs_t *bs)
{
    davs2_bs_t tmp = *bs;
    int video_format, sample_range, colour_description;
    int primaries, transfer, matrix;

    /* 进入这里时 i_bit_pos 指向起始码的**第一个 0x00**（parse_header 是在
     * 找到 start code 之后直接换算成位偏移的），所以先跳过 32 bit 起始码，
     * 位置才对得上 extension_start_code_identifier。 */
    tmp.i_bit_pos += 32;

    if (u_v(&tmp, 4, "extension_start_code_identifier") != SEQUENCE_DISPLAY_EXTENSION_ID) {
        return;
    }

    /* bool_t 是 uint8_t，而 vlc_u_v 越界返回 -1 —— 直接赋值会变成 255，
     * 所以标志位一律用 == 1 归一化。 */
    video_format       = u_v(&tmp, 3, "video_format");
    sample_range       = (u_flag(&tmp, "sample_range") == 1) ? 1 : 0;
    colour_description = (u_flag(&tmp, "colour_description") == 1) ? 1 : 0;

    if (colour_description) {
        /* vlc_u_v 越界时返回 -1 且不移动指针 —— 三个值必须全部有效才写回，
         * 否则被截断的扩展段会留下一组垃圾色彩，比 unknown 更糟。 */
        primaries = u_v(&tmp, 8, "colour_primaries");
        transfer  = u_v(&tmp, 8, "transfer_characteristics");
        matrix    = u_v(&tmp, 8, "matrix_coefficients");

        if (primaries < 0 || transfer < 0 || matrix < 0) {
            return;
        }

        mgr->colour_primaries         = (uint32_t)primaries;
        mgr->transfer_characteristics = (uint32_t)transfer;
        mgr->matrix_coefficients      = (uint32_t)matrix;
        mgr->colour_description       = 1;
    } else {
        mgr->colour_description = 0;
    }

    if (video_format >= 0 && video_format <= 7) {
        mgr->video_format = (uint32_t)video_format;
    }
    mgr->sample_range = (uint32_t)sample_range;
}

/* ---------------------------------------------------------------------------
 */
int parse_header(davs2_t *h, davs2_bs_t *p_bs)'

  # ③b 在 switch 里调用（case 标签后面接一条语句是合法的 C++，
  #     执行完自然 fall through 到下面的「跳过本单元」分支）
  edit_crlf "$dir/source/common/header.cc" \
'        case SC_EXTENSION:' \
'        case SC_EXTENSION:
            /* AVS2 的色彩描述就藏在这里，上游一直整段跳过 */
            parse_sequence_display_extension(h->task_info.taskmgr, p_bs);'

  # ③c 新序列头到来时把色彩描述清零：扩展段在序列头之后才到，会重新填；
  #     若这个新序列根本没有序列显示扩展，就应当回到 unknown 而不是沿用旧的。
  edit_crlf "$dir/source/common/header.cc" \
'        memcpy(&mgr->seq_info, seq, sizeof(davs2_seq_t));' \
'        memcpy(&mgr->seq_info, seq, sizeof(davs2_seq_t));

        /* 新序列：色彩描述先归零，等紧随其后的序列显示扩展重新填 */
        mgr->colour_description = 0;'

  # ④ 输出时补进 headerset（两处 GOT_HEADER 分支都要，want=2）
  edit_crlf "$dir/source/common/davs2.cc" \
'/* --------------------------------------------------------------------------
 * Thread of decoder output (decoded raw data)
 */
int decoder_get_output(davs2_mgr_t *mgr, davs2_seq_info_t *headerset, davs2_picture_t *out_frame, int is_flush)' \
'/* 把序列显示扩展里读到的色彩描述补进对外输出的序列信息。
 * 必须放在 memcpy 之后：memcpy 拷的是 mgr->seq_info.head，那份里没有色彩。 */
static void davs2_fill_colour_info(davs2_seq_info_t *headerset, davs2_mgr_t *mgr)
{
    headerset->colour_description       = mgr->colour_description;
    headerset->colour_primaries         = mgr->colour_primaries;
    headerset->transfer_characteristics = mgr->transfer_characteristics;
    headerset->matrix_coefficients      = mgr->matrix_coefficients;
    headerset->video_format             = mgr->video_format;
    headerset->sample_range             = mgr->sample_range;
}

/* --------------------------------------------------------------------------
 * Thread of decoder output (decoded raw data)
 */
int decoder_get_output(davs2_mgr_t *mgr, davs2_seq_info_t *headerset, davs2_picture_t *out_frame, int is_flush)'

  edit_crlf "$dir/source/common/davs2.cc" \
'            memcpy(headerset, &mgr->seq_info.head, sizeof(davs2_seq_info_t));' \
'            memcpy(headerset, &mgr->seq_info.head, sizeof(davs2_seq_info_t));
            davs2_fill_colour_info(headerset, mgr);' 2
}

# ------------------------------------------------------------------------------
# davs2 —— AVS2 解码
# 四个坑（全部已踩过并核实）：
#   1) 源码是 C++（.cc），configure 默认 CC=g++；交叉编译时必须把 CC 指到 C++ 编译器
#   2) configure 把 --bit-depth=10 写死成 exit 1 —— fork 改了源码却没改构建脚本
#   3) 没有 install 目标，只有 install-lib-static / install-lib-dev
#   4) 静态链进 FFmpeg 需要 C++ 运行库（由平台脚本 --extra-libs 补）
# ------------------------------------------------------------------------------
build_davs2() {
  local dir bdir logf
  dir="$(fetch davs2)"
  bdir="$dir/build/linux"
  logf="$LOGS/davs2.log"

  # 只保留对 9bit 的拒绝，放开 10bit
  edit_exact "$bdir/configure" \
    'elif [[ "$bit_depth" = "9" || "$bit_depth" = "10" ]]; then' \
    'elif [[ "$bit_depth" = "9" ]]; then'

  # 10bit 的 SIMD 例程里用了未限定的 min/max，而文件只 include 了 intrinsics
  # 头、没有 <algorithm>。MSVC 下靠 windows.h 带的 min/max 宏能过，MinGW 的
  # GCC 直接报 "'min' was not declared in this scope; did you mean 'sin'?"。
  # 换成三元表达式：不依赖头文件，也不受命名空间影响。
  edit_exact "$dir/source/common/vec/intrinsic_intra-pred.cc" \
    '    int ishift = min(ishift_x, ishift_y);' \
    '    int ishift = (ishift_x < ishift_y) ? ishift_x : ishift_y;'
  edit_exact "$dir/source/common/vec/intrinsic_pixel_avx.cc" \
    '    start = max(start, 0);' \
    '    start = (start > 0) ? start : 0;' 4

  # ---- 上游 10bit 构建的真实缺陷：ALF 的 AVX2 实现从来没被编译过 ----
  # source/common/alf.cc 在 `#if HIGH_BIT_DEPTH` 下会把
  #   alf_block[0] = alf_filter_block_avx2_10bit
  # 指过去，而该函数**只**定义在 source/common/vec/intrinsic_alf_avx2.c。
  # 这个文件既不在 SRCS 也不在 SRCSAVX 里（而且它是 .c，同类文件都是 .cc）。
  # 8bit 构建不引用它，所以这个洞一直没人发现；10bit 才暴露成
  #   ld: libdavs2.a(alf.o): undefined reference to `davs2_alf_filter_block_avx2_10bit'
  # 再被 FFmpeg configure 折叠成一句没头没脑的
  #   ERROR: davs2 >= 1.6.0 not found using pkg-config
  #
  # 试过把它塞进 OBJAVX 去真编：
  #   - 按 C++ 编（g++ 默认）：一串 invalid conversion from 'const pel_t*' to 'pel_t*'
  #   - 加 -x c 按 C 编：能编过，但目标文件进了压缩包之后 nm 仍然找不到符号
  #     （上游那套 OBJAVX 规则/依赖关系不是给 .c 设计的）
  # 收益只是「10bit ALF 用 AVX2 而不是 SSE4」，风险和排查成本都不划算。
  # 最终选择退回 SSE4 的 10bit 实现（intrinsic_alf.cc，一直是编译的），
  # 仍然是 SIMD。这是本项目里唯一一处「有意识的性能取舍」。
  # 注意锚点必须是**单行**：davs2 的源码是 CRLF 换行，多行锚点里的 \n 永远匹配不上
  # （run#14 就在这里「锚点匹配 0 次」）。
  edit_exact "$dir/source/common/alf.cc" \
    '            fh->alf_block[0] = alf_filter_block_avx2_10bit;' \
    '            /* AVX2 版 10bit ALF 上游从未接入构建，保留上面的 SSE4 实现 */'

  # 把序列显示扩展里的色彩描述读出来（详见 patch_davs2_colour 的注释）
  patch_davs2_colour "$dir"

  local arch_opts=()
  case "${TARGET_ARCH:-x86_64}" in
    arm*|aarch64)
      # davs2 仓库里没有任何 ARM 汇编（source/common 下只有 x86 与 vec 两个目录），
      # 用 --disable-asm 绕开 configure 里的 gas-preprocessor 分支，走纯 C。
      # 代价：没有 SIMD 加速；收益：不会因为汇编而编不过。
      arch_opts+=(--disable-asm)
      ;;
  esac
  if [ "${IS_ANDROID:-0}" = "1" ]; then
    arch_opts+=(--enable-pic)
  fi

  log "configure davs2 (10bit, arch=${TARGET_ARCH:-x86_64})"
  (
    cd "$bdir"
    # davs2 是 C++ 源码：强制用 C++ 编译器，否则 gcc 会把 .cc 当 C 编
    CC="$CXX" \
    ./configure \
      --prefix="$PREFIX" \
      ${HOST:+--host="$HOST"} \
      --bit-depth=10 \
      --enable-static --disable-shared \
      --disable-cli --disable-opencl \
      "${arch_opts[@]}"
  ) > "$logf" 2>&1 || { dump_log "$logf"; die "davs2: configure 失败"; }

  log "build/install davs2"
  make -C "$bdir" -j"$JOBS" install-lib-static install-lib-dev >> "$logf" 2>&1 \
    || { dump_log "$logf"; die "davs2: 构建或安装失败"; }

  require_pc davs2
  # FFmpeg 9.0 的 configure 写死 "davs2 >= 1.6.0"，而 fork 自己生成的 .pc
  # 版本串未必达得到（它长期没更新 version 宏）。库能力是够的，只改声明。
  pc_ensure_version davs2 1.6.0

  # 这里不再用 nm 断言「符号在不在」——试过，信噪比太差：
  # 它对含 nasm 汇编成员的归档给出的结果不稳定，run#15 就报了个假阴性
  # （说没有 davs2_alf_filter_block_sse128_10bit，实际库是好的）。
  # 真正的把关交给 build_everything 里的 probe_avs_pc_links：
  # 它用和 FFmpeg 完全一样的参数真编真链一次，缺任何符号都会立刻暴露，
  # 而且报的是链接器的原始错误，不是一句 "not found using pkg-config"。
}

# ------------------------------------------------------------------------------
# xavs2 —— AVS2 编码（只能 8bit）
# ------------------------------------------------------------------------------
build_xavs2() {
  local dir bdir logf
  dir="$(fetch xavs2)"
  bdir="$dir/build/linux"
  logf="$LOGS/xavs2.log"

  # GCC 14 起 -Wincompatible-pointer-types 从「警告」升级成「错误」，
  # xavs2 1.4（2018 年的代码）在这个函数上踩中：
  #   static void *encoder_aec_encode_one_frame(xavs2_t *h)
  #   被当成 void *(*)(void *) 传给 xavs2_threadpool_run
  # 两个指针只是类型标签不同、二进制布局完全一致，本可以安全转换；
  # 但 xavs2 的源码是 CRLF 行尾，多行锚点会匹配失败（edit_exact 用 \n 比对），
  # 所以不改造源码，直接在 configure 里关掉这条诊断 —— 效果等价，且不动上游文件。
  # -Wno-error= 是第二道保险：万一某些 GCC 把它当 permerror，这条能降回警告。
  local gcc14_opts='-Wno-incompatible-pointer-types -Wno-error=incompatible-pointer-types'

  local arch_opts=()
  case "${TARGET_ARCH:-x86_64}" in
    arm*|aarch64)
      arch_opts+=(--disable-asm)
      ;;
  esac
  if [ "${IS_ANDROID:-0}" = "1" ]; then
    arch_opts+=(--enable-pic)
  fi

  log "configure xavs2 (8bit)"
  (
    cd "$bdir"
    # 注意：这里**不能**像 davs2 那样把 CC 强制成 CXX。
    # xavs2 是纯 C 项目（source 下 70 个 .c、0 个 .cc）；用 g++ 编 .c 会按 C++
    # 规则做 narrowing 检查，cpu.c 里的 `static const char cache32_ids[] = {0x82,...}`
    # 直接报 "narrowing conversion of '130' from 'int' to 'char'"。
    # CC 由平台脚本导出（gcc / NDK clang），configure 会自己用。
    ./configure \
      --prefix="$PREFIX" \
      ${HOST:+--host="$HOST"} \
      --bit-depth=8 \
      --enable-static --disable-shared \
      --disable-cli --disable-opencl \
      --disable-avs --disable-swscale --disable-lavf \
      --disable-ffms --disable-gpac --disable-lsmash \
      --extra-cflags="$gcc14_opts" \
      "${arch_opts[@]}"
  ) > "$logf" 2>&1 || { dump_log "$logf"; die "xavs2: configure 失败"; }

  log "build/install xavs2"
  make -C "$bdir" -j"$JOBS" install-lib-static install-lib-dev >> "$logf" 2>&1 \
    || { dump_log "$logf"; die "xavs2: 构建或安装失败"; }

  require_pc xavs2
}

# ------------------------------------------------------------------------------
# uavs3d —— AVS3 解码（10bit）
# 自带 CMakeLists（cmake_minimum_required 3.1，CMake 4.x 需要 CMAKE_POLICY_VERSION_MINIMUM）
#
# 三个必改点（都是「上游没做」而不是「上游做错了」）：
#   1) 位深是**编译期**的：com_def.h 的 BIT_DEPTH 决定 pel 是 u8 还是 s16，
#      README 明写「要解 10bit 就把 BIT_DEPTH 改成 10」。
#      （原来传的 -DCOMPILE_10BIT=ON 是个无人引用的变量，cmake 只会警告 unused，
#        对产物零影响 —— 也就是说之前编出来的其实是 8bit-only。）
#      10bit 构建是超集：bit_depth_internal 由码流决定（8 或 10），
#      C / SSE / AVX2 的例程都吃运行期 bit_depth 参数，所以一个二进制 8/10bit 都能解。
#   2) source/CMakeLists.txt 把 x86 的 sse/avx2 目录**无条件**加进目标，
#      ARM 上就会拿 x86 intrinsics 去编 ARM（NDK clang 直接 20 个 error）。
#   3) 但 ARM 的 NEON 汇编不能拿来做「通用 10bit 解码」：def_arm64.S / def_armv7.S
#      里写死 `#define COMPILE_10BIT 0`，8bit 分支用 .16b/u8 指令、另一分支用 .8h/s16，
#      是编译期二选一 —— 一个二进制不可能同时对 8bit 和 10bit 正确。
#      所以 ARM 上关掉 NEON 汇编、走纯 C（C 实现是运行期位深的），
#      代价是 ARM 解码慢 2~4 倍；x86 上 SSE/AVX2 完全不受影响。
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# uavs3d —— AVS3 解码（10bit）
# ------------------------------------------------------------------------------
build_uavs3d() {
  local dir
  dir="$(fetch uavs3d)"

  edit_exact "$dir/source/decore/com_def.h" \
    '#define BIT_DEPTH 8' \
    '#define BIT_DEPTH 10'

  edit_exact "$dir/source/CMakeLists.txt" \
'aux_source_directory(./decore/sse DIR_X86_SRC)
aux_source_directory(./decore/avx2 DIR_X86_256_SRC)' \
'if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64|i.86")
  aux_source_directory(./decore/sse DIR_X86_SRC)
  aux_source_directory(./decore/avx2 DIR_X86_256_SRC)
else()
  message("-- ${CMAKE_SYSTEM_PROCESSOR}: 不启用 x86 SIMD（ARM 走纯 C，原因见 scripts/libs/avs.sh）")
endif()'

  # 空列表传给 set_source_files_properties 会被 CMake 当成参数个数错误，
  # 所以再包一层存在性判断（ARM 上这两个变量是空的）。
  edit_exact "$dir/source/CMakeLists.txt" \
'set_source_files_properties(${DIR_X86_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -msse4.2")
set_source_files_properties(${DIR_X86_256_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -mavx2")' \
'if(DIR_X86_SRC)
  set_source_files_properties(${DIR_X86_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -msse4.2")
endif()
if(DIR_X86_256_SRC)
  set_source_files_properties(${DIR_X86_256_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -mavx2")
endif()'

  # com_util.h 会按 __ANDROID__+__aarch64__ 自动打开 ENABLE_FUNCTION_ARM64/ARM32，
  # 而这两个宏指向的实现在 decore/arm64|armv7（我们不再编译）→ 链接期 undefined。
  # 注意 uavs3d.c 用的是 `#if defined(...)`，所以「定义成 0」没用，必须整条不定义。
  edit_exact "$dir/source/decore/com_util.h" \
'#define ENABLE_FUNCTION_C 1
#define ENABLE_FUNCTION_ARM64 1' \
'#define ENABLE_FUNCTION_C 1'
  edit_exact "$dir/source/decore/com_util.h" \
'#define ENABLE_FUNCTION_C 1
#define ENABLE_FUNCTION_ARM32 1' \
'#define ENABLE_FUNCTION_C 1'

  # uavs3d 1.1 的 source/decore/threadpool.h 第 15 行是一条 **写在非 Windows 分支里**
  # 的 MSVC 指令（上游 copy-paste 事故）：
  #     #if defined(_WIN32)
  #     #include "win32thread.h"
  #     #else
  #     #pragma comment(lib, "pthreadVC2.lib")   <-- 这里，POSIX 分支
  #     #include <pthread.h>
  # clang 会把它编成目标文件里的 .linker-options 段：
  #   - GNU ld 把不认识的段当垃圾忽略 → linux / mingw 一路无事（所以一直没暴露）
  #   - **NDK 用的 lld 会真的去解析**，于是任何 include 了 threadpool.h 的目标文件
  #     一旦被拉进链接就报：
  #       ld: error: libuavs3d.a(uavs3d.c.o): unable to find library from
  #                dependent library specifier: pthreadVC2.lib
  #     而 FFmpeg configure 把它折叠成一句没头没尾的
  #       ERROR: uavs3d >= 1.1.41 not found using pkg-config
  # 在 POSIX 上引 pthread 走的就是下面那行 <pthread.h>，这条 pragma 纯属多余，删掉。
  edit_exact "$dir/source/decore/threadpool.h" \
    '#pragma comment(lib, "pthreadVC2.lib")' \
    '/* 上游把 Windows 的 #pragma comment(lib) 错写进了非 Windows 分支；lld 会当真，删掉 */'

  # 线程栈：和 uavs3e 一模一样的坑，只是表现在解码侧。
  # source/decore/threadpool.c 建线程池时 attr = NULL（用系统默认栈），于是：
  #   - glibc 默认 8 MiB、Windows 走 win32thread.c 的 _beginthreadex(NULL, 0)
  #     拿 1 MiB 默认栈 → 都够用；
  #   - musl 默认只有 128 KiB → AVS3 的 CTU/CU 递归解析在 worker 线程里跑，
  #     直接撑爆。
  # run#22 linux 冒烟里表现得很典型：`-c:v libuavs3e` 编码已经成功（24.0K），
  # 紧接着「解回来验证帧数」那条命令一声不响就 exit 139 —— windows 同一份
  # 产物跑同一条命令完全正常。这里给 worker 显式 8 MiB 栈。
  edit_exact "$dir/source/decore/threadpool.c" \
'    for (i = 0; i < pool->threads; i++) {
        if (uavs3d_pthread_create(pool->thread_handle + i, NULL, (uavs3d_tfunc_a_t)uavs3d_threadpool_thread, pool)) {
            goto fail;
        }
    }' \
'    for (i = 0; i < pool->threads; i++) {
#if defined(_WIN32)
        if (uavs3d_pthread_create(pool->thread_handle + i, NULL, (uavs3d_tfunc_a_t)uavs3d_threadpool_thread, pool)) {
            goto fail;
        }
#else
        /* 显式给 8 MiB 栈：musl 的默认线程栈只有 128 KiB，CU 递归解析撑爆它 */
        {
            uavs3d_pthread_attr_t attr;
            uavs3d_pthread_attr_init(&attr);
            pthread_attr_setstacksize(&attr, (size_t)8 << 20);
            if (uavs3d_pthread_create(pool->thread_handle + i, &attr, (uavs3d_tfunc_a_t)uavs3d_threadpool_thread, pool)) {
                uavs3d_pthread_attr_destroy(&attr);
                goto fail;
            }
            uavs3d_pthread_attr_destroy(&attr);
        }
#endif
    }'

  # ------------------------------------------------------------------------
  # stdout 污染：uavs3d 有 3 处直接 printf 到 stdout，完全绕过了 av_log。
  # 这不只是"日志难看"，是会造成实际故障：
  #   * `ffprobe -of json` 的输出里被插进
  #       libuavs3d(10): 1.1.1_release, 4680032b9bd0034523cc00ec9dd7c95d5d565d1e
  #     于是第 2 行就不是 JSON 了，任何解析器都会崩——
  #     实测 8K 素材上 checkts.py 报
  #       "Expecting property name enclosed in double quotes: line 2 column 1"
  #   * 任何「结果走 stdout」的用法都会被彻底污染，例如
  #       ffmpeg -i in.ts -f mpegts pipe:1 > out.ts
  #     输出文件直接报废。
  # 版本横幅是在 uavs3d_create() 里打的，每建一个解码器实例就打一次，
  # 所以 ffprobe 探测一次会打两行（探流一个实例 + 正式一个实例）。
  # 三处统一改到 stderr，与 davs2 的行为对齐。
  # ------------------------------------------------------------------------
  edit_exact "$dir/source/decoder/uavs3d.c" \
    'printf("libuavs3d(%2d): %s_%s, %s\n", BIT_DEPTH, VERSION_STR, VERSION_TYPE, VERSION_SHA1);' \
    'fprintf(stderr, "libuavs3d(%2d): %s_%s, %s\n", BIT_DEPTH, VERSION_STR, VERSION_TYPE, VERSION_SHA1);'

  edit_exact "$dir/source/decoder/dec_util.c" \
    'printf(" >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>  Warnning: enc/dec mismatch! ptr = %lld\n", (long long)pic->ptr);' \
    'fprintf(stderr, " >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>  Warnning: enc/dec mismatch! ptr = %lld\n", (long long)pic->ptr);'

  edit_exact "$dir/source/decore/intra_pred.c" \
    'printf("\n illegal chroma intra prediction mode\n");' \
    'fprintf(stderr, "\n illegal chroma intra prediction mode\n");'

  # 把序列头里的色彩描述留下（详见文件末尾 patch_uavs3d_colour 的注释）
  patch_uavs3d_colour "$dir"

  log "cmake build uavs3d (10bit)"
  # 只编库目标：test/uavs3dec 会 target_link_libraries(… pthread)，
  # 而 Android 的 bionic 把 pthread 并进了 libc，没有独立 -lpthread，
  # 链接期直接 "ld: error: unable to find library -lpthread"。
  # 我们只要 libuavs3d.a，命令行程序一次也用不到。
  local CMAKE_BUILD_TARGET=uavs3d
  cmake_build "$dir" uavs3d \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc uavs3d
  # FFmpeg 9.0 的 configure 写死要求 "uavs3d >= 1.1.41"，
  # 而上游 version.sh 用 git describe 生成，可能只有 "1.1" 这种串。
  # 版本不达标时 configure 会直接拒绝，但库的功能是够用的。
  pc_ensure_version uavs3d 1.1.41
}

# ------------------------------------------------------------------------------
# uavs3e —— AVS3 编码（8bit，原因见函数内注释）
# 需要改的地方：
#   1) cmake_minimum_required(VERSION 2.8) —— CMake 4.x 已移除对 <3.5 的兼容
#   2) src/CMakeLists.txt 的 else() 分支会拉 x86 的 sse/avx2 源文件，
#      ARMv7 上会掉进去（CMAKE_SYSTEM_PROCESSOR=armv7-a 既不匹配 aarch64 也不匹配
#      loongarch64），结果拿 x86 intrinsics 编 ARM，必然失败
#   3) 同一个文件里 set_source_files_properties 的空列表地雷
#   4) inc/com_api.h 在非 Linux 分支把 COMPILE_10BIT 强行归零（MinGW 上踩）
#   5) test/utest.c 缺 <unistd.h> + 用 lseek64（musl 上没有这个符号）
# ------------------------------------------------------------------------------
build_uavs3e() {
  local dir
  dir="$(fetch uavs3e)"

  edit_exact "$dir/CMakeLists.txt" \
    'cmake_minimum_required(VERSION 2.8)' \
    'cmake_minimum_required(VERSION 3.5)'

  edit_exact "$dir/src/CMakeLists.txt" \
'else()
  aux_source_directory(./sse DIR_X86_SRC)' \
'elseif("${CMAKE_SYSTEM_PROCESSOR}" MATCHES "arm")
  message("-- arm: 仅 C 实现，不使用 x86 SIMD")
else()
  aux_source_directory(./sse DIR_X86_SRC)'

  # 3) src/CMakeLists.txt 还有一处同样的地雷：`set_source_files_properties(${DIR_X86_SRC} ...)`
  #    在上面那条分支把 x86 目录排除后，这两个变量是**空的**，
  #    而 set_source_files_properties 拿到空文件列表会直接报
  #    "called with incorrect number of arguments" → ARM 上 configure 就挂了。
  edit_exact "$dir/src/CMakeLists.txt" \
'set_source_files_properties(${DIR_X86_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -msse4.2")
set_source_files_properties(${DIR_X86_256_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -mavx2")' \
'if(DIR_X86_SRC)
  set_source_files_properties(${DIR_X86_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -msse4.2")
endif()
if(DIR_X86_256_SRC)
  set_source_files_properties(${DIR_X86_256_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -mavx2")
endif()'

  # 4) inc/com_api.h 用 #if defined(__linux__) 门控 10bit，
  #    非 Linux 分支里有一句无条件的 #define COMPILE_10BIT 0，
  #    会把 -DCOMPILE_10BIT=1 直接抹掉 —— MinGW(Windows) 上因此永远只有 8bit。
  #    改成 #ifndef 保护后，命令行定义优先。
  edit_exact "$dir/inc/com_api.h" \
'#else
#define COMPILE_10BIT 0' \
'#else
#ifndef COMPILE_10BIT
#define COMPILE_10BIT 0
#endif'

  # 5) inc/uavs3e.h 里两处 `#if defined(_WIN32) || defined(__linux__)`：
  #    第一处 include <sys/timeb.h>，第二处用 struct timeb + ftime() 取毫秒时间。
  #    Android 的 clang 同样定义 __linux__，于是掉进这个分支，
  #    而 bionic 根本没有 sys/timeb.h → "fatal error: 'sys/timeb.h' file not found"。
  #    这两处本来就是「Windows 用 ftime、其它平台用 gettimeofday」的分流，
  #    把 __linux__ 从条件里去掉，Linux/Android 就走下面 #elif defined(__GNUC__)
  #    的 gettimeofday 分支（glibc 和 bionic 都支持）。
  edit_exact "$dir/inc/uavs3e.h" \
    'defined(_WIN32) || defined(__linux__)' \
    'defined(_WIN32)' 2

  # 6) test/utest.c 的平台分支有两个坑，一起补：
  #      #if defined(__APPLE__) || defined(__loongarch__)
  #      #include <unistd.h>          <- 只有 Apple/loongarch 包含
  #      #define _lseeki64 lseek
  #      #else
  #      #define _lseeki64 lseek64     <- Linux/Android 走这条，但没有 unistd.h
  #    结果：Linux 下 read/write/close/lseek64 全是隐式声明；glibc 恰好有 lseek64 符号
  #    所以能链上，musl（Alpine 全静态）没有 → "undefined reference to `lseek64'"。
  #    隐式声明还有个隐患：被当成 int 返回，大文件下偏移会被截断。
  #    统一改成「无条件 include <unistd.h> + 用 POSIX 的 lseek」，
  #    配合下面 -D_FILE_OFFSET_BITS=64 让 32 位（armv7）上也是 64 位偏移。
  edit_exact "$dir/test/utest.c" \
'#if defined(__APPLE__) || defined(__loongarch__)
#include <unistd.h>
#define _lseeki64 lseek
#else
#define _lseeki64 lseek64
#endif' \
'#include <unistd.h>
#define _lseeki64 lseek'

  # 7) 和 uavs3d 一模一样的上游事故：inc/com_thread.h 第 26 行，
  #    那条 MSVC 的 #pragma comment 又写在 **非 Windows 分支** 里（#else 之后）：
  #      #else
  #      #pragma comment(lib, "pthreadVC2.lib")   <-- 这里
  #      #include <semaphore.h>
  #      #include <pthread.h>
  #    后果同 uavs3d：GNU ld 当垃圾段忽略，NDK 的 lld 会解析，于是任何链接
  #    libuavs3e.a 的命令都报
  #      ld: error: libuavs3e.a(uavs3e.c.o): unable to find library from
  #               dependent library specifier: pthreadVC2.lib
  #    （run#18 android-arm64：uavs3d 修好之后，紧接着就轮到它）
  edit_exact "$dir/inc/com_thread.h" \
    '#pragma comment(lib, "pthreadVC2.lib")' \
    '/* 上游把 Windows 的 #pragma comment(lib) 错写进了非 Windows 分支；lld 会当真，删掉 */'

  # 8) 线程栈：musl 的默认线程栈只有 128 KiB，glibc / mingw 是 8 MiB。
  #    src/com_thread.c 建线程池时传的是 attr = NULL（用默认值），而编码线程要跑
  #    CU 递归 + RDOQ，栈帧很深 —— 同样是这份代码，在 glibc/mingw 上跑得好好的，
  #    在 Alpine(musl) 上一进编码就
  #      Segmentation fault (core dumped)
  #    （run#21 linux 冒烟：`-c:v libuavs3e` 直接段错误，windows 同一份代码全过）。
  #    这里给线程池线程显式 8 MiB 栈；_WIN32 分支保持原样，不碰已经跑通的平台。
  edit_exact "$dir/src/com_thread.c" \
'    for (i = 0; i < pool->threads; i++) {
        if (uavs3e_pthread_create(pool->thread_handle + i, NULL, (uavs3e_tfunc_a_t)uavs3e_threadpool_thread, pool)) {
            goto fail;
        }
    }' \
'    for (i = 0; i < pool->threads; i++) {
#if defined(_WIN32)
        if (uavs3e_pthread_create(pool->thread_handle + i, NULL, (uavs3e_tfunc_a_t)uavs3e_threadpool_thread, pool)) {
            goto fail;
        }
#else
        /* 显式给 8 MiB 栈：musl 的默认线程栈只有 128 KiB，编码线程的 CU 递归会撑爆它 */
        {
            uavs3e_pthread_attr_t attr;
            uavs3e_pthread_attr_init(&attr);
            pthread_attr_setstacksize(&attr, (size_t)8 << 20);
            if (uavs3e_pthread_create(pool->thread_handle + i, &attr, (uavs3e_tfunc_a_t)uavs3e_threadpool_thread, pool)) {
                uavs3e_pthread_attr_destroy(&attr);
                goto fail;
            }
            uavs3e_pthread_attr_destroy(&attr);
        }
#endif
    }'

  log "cmake build uavs3e (8bit)"
  # 位深显式锁 8bit，不是偷懒，是因为「10bit 编码」这条路现在走不通：
  #   - uavs3e 的开关是顶层 CMakeLists 里的 add_definitions(-DCOMPILE_10BIT=1)，
  #     而它写在 add_subdirectory(./src) **之后**；CMake 的 add_definitions
  #     只对「之后创建的目标」生效，于是库目标永远拿不到这个宏 —— 也就是说
  #     传 -DCOMPILE_10BIT=ON 的真实效果是：库还是 8bit，只有 test/uavs3enc
  #     这个命令行被编成 10bit（pel 从 u8 变 s16），两者 ABI 直接打架。
  #   - 想真正打开，得同时把 FFmpeg 侧的 patches/libuavs3e.c 改成
  #     bit_depth_internal=10 并做 8→10 的样本搬移，是另一个独立改动。
  # 所以这里显式 OFF：C 库、ARM 汇编、CLI 三者一致都是 8bit。
  # 同样只编库目标，跳过 uavs3enc 命令行（原因见 build_uavs3d）
  local CMAKE_BUILD_TARGET=uavs3e
  cmake_build "$dir" uavs3e \
    -DCOMPILE_10BIT=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_C_FLAGS=-D_FILE_OFFSET_BITS=64

  require_pc uavs3e
}
# ------------------------------------------------------------------------------
# uavs3d —— 把 AVS3 序列头里的色彩描述留下（v1.1 读了就扔）
#
# 关键事实：uavs3d v1.1 的 parser.c **本来就在读** colour_description 和后面
# 三个 8 bit 字段，只是读完直接丢弃：
#
#     int colour_description = dec_bs_read1(bs, -1);   // colour_description u(1)
#     if (colour_description) {
#         dec_bs_read(bs, 8, 0, COM_UINT32_MAX);       // colour_primaries
#         dec_bs_read(bs, 8, 0, COM_UINT32_MAX);       // transfer_characteristics
#         dec_bs_read(bs, 8, 0, COM_UINT32_MAX);       // matrix_coefficients
#     }
#
# 而 com_seqh_t 里没有对应成员可存 —— 这就是 FFmpeg 的 libuavs3d.c 引用
# seqh->colour_description 时编不过的原因（run#18）。之前为了绕开这个编译错误，
# 我们把 libuavs3d.c 里那段搬运逻辑整块摘掉了（代价：AVS3 永远报 unknown）。
#
# 正解不是升到 1.2 —— 1.2 的 CMakeLists 会按 Uavs3d_TARGET_CPU 分支，
# armv7 那支强行 enable_language(ASM) 并加 -mfloat-abi=hard（NDK 是 softfp），
# 等于把已经调通的「Android 纯 C」结论推翻重来。这里只做最小改动：
#   · com_seqh_t 追加 4 个 unsigned char（与 1.2 同名同序，libuavs3d.c 无需改动）
#   · sequence_display_extension() 多接一个 seqhdr 参数，把值存进去
# 注意 colour_primaries 等必须是 u8 语义：libuavs3d.c 用
# UAVS3D_CHECK_INVALID_RANGE(seqh->colour_primaries, 0, 9) 做范围校验。
# ------------------------------------------------------------------------------
patch_uavs3d_colour() {
  local dir="$1"

  edit_exact "$dir/source/decoder/uavs3d.h" \
    '    unsigned char  position_based_transform_enable_flag;' \
'    unsigned char  position_based_transform_enable_flag;

    /* colour description, from sequence display extension (0xB5, id=2).
     * 与上游 uavs3d 1.2 同名同序，FFmpeg 的 libuavs3d.c 直接读这几个成员。 */
    unsigned char  colour_description;
    unsigned char  colour_primaries;
    unsigned char  transfer_characteristics;
    unsigned char  matrix_coefficients;'

  edit_exact "$dir/source/decoder/parser.c" \
    'static int sequence_display_extension(com_bs_t * bs)' \
    'static int sequence_display_extension(com_bs_t * bs, com_seqh_t * seqhdr)'

  edit_exact "$dir/source/decoder/parser.c" \
    '                sequence_display_extension(bs);' \
    '                sequence_display_extension(bs, seqhdr);'

  edit_exact "$dir/source/decoder/parser.c" \
    '    int colour_description = dec_bs_read1(bs, -1);     // colour_description       u(1)' \
'    int colour_description = dec_bs_read1(bs, -1);     // colour_description       u(1)
    seqhdr->colour_description = (unsigned char)colour_description;'

  edit_exact "$dir/source/decoder/parser.c" \
    '        dec_bs_read(bs, 8, 0, COM_UINT32_MAX);         // colour_primaries         u(8)' \
    '        seqhdr->colour_primaries = (unsigned char)dec_bs_read(bs, 8, 0, COM_UINT32_MAX);'

  edit_exact "$dir/source/decoder/parser.c" \
    '        dec_bs_read(bs, 8, 0, COM_UINT32_MAX);         // transfer_characteristics u(8)' \
    '        seqhdr->transfer_characteristics = (unsigned char)dec_bs_read(bs, 8, 0, COM_UINT32_MAX);'

  edit_exact "$dir/source/decoder/parser.c" \
    '        dec_bs_read(bs, 8, 0, COM_UINT32_MAX);         // matrix_coefficients      u(8)' \
    '        seqhdr->matrix_coefficients = (unsigned char)dec_bs_read(bs, 8, 0, COM_UINT32_MAX);'
}


# ------------------------------------------------------------------------------
# 一次性构建全部 AVS 库
# ------------------------------------------------------------------------------
build_avs_all() {
  build_davs2
  build_xavs2
  build_uavs3d
  build_uavs3e
}
