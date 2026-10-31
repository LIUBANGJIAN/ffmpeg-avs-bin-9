# ffmpeg-avs-bin-9

带 **AVS2 / AVS3 完整编解码能力** 的 FFmpeg **9.0.2** 静态构建，Windows / Linux / Android 三平台。

由 GitHub Actions 从源码构建，产物是可直接拷走使用的单文件可执行程序。

> 与 [`ffmpeg-avs-bin-6`](https://github.com/LIUBANGJIAN/ffmpeg-avs-bin-6)（锁 6.1.6）并列：
> 那个是长期自用的稳定线，**这个仓库是用来验证「同一套 AVS 补丁在 FFmpeg 9 上还能不能成立」**。
> 两个仓库脚本同源，差异见文末「与 6.1.6 仓库的差异」一节。

---

## 1. 为什么需要这个项目

官方 FFmpeg **没有 AVS3 编码器**，而 AVS2 的 10bit 解码在主流发行版里也拿不到。具体来说：

| 能力 | 官方 FFmpeg | gyan.dev 的 full build | 本项目 |
|---|---|---|---|
| AVS1 解码 | ✅ 原生 `cavs` | ✅ | ✅ |
| AVS2 解码 8bit | ✅ `libdavs2` | ✅ | ✅ |
| **AVS2 解码 10bit** | 取决于链接的 davs2 | ❌ 上游 davs2 只编 8bit | ✅ **10bit 构建（超集）** |
| AVS2 编码 | ✅ `libxavs2` | ✅（仅 8bit） | ✅（仅 8bit，上游硬限制） |
| AVS3 解码 | ✅ `libuavs3d` | ✅ | ✅ 8/10bit |
| **AVS3 编码** | ❌ **不存在** | ❌ | ✅ `libuavs3e` + 补丁 |

### 一个容易搞错的点：10bit 构建是超集，不是二选一

davs2 的位深是**编译期**固定的，`build/linux/configure` 甚至把 `--bit-depth=10` 写死成 `exit 1`。
但源码里的位深检查是这样的（`source/common/header.cc`）：

```c
#if HIGH_BIT_DEPTH
    g_bit_depth = h->sample_bit_depth;      // 位深跟着码流走，8 或 10 都行
#else
    if (g_bit_depth != h->sample_bit_depth) {
        davs2_log(h, DAVS2_LOG_ERROR, "Un-supported bit-depth %d in this version.\n", ...);
        return -1;
    }
#endif
```

`--bit-depth=10` 会定义 `HIGH_BIT_DEPTH=1`（configure 第 1068 行），于是走上面那个分支。

> **结论：10bit 构建同时能解 8bit 和 10bit 码流。** 选 10bit 没有任何损失。
> 真正只能在「8 或 10」之间二选一的，是把 davs2 当**系统预编译库**用的时候。

---

## 2. 为什么直接上 FFmpeg 9.0.2

**`libuavs3e` 至今没有进入 FFmpeg 主线。** 9.0.2 的 `configure` 外部库清单里仍然只有
`libdavs2` / `libuavs3d` / `libxavs` / `libxavs2`，一个 `uavs3e` 字样都没有。
所以 5 处接线 + 1 个 `libavcodec/libuavs3e.c` 依然要自己打 —— 这一步和 FFmpeg 版本无关。

真正的问题是：**这套补丁能不能跨过 6.1 → 9.0 的四年 API 演化。**

答案基本可以：**只需要改一处**。`patches/libuavs3e.c` 本来就写的是 6.1 之后的
「新式」写法（`.p.*` 字段、`FF_CODEC_ENCODE_CB`、`codec_internal.h`），这些 API 9.0 全都还在，
只有像素格式声明这一项被搬了家（见下表最后一行）：

| 依赖的 API | 9.0.2 现状 | 位置 |
|---|---|---|
| `ff_alloc_packet` | 在（未弃用，`int64_t size`） | `libavcodec/encode.h:71` |
| `FF_CODEC_ENCODE_CB` | 在 | `libavcodec/codec_internal.h:376` |
| `CODEC_LONG_NAME` | 在 | `libavcodec/codec_internal.h:347` |
| `FFCodecDefault` | 在 | `libavcodec/codec_internal.h:97` |
| `.p.capabilities` / `.p.priv_class` | 在（`AVCodec` 已全部 `.p.*` 化） | `libavcodec/codec.h` |
| `avctx->coded_width/height` | 在 | `libavcodec/avcodec.h:619` |
| `FF_API_CODED_FRAME` | **已删除** | 封装里那圈 `#if` 会自然跳空，不是错误 |
| `AVCodec.pix_fmts` | **已移除**（搬到 `FFCodec` 的匿名 union） | 必须改用 `CODEC_PIXFMTS()` 宏 |

`libdavs2.c` / `libuavs3d.c` 这边同样没动：`davs2_decode_frame` 仍是
`FF_CODEC_DECODE_CB` 三参回调，`libuavs3d.c` 里那段
`ff_avs3_color_primaries_tab[seqh->colour_primaries]` 色彩搬运也还在原位。

### 锚点是核对过的，不是猜的

`n9.0.2` 上把 7 处锚点（configure 4 + Makefile 1 + allcodecs 1 + libdavs2 2）逐个实跑：

```
[OK] 替换成功 (configure)      ×4
[OK] 替换成功 (Makefile)
[OK] 替换成功 (allcodecs.c)
[OK] 替换成功 (libdavs2.c)     ×2
[OK] FFmpeg AVS 补丁应用完成
```

`scripts/patch-ffmpeg.sh` 里带了版本护栏：`case "${FFMPEG_VERSION}" in 9.*)`，
换大版本会直接 `die` 而不是悄悄打歪。

### 补丁到底改了什么（6 处文本替换 + 1 个新文件）

| 位置 | 改动 | 为什么 |
|---|---|---|
| `configure` | 帮助文本加 `--enable-libuavs3e` | 让选项合法 |
| `configure` | `EXTERNAL_LIBRARY_LIST` 加 `libuavs3e` | 让 `--enable-libuavs3e` 能被接受 |
| `configure` | `libuavs3e_encoder_deps="libuavs3e"` | 编码器组件的依赖关系 |
| `configure` | `require_pkg_config libuavs3e ...` | 探测库是否存在 |
| `libavcodec/Makefile` | 加 `OBJS-$(CONFIG_LIBUAVS3E_ENCODER) += libuavs3e.o` | 编译单元 |
| `libavcodec/allcodecs.c` | 加 `extern const FFCodec ff_libuavs3e_encoder;` | **必需**，见下 |
| `libavcodec/libuavs3e.c` | 新增封装实现 | 编码器主体 |

> `allcodecs.c` 里那行 extern **不是装饰**。configure 是这么取编码器清单的：
> ```sh
> ENCODER_LIST=$(find_things_extern encoder FFCodec libavcodec/allcodecs.c)
> ```
> 删掉它，编码器就不会出现在 `codec_list.c` 里，`--enable-libuavs3e` 会变成空操作。

补丁用**严格锚点替换**（`edit_exact`）而不是 `patch(1)`：锚点必须精确匹配 N 次，
不匹配就立即失败。`patch` 的 fuzz 和 `--forward` 会留下「看起来打了其实没打」的半残状态。

### 9.0.2 的 configure 开关：逐个比对过

本项目用到的 34 个 `--enable-*` / `--disable-*`，在 `configure --help` 的 306 个开关里
逐个比对，只有 `--enable-libuavs3e` 不存在 —— 而它正是补丁 ① 要加的。
其余（`libvpl` / `amf` / `nvenc` / `libsvtav1` / `libharfbuzz` / `libzimg` …）全部有效。

外部库最低版本也重新核对了一遍，我们锁的版本全部达标：

| 库 | 9.0.2 要求 | 本仓库锁定 |
|---|---|---|
| davs2 | `>= 1.6.0` | fork master（`pc_ensure_version 1.6.0` 兜底） |
| uavs3d | `>= 1.1.41` | `v1.1`（`pc_ensure_version 1.1.41` 兜底） |
| xavs2 | `>= 1.3.0` | 1.4 |
| dav1d / vpx / SvtAv1Enc / aom | `>= 1.0.0 / 1.4.0 / 0.9.0 / 2.0.0` | 1.5.4 / 1.15.0 / 2.3.0 / v3.10.0 |
| libass / zimg / srt | `>= 0.11.0 / 2.7.0 / 1.3.0` | 0.17.5 / 3.0.5 / 1.5.4 |
| openssl | `>= 3.0.0`（需 `--enable-version3`） | 3.0.15 + `--enable-version3` |
| ffnvcodec / vpl | `>= 12.1.14.0 / 2.6` | n12.2.72.0 / 2.13.0 |
| x264 / x265 | `X264_BUILD >= 163` / `X265_BUILD >= 89` | stable 分支 / 3.4 |

---

## 3. 产物

| 平台 | runner | 产物 | 说明 |
|---|---|---|---|
| Windows x86_64 | `windows-latest` + MSYS2 UCRT64 | `ffmpeg.exe` `ffprobe.exe` `ffplay.exe` | 全静态，不依赖任何 DLL |
| Linux x86_64 | Alpine 3.20 + **musl** | `ffmpeg` `ffprobe` | 全静态（`ldd` 显示 not a dynamic executable） |
| Android armv7 | ubuntu + **NDK r25c** | `ffmpeg` | API 19（Android 4.4.2），单文件 |
| Android arm64 | 同上 | `ffmpeg` | API 21（Android 5.0） |

### 最近一次构建实测（tag `v9.0.2-avs.1`，2026-10-28）

| job | 耗时 | 结果 |
|---|---|---|
| windows-x86_64 | 36 min | success |
| linux-x86_64-static | 22 min | success |
| android-arm64 | 9 min | success |
| android-armv7 | 15 min | success |
| release | <1 min | success（4 个 zip + SHA256SUMS） |

产物下载到本机复验：

| 检查项 | 结果 |
|---|---|
| `ffprobe -version` | `ffprobe version 9.0.2` ✔（不是 commit sha，见下方说明） |
| 4K AVS2 解码 4 秒 | 127 帧，无新增错误 ✔ |
| AC-3 音轨 | `ac3, 48000 Hz, 5.1` ✔ |
| 色彩信令 | `bt2020 / arib-std-b67 / bt2020nc` ✔ |
| AVS3 编码→解码往返 | 编码 40K，解回 25 帧 ✔ |
| AVS2 编码（xavs2） | 48K，色彩仍 `unknown`（反向对照）✔ |
| stdout 干净度 | NUT 魔数完整，`libuavs3d` 横幅在 stderr ✔ |
| linux `ffmpeg`/`ffprobe` | ELF64 x86-64，**无 PT_INTERP / 无 PT_DYNAMIC** = 纯静态 ✔ |
| SHA256 | 与 release 的 `SHA256SUMS.txt` 逐字节一致 ✔ |

### 为什么 Linux 必须用 musl

glibc 静态链接后 `getaddrinfo` / NSS 会在**运行时**静默失败（dlopen 不到 `libnss_*`），
DNS 直接不工作 —— `http`/`rtmp`/`srt` 全部失效，而且报错现场离原因很远。
musl 没这个问题，代价是整个 libc 要换掉。

### 为什么 Android 叫「单文件」而不是「全静态」

bionic 不能静态链（会丢 TLS/atfork，运行时随机崩，官方不支持）。所以 Android 产物是
**一个二进制 + 依赖系统自带的 libc/libm/libdl/liblog**，除 libc 外全部静态。
放到 `/data/local/tmp` 就能 `./ffmpeg` 跑，不需要 root。

---

## 4. 能力清单

`--enable-gpl`（GPL v2），包含：

- **AVS**：`libdavs2`(10bit 超集) `libxavs2` `libuavs3d`(10bit) `libuavs3e`(10bit)
- **视频**：`libx264` `libx265` `libdav1d` `libvpx`；可选 `libsvtav1` `libaom` `libwebp`
- **音频**：`libmp3lame` `libvorbis` `libopus`
- **字幕**：`libass` `libfreetype` `libfribidi` `libharfbuzz`
- **缩放/色彩**：`libzimg`（zscale）
- **网络**：`openssl`(TLS) `libsrt`
- **硬件编码（仅 Windows）**：`nvenc`/`nvdec` `amf` `QSV`(libvpl)
- **播放器**：`ffplay`（仅 Windows，SDL2）

### 明确的取舍

**没有 fdk-aac。** 它的许可与 GPL 不兼容，要 `--enable-nonfree` 才能编，而 nonfree 产物
**不可再分发**。AAC 用 FFmpeg 自带编码器。需要 fdk-aac 就自己改 `LICENSE_GPL=0`。

**x265 只有 8bit。** x265 一个构建只出一个位深。gyan 那种「一个库支持 8/10/12bit」
是 `make multi-lib` 把三份对象合并，依赖上游 `multilib.mak`，跨平台可用性差。
10bit HEVC 需要另编一份 `-DHIGH_BIT_DEPTH=ON` 的 x265 并单独发版。

**xavs2 永远只能 8bit。** 上游硬限制，不是配置问题。

**AVS 的色彩/HDR 信令是补出来的。** 上游两条链路都把色彩信息丢了，本仓库把它接回来：

- `davs2`：AVS2 的色彩描述（`colour_primaries` / `transfer_characteristics` /
  `matrix_coefficients`）不在序列头里，而在**序列显示扩展**（`0xB5`，扩展 id = 2）。
  上游 `parse_header()` 对 `SC_EXTENSION` 一律 `skip this unit`，所以这些值从来没被读过，
  `ffprobe` 对任何 AVS2 流都报 `unknown`。本仓库补了一段解析，并把结果接到
  `AVCodecContext`（见 `scripts/libs/avs.sh` 的 `patch_davs2_colour`）。
- `uavs3d`：v1.1 的 `parser.c` **本来就在读** `colour_description`，但读完直接丢弃，
  `com_seqh_t` 里没有成员可存，于是 FFmpeg 的 `libuavs3d.c` 编不过。本仓库给
  `com_seqh_t` 补了同名同序的四个字段（不升 1.2，避免其 CMakeLists 的 armv7 分支
  强制 `-mfloat-abi=hard` 打坏 Android softfp 构建）。

**实测**（深圳卫视 4K 组播，AVS2 Main10，3840x2160 yuv420p10le，9.0.2 产物）：

```
$ ffprobe -select_streams v:0 -show_entries stream=color_primaries,color_transfer,color_space \
           -of default=nw=1 录制.ts

color_primaries=bt2020
color_transfer=arib-std-b67
color_space=bt2020nc
```

即 **BT.2020 + HLG**。未打补丁的 FFmpeg 对这条流这三个值全是 `unknown`，播放器只能按
BT.709/SDR 解释，画面会偏淡偏灰。

反向对照（说明补丁**不会凭空造色彩**）：用本仓库的 `xavs2` 自编一个 AVS2 流，它不带
序列显示扩展，`ffprobe` 报的仍然是三个 `unknown` —— 只有码流里真的有
`colour_description=1` 才写值。

`color_range` 仍是 `unknown`：序列显示扩展里还有一位 `sample_range`，实测这条流是
`0`（limited），而 FFmpeg 对 `yuv420p10le` 默认也按 limited 处理，所以没有映射它 ——
映射错了反而会让画面偏色，宁可不做。

**AVS3 侧的色彩没有真实样本可验。** `uavs3d` 那条链路补的是 `com_seqh_t` 的字段搬运，
代码路径与 FFmpeg 自带的 AVS3 解码器一致（映射表逐项照抄 `libavcodec/avs3.h`），
但手上没有 AVS3 广播流，只能用「AVS3 编解码往返仍然正常」证明没有打断原有功能。

**编码侧仍不写色彩。** `xavs2` 的序列显示扩展字段在上游是注释掉的，本仓库没有补，
所以自编的 AVS2 流仍不带 colour_description。解码侧不受影响。

**Android 不启用硬编解码。** `mediacodec` 需要 JVM 上下文，静态 CLI 里开了也跑不通。

---

## 5. 目录结构

```
scripts/
  env.sh            版本锁 —— 所有依赖的版本/URL 只在这里出现
  lib.sh            fetch / autotools / cmake / meson / edit_exact / .pc 工具
  build-ffmpeg.sh   FFmpeg configure 参数组装 + 防静默失败断言
  build-common.sh   构建顺序、打包、冒烟测试、交叉产物结构验证
  patch-ffmpeg.sh   AVS3 编码器补丁（6 处锚点替换）
  libs/avs.sh       davs2 / xavs2 / uavs3d / uavs3e
  libs/video.sh     x264 / x265 / dav1d / libvpx / svt-av1 / aom / webp
  libs/audio.sh     lame / ogg / vorbis / opus
  libs/misc.sh      zlib / openssl / expat / fontconfig / freetype /
                    fribidi / harfbuzz / libass / zimg / srt / sdl2
  build-windows.sh  build-linux.sh  build-android.sh
  verify-urls.sh    依赖地址可达性自检
  etr290.py         流体检入口（抓流 + TSDuck analyze + 出报告）
  etr290_report.py  analyze 的 JSON -> TR 101 290 判定
patches/
  libuavs3e.c       AVS3 编码器封装（约 300 行）
.github/workflows/
  build.yml         4 个并行 job + tag 自动发 Release
```

**一套依赖脚本 + 三套工具链**：库脚本只认 `CC CXX AR RANLIB STRIP CFLAGS LDFLAGS PREFIX`
和 `autotools_build` / `cmake_build` / `meson_build`，平台差异全部收敛在 `build-*.sh` 里。
改一个库只改一处。

---

## 6. 构建

### 本地（Windows / MSYS2 UCRT64）

```bash
pacman -S --needed base-devel mingw-w64-ucrt-x86_64-toolchain \
    mingw-w64-ucrt-x86_64-nasm mingw-w64-ucrt-x86_64-cmake \
    mingw-w64-ucrt-x86_64-meson mingw-w64-ucrt-x86_64-ninja \
    mingw-w64-ucrt-x86_64-pkgconf autoconf automake libtool python zip
./scripts/build-windows.sh
```

### 本地（Linux / musl）

```bash
docker run --rm -v "$PWD":/src -w /src alpine:3.20 sh -c '
  apk add --no-cache bash build-base linux-headers nasm cmake meson ninja \
      pkgconf perl autoconf automake libtool git curl python3 zip file binutils &&
  bash ./scripts/build-linux.sh'
```

### 本地（Android）

```bash
ANDROID_NDK_HOME=/opt/ndk-r25c ./scripts/build-android.sh armv7
ANDROID_NDK_HOME=/opt/ndk-r25c ./scripts/build-android.sh arm64
```

### CI

推送 / 手动触发即构建；打 `v*` tag 会把四个产物 + `SHA256SUMS.txt` 挂到 Release。

---

## 7. 构建期做了什么验证

光「编过了」不算数。每次构建都会跑：

1. **configure 回读断言** —— FFmpeg 的 `--enable-xxx` 找不到库时**不报错、只静默关掉**。
   所以 configure 之后必须回读 `config_components.h`：
   `CONFIG_LIBDAVS2_DECODER` / `CONFIG_LIBUAVS3D_DECODER` /
   `CONFIG_LIBUAVS3E_ENCODER` / `CONFIG_LIBXAVS2_ENCODER` 必须全为 1。
2. **冒烟测试（Windows / Linux）** —— `-codecs` 断言四个 AVS 编解码器带对应库名；
   然后用 `testsrc2` 真跑一次 `libuavs3e` 编码，再解回来核对。
3. **交叉产物结构验证（Android）** —— ARM 二进制在 x86 runner 上执行不了，
   所以改为静态取证：ELF 架构对不对、`NEEDED` 里有没有混进主机库、
   二进制里有没有 `libuavs3e` / `libdavs2` 符号。
4. **静态性验证（Linux）** —— `ldd` 必须是 `not a dynamic executable`。

---

## 8. 流体检工具：TR 101 290（ETR 290）

`scripts/etr290.py` 一条命令做「抓流 → TSDuck `analyze` → TR 101 290 判定」：

```bash
# 实时组播抓 30 秒
python scripts/etr290.py 230.177.0.28:3028 --local-address 10.222.132.199

# 抓 60 秒，并把 analyze 的原始 JSON 留下来备查
python scripts/etr290.py 230.177.0.28:3028 --seconds 60 --keep out.json

# 现成录像离线体检（不联网）
python scripts/etr290.py 录制.ts

# 手上已经有 analyze JSON，只想出报告
python scripts/etr290.py out.json
```

退出码：`0` 优先级 1/2 全过，`1` 有硬错，`2` 抓包/分析本身失败（会列原因清单）。
依赖 TSDuck 的 `tsp`。Windows 装完默认在 `C:\tsduck\bin\tsp.exe`；找不到会自动搜
PATH、`$TSDuck_HOME`、常见安装目录，也可以用 `--tsp` 指定。

实测（深圳卫视 4K 组播，20 秒 / 505,337 包 / 38.00 Mbps CBR）：

```
  PID       角色           码率Mbps        包数   CC错误   重复包 PES非法
  0x0077    视频             36.000     478,736        0        0       0
  0x0078    音频              0.470       6,250        0        0       0
  ...
判定
  CC 错误率         : 0.000000%（0 / 505,337）
  [PASS] TR 101 290 优先级 1/2 全部通过
```

能覆盖哪些项、覆盖不了哪些项（`analyze` 拿不到 PCR 抖动精度 ±500 ns 和部分描述符
语法检查，那两项要专用分析仪），都写在 `scripts/etr290_report.py` 开头的文档注释里。

> 两个实现细节值得记一笔：`-P until --seconds N` 只在有数据流过时才计时，
> 所以组播没流的时候 `tsp` 会永远阻塞在 recv 上 —— 脚本外面另掐了一个硬超时兜底；
> 另外 TSDuck 只在「exe 自身目录」和当前目录找 `tsduck.dtv.names`，从别处调用会先甩
> 一行 `Error: error opening file ...dtv.names` 吓人（其实不影响分析），脚本把
> cwd 切到了 tsp 目录来消掉它。

---

## 9. 已知限制

| # | 限制 | 影响 |
|---|---|---|
| 1 | Android 需 NDK **r25c**（r26 起不支持 API 19） | 想升 NDK 就必须放弃 4.4.2 |
| 2 | NDK r24+ 的 armv7 sysroot 按 NEON 编译 | 无 NEON 的老芯片（部分 MTK/全志盒子）跑不起来 |
| 3 | davs2 的 10bit SIMD 只有 x86 版 | ARM 上走纯 C，解码慢 3~5 倍（结果正确） |
| 4 | x265 只有 8bit | 10bit HEVC 编码不可用 |
| 5 | xavs2 只有 8bit | AVS2 10bit 编码不可用（上游限制） |
| 6 | aom 官方源在国内常不可达 | 可选库，默认关闭，不影响 AVS |
| 7 | AVS3 色彩透出没有真实广播流可验 | 代码路径与 FFmpeg 自带 AVS3 解码器一致，只验证了「不破坏原有编解码」 |
| 8 | `color_range` 不映射 `sample_range` | 实测流该位为 0（limited），FFmpeg 默认也按 limited 处理，硬映射反而可能偏色 |
| 9 | 版本串靠写 `VERSION` 文件压住 | GitHub 的 tag tarball 无 `.git`，`ffbuild/version.sh` 的 `git describe` 会向上命中本仓库 `.git`，产物版本串变成 commit sha（实测 `f052ad4`）。构建脚本在 configure 前写 `VERSION` 修正 |

---

### 9.1 与 6.1.6 仓库的差异

两个仓库脚本同源，但**不是只有版本号不同**。已知差异：

| 项 | 本仓（9.0.2） | `ffmpeg-avs-bin-6`（6.1.6） | 原因 |
|---|---|---|---|
| FFmpeg 版本 | 9.0.2 | 6.1.6 | 主线不同 |
| drawvg 滤镜 | ✅ 有 | ❌ 无 | 6.1 主线 configure 里没有 drawvg，装了 cairo 也无用武之地 |
| cairo / pixman | ✅ 构建 | ❌ 不构建 | 同上 |
| AMF 版本 | 1.5.2 | 1.4.33 | 门槛不同：9.0 要求 `MINOR>=5`，6.1 只要求 `MINOR>=4 且 RELEASE>=29`；1.4.33 满足 6.1 但不满足 9.0 |
| 上游巡检 workflow | ✅ 有 | ❌ 无 | 6.1 是 EOL 主线，巡检无意义 |

硬件编码器（nvenc / qsv / amf）两边都有。

---

## 10. 许可证

本项目为 **GPL v2**。产物包含 GPL v2 的 `x264` / `x265` / `davs2` / `xavs2`，
因此**产物整体按 GPL v2 分发**。打包时会自动附带 FFmpeg 源码树里的
`COPYING.GPLv2` 全文（不自己抄，保证与上游逐字一致）。

各依赖的许可证以其上游为准。`patches/libuavs3e.c` 源自 `LuoZijun/FFmpeg` 的
`patch-avs3` 分支，遵循其原始许可。
