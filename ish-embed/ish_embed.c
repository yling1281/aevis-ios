/*
 * ============================================================================
 *  AEVIS · iSH 内核「宿主入口层」实现
 *  ----------------------------------------------------------------------------
 *  这个文件把 libish.a 里那套内核**包成** ish_embed.h 暴露的窄接口。
 *
 *  它在 iSH 源码树里被编进 libish（见 CI 的 meson 补丁），所以：
 *    · 它**可以** include iSH 的头（这是内部实现）；
 *    · 它编出来的目标文件同时进 iOS 静态库与宿主 macOS 静态库；
 *    · 上游源码**一个字都不改**，所有 iSH 符号都只用上游「本来就导出」的那些。
 *
 *  关键事实（都已对着 pin commit 54ca185b 的头文件核过，行号见报告）：
 *    · task_run_current() 阻塞主循环（kernel/task.c:152），用线程局部 current
 *      ⇒ boot 与主循环必须同线程。
 *    · create_piped_stdio()（kernel/init.c:196）把 guest fd 0/1/2 映射到宿主
 *      真实的 0/1/2 ⇒ 我们先用 dup2 把管道套到宿主 0/1/2 上。
 *    · printk 走宿主 fd 666（kernel/log.c:138-143）⇒ 也要 dup2 过去，否则内核日志丢。
 *    · 常驻 shell 是 guest 的 init（pid 1）；init 一退出，do_exit 会走
 *      halt_system() → _exit(0)（kernel/exit.c:155-157, 402）⇒ 整个宿主进程没了。
 *      所以命令一律用子 shell 包起来，绝不让 init 退出。
 *
 *  ⚠️ 同步：**不用 POSIX 信号量**。macOS / iOS 的 Darwin 内核**没有实现
 *     sem_timedwait()**（调用即 ENOSYS），而本层必须带超时等待。
 *     所以统一用 pthread_mutex + pthread_cond_timedwait（两个平台都完整支持，
 *     且可用 PTHREAD_COND_INITIALIZER 静态初始化，不需要 constructor）。
 * ============================================================================
 */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "aevis_ish_embed.h"   /* 本层对外 API（自包含，不含 iSH 头） */

/* —— 只用到「本来就导出」的 iSH 符号 —— */
#include "kernel/init.h"       /* mount_root / become_first_process / create_piped_stdio / set_console_device */
#include "kernel/calls.h"      /* do_execve（并顺带拉进 kernel/fs.h、fs/sock.h、fs/fd.h） */
#include "kernel/fs.h"         /* fakefs / procfs / devptsfs / do_mount / generic_mknodat / generic_mkdirat / generic_setattrat */
#include "kernel/task.h"       /* current / task_run_current / exit_hook */
#include "fs/devices.h"        /* MEM_MAJOR / DEV_*_MINOR / TTY_CONSOLE_MAJOR / TTY_ALTERNATE_MAJOR */
#include "fs/dev.h"            /* dev_make() */
#include "fs/path.h"           /* AT_PWD */
#include "fs/tty.h"            /* tty_drivers[] / real_tty_driver */
#include "fs/sock.h"           /* sock_tmp_prefix */
#include "debug.h"             /* die_handler */

/* ---------------------------------------------------------------------------
 * 常量
 * ------------------------------------------------------------------------- */
#define AEVIS_ISH_VERSION_STR  "iSH asbestos 2026-10-06 (GPL-3.0)"

/* 退出码哨兵标记。aevis_ish_run 里禁止命令本身包含它，防止伪造。 */
#define AEVIS_RC_MARKER        "__AEVIS_RC__="

/* 命令包装：子 shell + 哨兵行。
 * ⚠️ 用 ( ... ) 而不是 { ... }：init 一旦退出 → halt_system() → _exit(0)；
 *    子 shell 把 `exit N` / `exec` 的影响关在里面。 */
#define AEVIS_RUN_PREFIX       "(\n"
#define AEVIS_RUN_SUFFIX       "\n)\nprintf '__AEVIS_RC__=%d\\n' $?\n"

/* printk 专用宿主 fd（kernel/log.c 里写死 666）。 */
#define AEVIS_ISH_PRINTK_FD    666

/* boot 等待上限（毫秒）。 */
#define AEVIS_BOOT_TIMEOUT_MS  30000

