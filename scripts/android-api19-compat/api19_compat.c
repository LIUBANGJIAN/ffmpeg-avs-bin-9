/*
 * Android API < 21 的 libc++ 兼容垫片
 * ============================================================================
 * 现象（run#22 android-armv7：NDK r25c，armv7a-linux-androideabi19）：
 *
 *   ld: error: undefined symbol: mbsnrtowcs
 *   >>> referenced by __bsd_locale_fallbacks.h:67
 *   >>>      locale.o:(__libcpp_mbsnrtowcs_l(...)) in archive
 *            .../sysroot/usr/lib/arm-linux-androideabi/libc++_static.a
 *   ld: error: undefined symbol: mbtowc / localeconv / strtoll_l /
 *            strtoull_l / strtold_l / wcstoll / wcstoull / wcstof
 *
 * 根因：NDK 里的 libc++_static.a 是**面向 API 21 编的**，它的 locale.o 直接
 * 引用了 bionic 直到 21 才提供的那批 locale 函数。同一份 FFmpeg 在
 * android-arm64（API 21）上一把过，在 API 19 上必然链接失败 —— 与我们自己的
 * 代码无关，是「用 C++ 静态库」这个前提在 API 19 上被打断了。
 *
 * 处理：给这 9 个符号补一份最小实现。bionic 只支持 "C"/POSIX 与 UTF-8，
 * 语义可以放心简化：数值解析一律转给不带 locale 的版本，宽字符按 UTF-8 解。
 * 这些函数 FFmpeg 自己一次都不会调用（它们只服务于 libc++ 的 std::locale），
 * 但必须存在，否则链接过不去。
 *
 * 注意：本文件**故意不 include 任何系统头文件**。NDK unified header 里这些
 * 函数是「声明了、但带 __INTRODUCED_IN(21)」，在 __ANDROID_API__ < 21 的
 * 编译单元里一提到就报 `is unavailable: introduced in Android 21`。
 * 所以我们自带类型，绕开那套可用性标注。参数只用「指针 / 定宽整数」，
 * 与真实原型 ABI 完全一致。
 *
 * 只给 32 位 API 19 用（armv7）。arm64 是 API 21，不需要也不会编这份。
 */

/* ---- 复用 API 19 已经有的函数（只声明，不引头文件）--------------------- */
extern long long strtoll(const char *s, char **end, int base);
extern unsigned long long strtoull(const char *s, char **end, int base);
extern double strtod(const char *s, char **end);

/* bionic 的 wchar_t 是 4 字节有符号整数；这里用 int 表示，指针参数 ABI 一致 */
typedef int wc_t;

/* 本文件里 size_t 的角色（LP64 / ILP32 下都与 unsigned long 同宽） */
typedef unsigned long usize_t;

/* ==========================================================================
 * 1) 数值解析的 _l 变体
 *    bionic 的 locale 只有 "C"，_l 参数没有任何作用，转发即可。
 * ========================================================================== */
long long strtoll_l(const char *s, char **end, int base, void *loc)
{
    (void)loc;
    return strtoll(s, end, base);
}

unsigned long long strtoull_l(const char *s, char **end, int base, void *loc)
{
    (void)loc;
    return strtoull(s, end, base);
}

/* 用 strtod 升精度实现：API 19 未必有 strtold，但一定有 strtod */
long double strtold_l(const char *s, char **end, void *loc)
{
    (void)loc;
    return (long double)strtod(s, end);
}

/* ==========================================================================
 * 2) 宽字符数字解析：把 ASCII 记号收窄后交给 strtoll/strtoull/strtod
 *    C locale 下宽字符数字就是 ASCII，非 ASCII 一律视为记号结束。
 * ========================================================================== */
static usize_t wc_token(const wc_t *s, char *buf, usize_t cap)
{
    usize_t i = 0;

    if (cap == 0) {
        return 0;
    }
    while (s[i] != 0 && i + 1 < cap) {
        int c = s[i];
        if (c < 0 || c > 0x7f) {
            break;
        }
        buf[i] = (char)c;
        i++;
    }
    buf[i] = '\0';
    return i;
}

