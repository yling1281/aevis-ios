/*
 * ============================================================================
 *  AEVIS · iSH 内核「宿主入口层」对外 API
 *  ----------------------------------------------------------------------------
 *  这个头文件是 **App 与本项目里那套 iSH 内核之间唯一的契约**。
 *
 *  它故意 **不含任何 iSH 头文件**（不 include "kernel/*.h"、不 include "fs/*.h"）。
 *  原因：iSH 的头文件是 GPL-3.0 的实现细节，而且它们互相依赖很重、还会拉进
 *  sqlite3 / emu / vdso 一堆东西；如果让 Swift 侧（或任何调用方）直接看到它们，
 *  调用方就被绑死在 iSH 的内部结构上了。所以这里只暴露「纯 C 的窄接口」：
 *     · 只有 int / const char * / char * 三种类型；
 *     · 不暴露任何 struct、union、enum、宏（除了返回码）；
 *     · 任何 C89/C11/gnu11 编译器都能直接解析，C++ 也能（外面套了 extern "C"）。
 *  ⇒ 调用方（App / 别的语言绑定）只要这一个头 + 一个静态库即可。
 * ============================================================================
 */

#ifndef AEVIS_ISH_EMBED_H
#define AEVIS_ISH_EMBED_H

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * 返回码
 * ---------------------------------------------------------------------------
 * 约定：AEVIS_ISH_OK == 0 表示成功；负数是错误码（方便 `if (rc < 0)` 判断）。
 * 这些数值是**对外协议**，不要随意改动顺序/大小。
 */
#define AEVIS_ISH_OK              0   /* 成功 */
#define AEVIS_ISH_ERR_ARG        -1   /* 参数非法（NULL、命令为空、busy 时又发命令……） */
#define AEVIS_ISH_ERR_ALREADY    -2   /* 已经 boot 过（本进程只允许一次，见下） */
#define AEVIS_ISH_ERR_ROOTFS     -3   /* rootfs 目录不对（缺 data/ 或 meta.db） */
#define AEVIS_ISH_ERR_MOUNT      -4   /* mount_root 失败 */
#define AEVIS_ISH_ERR_BOOT       -5   /* become_first_process / create_piped_stdio / exec 失败 */
#define AEVIS_ISH_ERR_TIMEOUT    -6   /* 等命令结束超时 */
#define AEVIS_ISH_ERR_DEAD       -7   /* 内核 / shell 已经死了，不能再发命令 */

/* ---------------------------------------------------------------------------
 * 版本串：静态只读字符串（不需要 free），形如
 *   "iSH asbestos 2026-10-06 (GPL-3.0)"
 * 用来在自检/日志里标记「这套嵌入层对应哪个上游」。永远非 NULL。
 * ------------------------------------------------------------------------- */
const char *aevis_ish_version(void);

/* ---------------------------------------------------------------------------
 * aevis_ish_boot —— 启动内核并拉起一个**常驻**的 /bin/sh
 * ---------------------------------------------------------------------------
 * 参数：
 *   rootfsDir : 一个**真实存在**的宿主目录，里面必须同时有
 *                 <rootfsDir>/data/    （fakefs 的数据目录）
 *                 <rootfsDir>/meta.db  （fakefs 的元数据库）
 *               这正是 CI 里 fakefsify 的产物形态（alpine-fakefs/）。
 *               传 NULL 或目录不对 → 返回 AEVIS_ISH_ERR_ROOTFS。
 *   ⚠️ 关于 `data`（别搞反层级）：内核最终挂载的源是 **`<rootfsDir>/data`**，
 *      而 iSH fakefs 要求这个挂载源的**末段目录名恰好是 `data`**
 *      ——它在 fs/fake.c 里会就地把末段 strcpy 成 `meta.db` 去找数据库。
 *      所以 rootfsDir 传的是**那个 data/ 的父目录**（CI 里是 alpine-fakefs/），
 *      不是 data/ 本身；传错**不会报错**，而是静默去找另一个文件，故本层在入口
 *      先 stat `<rootfsDir>/data` 与 `<rootfsDir>/meta.db`，不合格即 ERR_ROOTFS。
 *   tmpDir    : App 自己的可写临时目录，用来安置 iSH 的 Unix socket 前缀
 *               （iSH 默认把 socket 放在 /tmp/ishsock，而 iOS 上 /tmp 不可写）。
 *               传 NULL 则保持 iSH 默认值。
 *
 * 行为：
 *   · 本函数**内部起线程**：内核主循环（task_run_current）是阻塞的、而且用的是
 *     线程局部变量 `current`，所以「boot 与主循环必须在同一个线程上」。
 *     调用方不需要自己起线程，本函数会在「shell 已经 exec 好、随时能收命令」
 *     之后才返回。
 *   · ⚠️ 一个进程**只允许成功 boot 一次**。iSH 的全局状态（mount 表、pid 表、
 *     signal handler……）是进程级的，根本不能 boot 两次。重复调用返回
 *     AEVIS_ISH_ERR_ALREADY。内核一旦死了也**不能重启**，只能整个进程重来。
 *   · ⚠️ 副作用：为了让 guest 的 fd 0/1/2 通到我们自己的管道，本函数会把**宿主
 *     进程**的 fd 0/1/2（以及 printk 用的 fd 666）重定向到内部管道。
 *     也就是说：boot 之后，调用方自己再往 stdout 打印是收不到的（会被当成
 *     guest 输出读走）。要在 boot 之后自己打日志，请**先 dup 一份原始 stdout**。
 *   返回：AEVIS_ISH_OK / 上面某个错误码。
 * ------------------------------------------------------------------------- */