/* ---------------------------------------------------------------------------
 * 共享状态
 * ---------------------------------------------------------------------------
 * 全部静态存储；锁与条件变量都用静态初始化宏（Darwin 支持）。
 */
static pthread_mutex_t g_lock      = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_boot_cond = PTHREAD_COND_INITIALIZER; /* boot 就绪 */
static pthread_cond_t  g_done_cond = PTHREAD_COND_INITIALIZER; /* 命令跑完 */

static int  g_boot_started   = 0;        /* 是否已经发起过 boot（只允许一次） */
static int  g_boot_ready     = 0;        /* boot 是否已经出结果（成功或失败） */
static int  g_is_booted      = 0;        /* 0/1 */
static int  g_busy           = 0;        /* 0/1 当前命令是否在跑 */
static int  g_dead           = 0;        /* 内核/shell 是否已判死 */
static int  g_last_rc        = -1;       /* 上一条命令退出码 */
static int  g_boot_rc        = AEVIS_ISH_OK; /* boot 结果 */

static int  g_cmd_pipe[2]    = { -1, -1 };   /* 宿主写 → guest 读 */
static int  g_out_pipe[2]    = { -1, -1 };   /* guest 写 → 宿主读 */

static pthread_t g_boot_thread;          /* boot + 内核主循环线程 */
static pthread_t g_reader_thread;        /* 输出读取线程 */

/* 累积输出（互斥保护） */
static char  *g_out_buf      = NULL;
static size_t g_out_len      = 0;
static size_t g_out_cap      = 0;

/* 「当前行」缓冲（只有读取线程碰它；仍在 g_lock 下处理） */
static char  *g_line         = NULL;
static size_t g_line_len     = 0;
static size_t g_line_cap     = 0;

/* sock_tmp_prefix 的持久副本（绝不让它指向调用者的栈） */
static char  *g_sock_tmp     = NULL;
/* 传给 boot 线程的 rootfs 路径副本（同样不能指向调用者栈） */
static char  *g_rootfs       = NULL;

/* 最近一次内部错误文案；永远非 NULL */
static char   g_msg[1024]    = "iSH embed: not started";

/* ---------------------------------------------------------------------------
 * 小工具
 * ------------------------------------------------------------------------- */

/* 设置诊断文案（不参与控制流）。可在锁内/锁外调用。 */
static void set_msg(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_msg, sizeof(g_msg), fmt, ap);
    va_end(ap);
    g_msg[sizeof(g_msg) - 1] = '\0';
}

/* 记录 boot 失败：在锁下写结果码 + 文案（**不**唤醒；由线程清理函数统一唤醒）。 */
static void set_boot_fail(int rc, const char *fmt, ...) {
    va_list ap;
    char tmp[1024];
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    tmp[sizeof(tmp) - 1] = '\0';
    pthread_mutex_lock(&g_lock);
    snprintf(g_msg, sizeof(g_msg), "%s", tmp);
    g_boot_rc = rc;
    pthread_mutex_unlock(&g_lock);
}

/* 由「现在」往后 ms 毫秒，算出 CLOCK_REALTIME 的绝对时刻。 */
static struct timespec abs_after_ms(int ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec  += ms / 1000;
    ts.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec  += 1;
        ts.tv_nsec -= 1000000000L;
    }
    return ts;
}

/* 往累积输出尾部追加（调用者需持有 g_lock）。失败就丢弃，绝不崩。 */
static void out_push_locked(const char *data, size_t n) {
    if (n == 0)
        return;
    if (g_out_len + n + 1 > g_out_cap) {
        size_t cap = g_out_cap ? g_out_cap : 4096;
        while (cap < g_out_len + n + 1)
            cap *= 2;
        char *nb = realloc(g_out_buf, cap);
        if (nb == NULL)
            return; /* 宁可丢日志，也不让诊断路径把进程搞崩 */
        g_out_buf = nb;
        g_out_cap = cap;
    }
    memcpy(g_out_buf + g_out_len, data, n);
    g_out_len += n;
    g_out_buf[g_out_len] = '\0';
}