long long wcstoll(const wc_t *s, wc_t **end, int base)
{
    char buf[64];
    char *e = buf;

    wc_token(s, buf, (usize_t)sizeof(buf));
    {
        long long v = strtoll(buf, &e, base);
        if (end) {
            *end = (wc_t *)(s + (e - buf));
        }
        return v;
    }
}

unsigned long long wcstoull(const wc_t *s, wc_t **end, int base)
{
    char buf[64];
    char *e = buf;

    wc_token(s, buf, (usize_t)sizeof(buf));
    {
        unsigned long long v = strtoull(buf, &e, base);
        if (end) {
            *end = (wc_t *)(s + (e - buf));
        }
        return v;
    }
}

float wcstof(const wc_t *s, wc_t **end)
{
    char buf[128];
    char *e = buf;

    wc_token(s, buf, (usize_t)sizeof(buf));
    {
        double v = strtod(buf, &e);
        if (end) {
            *end = (wc_t *)(s + (e - buf));
        }
        return (float)v;
    }
}

/* ==========================================================================
 * 3) 多字节 → 宽字符
 *    bionic 只有 "C" 与 UTF-8 两种 locale，这里按 UTF-8 解，非法序列按
 *    POSIX 返回 -1。
 * ========================================================================== */
int mbtowc(wc_t *pwc, const char *s, usize_t n)
{
    unsigned char c;
    int cnt, i, cp;

    if (s == 0) {
        return 0; /* 复位状态：本实现无状态 */
    }
    if (n == 0) {
        return -1;
    }
    c = (unsigned char)s[0];
    if (c == 0) {
        if (pwc) {
            *pwc = 0;
        }
        return 0;
    }
    if (c < 0x80) {
        if (pwc) {
            *pwc = (int)c;
        }
        return 1;
    } else if ((c & 0xe0) == 0xc0) {
        cnt = 2; cp = c & 0x1f;
    } else if ((c & 0xf0) == 0xe0) {
        cnt = 3; cp = c & 0x0f;
    } else if ((c & 0xf8) == 0xf0) {
        cnt = 4; cp = c & 0x07;
    } else {
        return -1;
    }
    if ((usize_t)cnt > n) {
        return -1;
    }
    for (i = 1; i < cnt; i++) {
        unsigned char cc = (unsigned char)s[i];
        if ((cc & 0xc0) != 0x80) {
            return -1;
        }
        cp = (cp << 6) | (cc & 0x3f);
    }
    if (pwc) {
        *pwc = cp;
    }
    return cnt;
}

usize_t mbsnrtowcs(wc_t *dst, const char **src, usize_t nmc, usize_t len, void *ps)
{
    const char *s = *src;
    usize_t count = 0;

    (void)ps;
    if (s == 0) {
        return 0;
    }
    while (nmc > 0) {
        int n;
        int cp = 0;

        if (dst != 0 && count >= len) {
            break; /* 目标缓冲区满，保留 *src 指向下一个待转换字节 */
        }
        n = mbtowc(dst ? &cp : 0, s, nmc);
        if (n < 0) {
            if (dst) {
                *src = s;
            }
            return (usize_t)-1;
        }
        if (n == 0) {
            if (dst) {
                dst[count] = 0;
            }
            *src = 0; /* 按 POSIX：写入了 L'\0'，*src 置为 NULL */
            return count;
        }
        if (dst) {
            dst[count] = cp;
        }
        count++;
        s += n;
        nmc -= (usize_t)n;
    }
    *src = s;
    return count;
}

/* ==========================================================================
 * 4) localeconv：C locale 的那一份常量表
 *    字段顺序与 bionic/glibc 的 struct lconv 一致（decimal_point 在最前，
 *    也是 libc++ 唯一真正会读的字段）。
 * ========================================================================== */