int aevis_ish_boot(const char *rootfsDir, const char *tmpDir);

/* 1 = 已经成功 boot；0 = 还没有。 */
int aevis_ish_is_booted(void);

/* 1 = 上一条命令还在跑（还没等到哨兵行）；0 = 空闲/未启动。 */
int aevis_ish_busy(void);

/* 上一条命令的退出码；还没跑完（或还没跑过）返回 -1。 */
int aevis_ish_last_exit_code(void);

/* 最近一次内部错误的人类可读说明（UTF-8）。**永远非 NULL**，不需要 free。
 * 它只是诊断信息，不参与控制流。 */
const char *aevis_ish_last_message(void);

/* ---------------------------------------------------------------------------
 * aevis_ish_run —— 把一条命令追加到常驻 shell 的 stdin
 * ---------------------------------------------------------------------------
 * ⚠️ 实现上会包一层子 shell 并追加一行「退出码哨兵」，例如执行
 *       "echo hi"
 *    实际写进 shell 的是（换行按字面）：
 *       (
 *       echo hi
 *       )
 *       printf '__AEVIS_RC__=%d\n' $?
 *    · 为什么用 **( ... )** 而不是 { ... }：常驻 shell 是 guest 的 **init（pid 1）**，
 *      iSH 在 init 退出时会走 halt_system() → _exit(0)，**整台 App 都没了**。
 *      用子 shell 包住，`exit N` / `exec ...` 只会干掉那个子 shell，init 活下来。
 *    · 为什么追加哨兵行：shell 不会替我们把「上一条命令的退出码」报回来，
 *      所以自己在同一条命令里把 $? 打出来，宿主侧解析这一行即可。
 *
 * ⚠️ 必须在上一条命令结束（aevis_ish_busy()==0）之后再调；
 *    busy 时调用返回 AEVIS_ISH_ERR_ARG。
 * ⚠️ 命令里**不允许出现哨兵标记 "__AEVIS_RC__="**（防止伪造退出码）；
 *    含则返回 AEVIS_ISH_ERR_ARG。
 * ------------------------------------------------------------------------- */
int aevis_ish_run(const char *command);

/* ---------------------------------------------------------------------------
 * aevis_ish_take_output —— 取走「自上次调用以来」累积的 guest 输出
 * ---------------------------------------------------------------------------
 * 返回值：UTF-8、NUL 结尾的堆内存；**由调用者 free()**。
 *        没有新输出时返回 NULL。
 * 已剥掉内部哨兵行；内核 printk/die 的日志也会被拼进来。
 * ------------------------------------------------------------------------- */
char *aevis_ish_take_output(void);

/* ---------------------------------------------------------------------------
 * aevis_ish_wait —— 等上一条命令结束
 * ---------------------------------------------------------------------------
 * timeoutMs <= 0 表示无限等（直到命令结束或内核死）。
 * 返回：AEVIS_ISH_OK 成功结束；AEVIS_ISH_ERR_TIMEOUT 超时（**不会**自动 abort，
 *       需要的话由调用方自己调 aevis_ish_abort_current()）。
 * ------------------------------------------------------------------------- */
int aevis_ish_wait(int timeoutMs);

/* ---------------------------------------------------------------------------
 * aevis_ish_abort_current —— 强制把「当前这条」判成结束
 * ---------------------------------------------------------------------------
 * 仅当某条命令已经超时、你不想再等时使用：把 busy 清掉，并把 shell 视为**脏**
 * （g_dead 置位）。⚠️ **不会重启内核** —— iSH 全局状态不能 boot 两次，
 * 所以「重启」= 让 App 重启整个进程。
 * ------------------------------------------------------------------------- */
int aevis_ish_abort_current(void);

#ifdef __cplusplus
}
#endif

#endif /* AEVIS_ISH_EMBED_H */