/* 往「当前行」缓冲追加一个字节（只有读取线程调用）。 */
static void line_push_byte(char c) {
    if (g_line_len + 2 > g_line_cap) {
        size_t cap = g_line_cap ? g_line_cap : 256;
        while (cap < g_line_len + 2)
            cap *= 2;
        char *nb = realloc(g_line, cap);
        if (nb == NULL)
            return; /* 丢字节，绝不崩 */
        g_line = nb;
        g_line_cap = cap;
    }
    g_line[g_line_len++] = c;
    g_line[g_line_len] = '\0';
}

/* ---------------------------------------------------------------------------
 * iSH 回调（由内核调用；**只记状态，绝不 exit()/abort()**）
 * ------------------------------------------------------------------------- */

/* exit_hook 签名见 kernel/task.h:216。do_exit 只在「整个线程组死光」时才调它。
 * ⚠️ init（pid 1）退出时，do_exit 会先走 halt_system() → _exit(0)，
 *    根本轮不到本回调；所以这里对 init 的分支是防御性的。 */
static void aevis_ish_on_exit(struct task *task, int code) {
    int is_init = (task != NULL && task->parent == NULL);
    pthread_mutex_lock(&g_lock);
    if (is_init) {
        g_last_rc = (code >> 8) & 0xff;
        g_busy = 0;
        g_dead = 1;
        snprintf(g_msg, sizeof(g_msg), "init shell exited (code=%d)", code);
        pthread_cond_broadcast(&g_done_cond);
    }
    pthread_mutex_unlock(&g_lock);
}

/* die_handler 签名见 debug.h:76。注意：die() 在本回调之后**一定**会 abort()
 * （kernel/log.c:174），所以这里只把消息捞进输出缓冲，不试图阻止 abort。 */
static void aevis_ish_on_die(const char *msg) {
    pthread_mutex_lock(&g_lock);
    if (msg != NULL)
        out_push_locked(msg, strlen(msg));
    out_push_locked("\n", 1);
    snprintf(g_msg, sizeof(g_msg), "kernel die: %s", msg != NULL ? msg : "(null)");
    pthread_mutex_unlock(&g_lock);
}

/* ---------------------------------------------------------------------------
 * 输出读取线程
 * ------------------------------------------------------------------------- */
static void process_line_locked(void) {
    const char *line = (g_line != NULL) ? g_line : "";
    const char *m = strstr(line, AEVIS_RC_MARKER);
    if (m != NULL) {
        /* 哨兵行：标记之前那截属于上一条命令、且没以换行结尾的输出 */
        size_t prefix = (size_t)(m - line);
        if (prefix > 0)
            out_push_locked(line, prefix);
        g_last_rc = atoi(m + strlen(AEVIS_RC_MARKER));
        g_busy = 0;
        pthread_cond_broadcast(&g_done_cond);
        return;
    }
    out_push_locked(line, strlen(line));
    out_push_locked("\n", 1);
}