struct api19_lconv {
    char *decimal_point;
    char *thousands_sep;
    char *grouping;
    char *int_curr_symbol;
    char *currency_symbol;
    char *mon_decimal_point;
    char *mon_thousands_sep;
    char *mon_grouping;
    char *positive_sign;
    char *negative_sign;
    char int_frac_digits;
    char frac_digits;
    char p_cs_precedes;
    char p_sep_by_space;
    char n_cs_precedes;
    char n_sep_by_space;
    char p_sign_posn;
    char n_sign_posn;
    char int_p_cs_precedes;
    char int_p_sep_by_space;
    char int_n_cs_precedes;
    char int_n_sep_by_space;
    char int_p_sign_posn;
    char int_n_sign_posn;
};

struct api19_lconv *localeconv(void)
{
    static struct api19_lconv lc;

    lc.decimal_point = (char *)".";
    lc.thousands_sep = (char *)"";
    lc.grouping = (char *)"";
    lc.int_curr_symbol = (char *)"";
    lc.currency_symbol = (char *)"";
    lc.mon_decimal_point = (char *)"";
    lc.mon_thousands_sep = (char *)"";
    lc.mon_grouping = (char *)"";
    lc.positive_sign = (char *)"";
    lc.negative_sign = (char *)"";
    /* C locale 下所有 *_digits / 位置标志都是 CHAR_MAX（127） */
    lc.int_frac_digits = 127;
    lc.frac_digits = 127;
    lc.p_cs_precedes = 127;
    lc.p_sep_by_space = 127;
    lc.n_cs_precedes = 127;
    lc.n_sep_by_space = 127;
    lc.p_sign_posn = 127;
    lc.n_sign_posn = 127;
    lc.int_p_cs_precedes = 127;
    lc.int_p_sep_by_space = 127;
    lc.int_n_cs_precedes = 127;
    lc.int_n_sep_by_space = 127;
    lc.int_p_sign_posn = 127;
    lc.int_n_sign_posn = 127;
    return &lc;
}

/* ==========================================================================
 * 5) locale 对象三件套 + 宽→窄转换
 *    补完第 3 节那 9 个符号之后，run#23 的链接测试又报出这一批：
 *      ld: error: undefined symbol: uselocale / newlocale / freelocale
 *      >>> referenced by __locale:54
 *      >>>    locale.o:(__libcpp_sscanf_l / __libcpp_snprintf_l / ...)
 *      ld: error: undefined symbol: wcsnrtombs
 *    它们在 bionic 里同样是 API 21 才有的。libc++ 的用法是
 *    `locale_t old = uselocale(l); ...; uselocale(old);` ——
 *    我们只需要「能存能还」，不需要真的切换 LC_*。
 * ========================================================================== */
static int api19_dummy_locale; /* 只当令牌用，绝不按 struct 解引用 */

void *newlocale(int category_mask, const char *name, void *base)
{
    (void)category_mask;
    (void)name;
    (void)base;
    return (void *)&api19_dummy_locale;
}

void freelocale(void *loc)
{
    (void)loc;
}

void *uselocale(void *loc)
{
    static void *current;
    void *prev = current;

    if (loc != 0) { /* 传 0 表示「只查询」，不改 */
        current = loc;
    }
    return prev;
}