static void *aevis_ish_reader_main(void *arg) {
    (void)arg;
    char buf[4096];
    for (;;) {
        ssize_t n = read(g_out_pipe[0], buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break; /* 读错误 → 视同 EOF */
        }
        if (n == 0)
            break; /* EOF：所有写端都关了 ⇒ shell/内核死了 */
        pthread_mutex_lock(&g_lock);
        for (ssize_t i = 0; i < n; i++) {
            char c = buf[i];
            if (c == '\n') {
                process_line_locked();
                g_line_len = 0;
                if (g_line != NULL)
                    g_line[0] = '\0';
            } else {
                line_push_byte(c);
            }
        }
        pthread_mutex_unlock(&g_lock);
    }

    /* 收尾：把半行刷出去，并标记「内核死」 */
    pthread_mutex_lock(&g_lock);
    if (g_line_len > 0) {
        out_push_locked(g_line, g_line_len);
        g_line_len = 0;
    }
    g_busy = 0;
    g_dead = 1;
    snprintf(g_msg, sizeof(g_msg), "shell/stdout closed（内核可能已退出）");
    pthread_cond_broadcast(&g_done_cond);
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

/* ---------------------------------------------------------------------------
 * boot 线程
 * ------------------------------------------------------------------------- */
static void aevis_ish_boot_cleanup(void *arg) {
    (void)arg;
    /* 无论正常返回、还是被 pthread_exit/取消打断，都要唤醒等待者 */
    pthread_mutex_lock(&g_lock);
    g_boot_ready = 1;
    pthread_cond_broadcast(&g_boot_cond);
    pthread_mutex_unlock(&g_lock);
}

static void aevis_ish_boot_body(const char *rootfsDir) {
    int err;

    /* =======================================================================
     * ⚠️⚠️ 顺序契约（改本函数前务必读完） ⚠️⚠️
     * -----------------------------------------------------------------------
     * 本函数里，**第一次 guest 侧路径操作必须是下面的 mount_root()**：
     *   fs/mount.c:69 有 assert(!list_empty(&mounts)) —— 在挂上根之前，任何走
     *   通用路径解析的调用都会踩到「空挂载表」。
     * 因此 mount_root() 之前**只允许**「宿主 libc 的 stat / 字符串拼接 / dup2」，
     *   **绝不许**插入 generic_open / generic_statat / fs_chdir 之类 guest 侧调用。
     *
     * mount_root() 的 source 末段目录名**必须恰好叫 `data`**：
     *   fs/fake.c:984 会就地把 source 的 basename strcpy 成 "meta.db" 去找数据库；
     *   传错**不会报错**，而是静默去打开**另一个文件**（这才是最阴的坑）。
     *   所以 aevis_ish_boot() 入口已对 <rootfsDir>/data、<rootfsDir>/meta.db 做 stat 校验。
     *
     * 任何 tty_drivers[...] 的**读取**都必须在下面第 6 步那次赋值
     *   （tty_drivers[TTY_CONSOLE_MAJOR] = &real_tty_driver;，fs/tty.c:180）**之后**。
     * ======================================================================= */

    /* 1) 把内部管道套到宿主 fd 0/1/2，以及 printk 的 666 */
    if (dup2(g_cmd_pipe[0], STDIN_FILENO) < 0 ||
        dup2(g_out_pipe[1], STDOUT_FILENO) < 0 ||
        dup2(g_out_pipe[1], STDERR_FILENO) < 0 ||
        dup2(g_out_pipe[1], AEVIS_ISH_PRINTK_FD) < 0) {
        set_boot_fail(AEVIS_ISH_ERR_BOOT, "dup2(pipes) failed: %s", strerror(errno));
        return;
    }
    /* 关掉不再需要的「原始」管道端：这样 guest 一旦把 stdout/stderr 全关掉，
     * 读取端就能读到 EOF（否则那个原始写端会一直吊着）。 */
    if (g_cmd_pipe[0] > 2)
        close(g_cmd_pipe[0]);
    if (g_out_pipe[1] > 2)
        close(g_out_pipe[1]);
    g_cmd_pipe[0] = -1;
    g_out_pipe[1] = -1;

    /* 2) 挂根：fakefs 的 source 是 <rootfs>/data */
    char dataPath[4200];
    snprintf(dataPath, sizeof(dataPath), "%s/data", rootfsDir);
    err = mount_root(&fakefs, dataPath);
    if (err < 0) {
        set_boot_fail(AEVIS_ISH_ERR_MOUNT, "mount_root(%s) failed: %d", dataPath, err);
        return;
    }

    /* 3) 造第一个进程（pid 1），并把本宿主线程登记进 current */
    err = become_first_process();
    if (err < 0) {
        set_boot_fail(AEVIS_ISH_ERR_BOOT, "become_first_process() failed: %d", err);
        return;
    }
    current->thread = pthread_self();

    /* 4) 设备节点（照 xX_main_Xx.h:99-106 与 AppDelegate.m:107-128 的极简子集） */
    generic_mknodat(AT_PWD, "/dev/null",    S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero",    S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full",    S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random",  S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/tty",     S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx",    S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    /* / 的权限历史上是坏的，修一下（AppDelegate.m:128 同样做法） */
    generic_setattrat(AT_PWD, "/", (struct attr){.type = attr_mode, .mode = 0755}, false);

    /* 5) proc / devpts */
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    /* 6) 控制台 tty 驱动（照 AppDelegate.m:156-157） */
    tty_drivers[TTY_CONSOLE_MAJOR] = &real_tty_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);

    /* 7) 两个回调 */
    exit_hook   = aevis_ish_on_exit;
    die_handler = aevis_ish_on_die;

    /* 8) stdio：0/1/2 现在是管道 ⇒ isatty() 为假 ⇒ 走 create_piped_stdio */
    err = create_piped_stdio();
    if (err < 0) {
        set_boot_fail(AEVIS_ISH_ERR_BOOT, "create_piped_stdio() failed: %d", err);
        return;
    }

    /* 9) exec 常驻 /bin/sh（argv/envp 都是「NUL 分隔 + 末尾再补一个 NUL」的连续缓冲）
     *
     * ⚠️ 为什么 argv 要写成显式双 NUL 的数组而不是字面量 "/bin/sh"：
     *    kernel/exec.c 的 args_size() 会做
     *        for (i = 0; i < args.count; i++) args_end += strlen(args_end) + 1;
     *        assert(args_end[0] == '\0');   // argc=1 ⇒ 落在 buf + strlen("/bin/sh") + 1 = buf[8]
     *    字面量 "/bin/sh" 只有 8 字节（下标 0..7），buf[8] 就是**越界读**——在 .rodata 里
     *    恰好是 0 才「碰巧能跑」，否则读进脏字节。release 下该 assert 被 NDEBUG 掐掉 ⇒ CI 不报。
     *    显式列成下标 0..8 共 9 字节，下标 8 恒为 0，才是 args_size() 想要的形状。
     *    （envp 那边字面量末尾的显式 \0 加上 C 自动补的 NUL，已经正好构成双 NUL 结尾，保持不动。） */
    static const char kShArgv[] = { '/', 'b', 'i', 'n', '/', 's', 'h', '\0', '\0' };
    static const char envp[] =
        "TERM=xterm-256color\0"
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
        "PYTHONMALLOC=malloc\0";
    err = do_execve("/bin/sh", 1, kShArgv, envp);
    if (err < 0) {
        set_boot_fail(AEVIS_ISH_ERR_BOOT, "do_execve(/bin/sh) failed: %d", err);
        return;
    }

    /* 10) 成功：先通知等待者（下一行不返回） */
    pthread_mutex_lock(&g_lock);
    g_boot_rc    = AEVIS_ISH_OK;
    g_boot_ready = 1;
    pthread_cond_broadcast(&g_boot_cond);
    pthread_mutex_unlock(&g_lock);

    /* 11) 进入内核主循环（永不返回） */
    task_run_current();

    /* 12) 万一返回了：标死 + 唤醒可能还在等的人 */
    set_boot_fail(AEVIS_ISH_ERR_DEAD, "task_run_current() returned unexpectedly");
    pthread_mutex_lock(&g_lock);
    g_boot_ready = 1;
    g_dead = 1;
    g_busy = 0;
    pthread_cond_broadcast(&g_boot_cond);
    pthread_cond_broadcast(&g_done_cond);
    pthread_mutex_unlock(&g_lock);
}

static void *aevis_ish_boot_main(void *arg) {
    pthread_cleanup_push(aevis_ish_boot_cleanup, NULL);
    aevis_ish_boot_body((const char *)arg);
    pthread_cleanup_pop(1); /* 统一在这里把 g_boot_ready 置位并唤醒 */
    return NULL;
}

/* ===========================================================================
 * 对外 API
 * ========================================================================= */

const char *aevis_ish_version(void) {
    return AEVIS_ISH_VERSION_STR;
}

const char *aevis_ish_last_message(void) {
    return g_msg; /* 静态缓冲，永远非 NULL */
}

int aevis_ish_is_booted(void) {
    return g_is_booted ? 1 : 0;
}

int aevis_ish_busy(void) {
    return g_busy ? 1 : 0;
}

int aevis_ish_last_exit_code(void) {
    return g_last_rc;
}

int aevis_ish_boot(const char *rootfsDir, const char *tmpDir) {
    if (g_boot_started) {
        set_msg("already booted；iSH 全局状态不能 boot 两次");
        return AEVIS_ISH_ERR_ALREADY;
    }
    if (rootfsDir == NULL || rootfsDir[0] == '\0') {
        set_msg("rootfsDir 为空");
        return AEVIS_ISH_ERR_ARG;
    }

    /* rootfs 形状校验：<rootfs>/ 是目录、里面有 data/ 与 meta.db */
    struct stat st;
    if (stat(rootfsDir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        set_msg("rootfsDir 不是目录：%s", rootfsDir);
        return AEVIS_ISH_ERR_ROOTFS;
    }
    char dataPath[4200];
    char metaPath[4200];
    snprintf(dataPath, sizeof(dataPath), "%s/data", rootfsDir);
    snprintf(metaPath, sizeof(metaPath), "%s/meta.db", rootfsDir);
    if (stat(dataPath, &st) != 0 || !S_ISDIR(st.st_mode)) {
        set_msg("缺少 data/ 目录：%s", dataPath);
        return AEVIS_ISH_ERR_ROOTFS;
    }
    if (stat(metaPath, &st) != 0) {
        set_msg("缺少 meta.db：%s", metaPath);
        return AEVIS_ISH_ERR_ROOTFS;
    }

    /* sock_tmp_prefix：iOS 上 /tmp 不可写，重定向到 App 自己的临时目录 */
    if (tmpDir != NULL && tmpDir[0] != '\0') {
        if (mkdir(tmpDir, 0755) != 0 && errno != EEXIST) {
            set_msg("mkdir(%s) 失败：%s", tmpDir, strerror(errno));
            return AEVIS_ISH_ERR_ARG;
        }
        char *copy = strdup(tmpDir);
        if (copy == NULL) {
            set_msg("strdup(tmpDir) 失败");
            return AEVIS_ISH_ERR_ARG;
        }
        free(g_sock_tmp);
        g_sock_tmp = copy;
        sock_tmp_prefix = g_sock_tmp;
    }

    /* rootfs 路径也要给 boot 线程留一份持久的 */
    char *rootfs_copy = strdup(rootfsDir);
    if (rootfs_copy == NULL) {
        set_msg("strdup(rootfsDir) 失败");
        return AEVIS_ISH_ERR_ARG;
    }
    free(g_rootfs);
    g_rootfs = rootfs_copy;

    /* 两条管道 */
    if (pipe(g_cmd_pipe) != 0) {
        set_msg("pipe(cmd) 失败：%s", strerror(errno));
        return AEVIS_ISH_ERR_BOOT;
    }
    if (pipe(g_out_pipe) != 0) {
        set_msg("pipe(out) 失败：%s", strerror(errno));
        close(g_cmd_pipe[0]);
        close(g_cmd_pipe[1]);
        g_cmd_pipe[0] = g_cmd_pipe[1] = -1;
        return AEVIS_ISH_ERR_BOOT;
    }

    g_boot_started = 1;
    g_boot_ready   = 0;
    g_is_booted    = 0;
    g_dead         = 0;
    g_busy         = 0;
    g_last_rc      = -1;
    g_boot_rc      = AEVIS_ISH_OK;

    if (pthread_create(&g_boot_thread, NULL, aevis_ish_boot_main, (void *)g_rootfs) != 0) {
        set_msg("pthread_create(boot) 失败：%s", strerror(errno));
        g_boot_started = 0;
        return AEVIS_ISH_ERR_BOOT;
    }

    /* 等 boot 出结果（最多 AEVIS_BOOT_TIMEOUT_MS） */
    pthread_mutex_lock(&g_lock);
    struct timespec deadline = abs_after_ms(AEVIS_BOOT_TIMEOUT_MS);
    int timed_out = 0;
    while (!g_boot_ready) {
        int r = pthread_cond_timedwait(&g_boot_cond, &g_lock, &deadline);
        if (r == ETIMEDOUT) {
            timed_out = 1;
            break;
        }
    }
    int ready = g_boot_ready;
    int rc    = g_boot_rc;
    pthread_mutex_unlock(&g_lock);

    if (!ready || timed_out) {
        set_msg("boot 超时（%dms）", AEVIS_BOOT_TIMEOUT_MS);
        return AEVIS_ISH_ERR_TIMEOUT;
    }
    if (rc != AEVIS_ISH_OK)
        return rc; /* 文案已由 set_boot_fail 写好 */

    pthread_mutex_lock(&g_lock);
    g_is_booted = 1;
    pthread_mutex_unlock(&g_lock);

    if (pthread_create(&g_reader_thread, NULL, aevis_ish_reader_main, NULL) != 0) {
        set_msg("pthread_create(reader) 失败：%s", strerror(errno));
        return AEVIS_ISH_ERR_BOOT;
    }
    return AEVIS_ISH_OK;
}

int aevis_ish_run(const char *command) {
    if (command == NULL) {
        set_msg("command 为 NULL");
        return AEVIS_ISH_ERR_ARG;
    }
    if (strstr(command, AEVIS_RC_MARKER) != NULL) {
        set_msg("命令里不允许出现哨兵标记 %s", AEVIS_RC_MARKER);
        return AEVIS_ISH_ERR_ARG;
    }

    /* 拼包装串（动态分配，绝不用固定小缓冲） */
    size_t need = strlen(AEVIS_RUN_PREFIX) + strlen(command) +
                  strlen(AEVIS_RUN_SUFFIX) + 1;
    char *wrapped = malloc(need);
    if (wrapped == NULL) {
        set_msg("malloc(wrapped) 失败");
        return AEVIS_ISH_ERR_BOOT;
    }
    snprintf(wrapped, need, "%s%s%s", AEVIS_RUN_PREFIX, command, AEVIS_RUN_SUFFIX);

    pthread_mutex_lock(&g_lock);
    if (!g_is_booted) {
        pthread_mutex_unlock(&g_lock);
        free(wrapped);
        set_msg("还没 boot");
        return AEVIS_ISH_ERR_ARG;
    }
    if (g_dead) {
        pthread_mutex_unlock(&g_lock);
        free(wrapped);
        set_msg("内核/shell 已死，不能再发命令");
        return AEVIS_ISH_ERR_DEAD;
    }
    if (g_busy) {
        pthread_mutex_unlock(&g_lock);
        free(wrapped);
        set_msg("上一条命令还没跑完（busy）");
        return AEVIS_ISH_ERR_ARG;
    }

    g_busy    = 1;
    g_last_rc = -1;

    /* 一次 write 写完整条（循环写直到写完） */
    const char *p    = wrapped;
    size_t      left = strlen(wrapped);
    int         wfail = 0;
    while (left > 0) {
        ssize_t w = write(g_cmd_pipe[1], p, left);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            wfail = 1;
            break;
        }
        p    += w;
        left -= (size_t)w;
    }
    free(wrapped);

    if (wfail) {
        g_busy = 0;
        g_dead = 1;
        snprintf(g_msg, sizeof(g_msg), "写命令进管道失败：%s", strerror(errno));
        pthread_mutex_unlock(&g_lock);
        return AEVIS_ISH_ERR_DEAD;
    }

    pthread_mutex_unlock(&g_lock);
    return AEVIS_ISH_OK;
}

int aevis_ish_wait(int timeoutMs) {
    pthread_mutex_lock(&g_lock);
    if (!g_is_booted) {
        pthread_mutex_unlock(&g_lock);
        set_msg("还没 boot");
        return AEVIS_ISH_ERR_ARG;
    }
    if (!g_busy) {
        pthread_mutex_unlock(&g_lock);
        return AEVIS_ISH_OK;
    }

    int timed_out = 0;
    if (timeoutMs <= 0) {
        while (g_busy)
            pthread_cond_wait(&g_done_cond, &g_lock);
    } else {
        struct timespec deadline = abs_after_ms(timeoutMs);
        while (g_busy) {
            int r = pthread_cond_timedwait(&g_done_cond, &g_lock, &deadline);
            if (r == ETIMEDOUT) {
                timed_out = 1;
                break;
            }
        }
    }
    int still_busy = g_busy;
    pthread_mutex_unlock(&g_lock);

    if (timed_out && still_busy) {
        set_msg("等命令结束超时（%dms）", timeoutMs);
        return AEVIS_ISH_ERR_TIMEOUT;
    }
    return AEVIS_ISH_OK;
}

char *aevis_ish_take_output(void) {
    pthread_mutex_lock(&g_lock);
    if (g_out_len == 0 || g_out_buf == NULL) {
        pthread_mutex_unlock(&g_lock);
        return NULL;
    }
    char *ret = g_out_buf;          /* 所有权交给调用方 */
    ret[g_out_len] = '\0';
    g_out_buf = NULL;
    g_out_len = 0;
    g_out_cap = 0;
    pthread_mutex_unlock(&g_lock);
    return ret;
}

int aevis_ish_abort_current(void) {
    pthread_mutex_lock(&g_lock);
    g_busy = 0;
    g_dead = 1;
    set_msg("已强制判定当前命令结束；内核视为脏（不会重启）");
    pthread_cond_broadcast(&g_done_cond);
    pthread_mutex_unlock(&g_lock);
    return AEVIS_ISH_OK;
}