/* 宽字符 → UTF-8 */
static int wc_to_utf8(unsigned int cp, unsigned char *buf)
{
    if (cp < 0x80) {
        buf[0] = (unsigned char)cp;
        return 1;
    } else if (cp < 0x800) {
        buf[0] = (unsigned char)(0xc0 | (cp >> 6));
        buf[1] = (unsigned char)(0x80 | (cp & 0x3f));
        return 2;
    } else if (cp < 0x10000) {
        buf[0] = (unsigned char)(0xe0 | (cp >> 12));
        buf[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
        buf[2] = (unsigned char)(0x80 | (cp & 0x3f));
        return 3;
    }
    buf[0] = (unsigned char)(0xf0 | (cp >> 18));
    buf[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3f));
    buf[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
    buf[3] = (unsigned char)(0x80 | (cp & 0x3f));
    return 4;
}

usize_t wcsnrtombs(char *dst, const wc_t **src, usize_t nwc, usize_t len, void *ps)
{
    const wc_t *s;
    usize_t count = 0;

    (void)ps;
    if (!src || !*src) {
        return 0;
    }
    s = *src;
    while (nwc > 0) {
        unsigned char buf[4];
        int n, i;

        if (s[0] == 0) {
            if (dst == 0) {
                break;
            }
            if (count < len) {
                dst[count] = '\0';
                *src = 0; /* 按 POSIX：写了结尾 NUL，*src 置 NULL */
                return count;
            }
            break;
        }
        n = wc_to_utf8((unsigned int)s[0], buf);
        if (dst != 0 && count + (usize_t)n > len) {
            break;
        }
        if (dst) {
            for (i = 0; i < n; i++) {
                dst[count + (usize_t)i] = (char)buf[i];
            }
        }
        count += (usize_t)n;
        s++;
        nwc--;
    }
    *src = s;
    return count;
}

usize_t wcsrtombs(char *dst, const wc_t **src, usize_t len, void *ps)
{
    /* 与 wcsnrtombs 等价，只是没有宽字符数上限 */
    return wcsnrtombs(dst, src, (usize_t)-1, len, ps);
}

/* 顺手补上同一批 BSD fallback 会用到的窄→宽/宽→窄单字符版本。
   它们同样只在「符号真的缺」时才会被链接器从归档里取出来。 */
usize_t mbrtowc(wc_t *pwc, const char *s, usize_t n, void *ps)
{
    int r;

    (void)ps;
    if (s == 0) {
        return 0; /* 复位状态 */
    }
    r = mbtowc(pwc, s, n);
    if (r < 0) {
        /* 区分「非法序列」和「字节不够」：看首个字节声明的长度 */
        if (n > 0) {
            unsigned char c = (unsigned char)s[0];
            int need = 1;

            if ((c & 0xe0) == 0xc0) {
                need = 2;
            } else if ((c & 0xf0) == 0xe0) {
                need = 3;
            } else if ((c & 0xf8) == 0xf0) {
                need = 4;
            }
            if (need > 1 && (usize_t)need > n) {
                return (usize_t)-2;
            }
        }
        return (usize_t)-1;
    }
    return (usize_t)r;
}

usize_t wcrtomb(char *s, wc_t wc, void *ps)
{
    unsigned char buf[4];
    int n, i;

    (void)ps;
    if (s == 0) {
        return 1; /* 传 NULL 只做状态查询 */
    }
    n = wc_to_utf8((unsigned int)(wc & 0x7fffffff), buf);
    for (i = 0; i < n; i++) {
        s[i] = (char)buf[i];
    }
    return (usize_t)n;
}

usize_t mbsrtowcs(wc_t *dst, const char **src, usize_t len, void *ps)
{
    const char *s;
    usize_t count = 0;

    (void)ps;
    if (!src || !*src) {
        return 0;
    }
    s = *src;
    for (;;) {
        int cp = 0;
        usize_t n;

        if (dst != 0 && count >= len) {
            break;
        }
        n = mbrtowc(dst ? &cp : 0, s, 4, 0);
        if (n == (usize_t)-1) {
            *src = s;
            return (usize_t)-1;
        }
        if (n == (usize_t)-2) {
            break;
        }
        if (n == 0) {
            if (dst) {
                dst[count] = 0;
            }
            *src = 0;
            return count;
        }
        if (dst) {
            dst[count] = cp;
        }
        count++;
        s += n;
    }
    *src = s;
    return count;
}

int mbsinit(const void *ps)
{
    (void)ps;
    return 1; /* 本实现无状态 */
}
