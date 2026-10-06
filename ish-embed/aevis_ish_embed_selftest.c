/*
 * ============================================================================
 *  AEVIS · iSH 嵌入层「宿主 macOS 端到端自检」
 *  ----------------------------------------------------------------------------
 *  这是给 CI（macos runner）用的：真编出一个可执行文件，真把 Alpine 跑起来，
 *  真跑几条命令、真读回输出与退出码。**只有非交叉构建（native）才会编译它**
 *  （见 CI 对 meson.build 的第二处插入：executable(...) 在
 *    `if not meson.is_cross_build()` 块里）。
 *
 *  用法：  aevis_ish_embed_selftest <rootfsDir> <tmpDir>
 *      rootfsDir  含 data/ 与 meta.db 的 fakefs 根（CI 里是 $SBX/alpine-fakefs）
 *      tmpDir     App 可写临时目录（CI 里是 $SBX/tmp-embed）
 *
 *  顺序：① 先跑**负例**（坏 rootfs 必须被干净拒绝，iSH 只能 boot 一次，故放最前）
 *        ② 再 boot 真 rootfs，跑 6 条正例命令
 *
 *  成功：打印一行 "AEVIS_ISH_EMBED_SELFTEST_OK <version>"（负例全过时另有
 *        "AEVIS_ISH_EMBED_NEGATIVE_OK"），退出码 0
 *  失败：打印一行 "AEVIS_ISH_EMBED_SELFTEST_FAIL <原因>"，退出码非 0
 *
 *  ⚠️ 收尾一律用 _exit()：内核主循环跑在别的线程上，正常 return/exit 会触发
 *     atexit / 线程收尾，不安全也不必要。
 * ============================================================================
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "aevis_ish_embed.h"

/* boot 会把**宿主进程的 fd 1** 抢去当 guest 的 stdout，所以我们先 dup 一份
 * 原始 stdout，之后自己打日志全部写这份副本（写 g_log_fd，不写 fd 1）。 */
static int g_log_fd = STDOUT_FILENO;

static void emit(const char *fmt, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        size_t len = ((size_t)n < sizeof(buf)) ? (size_t)n : (sizeof(buf) - 1);
        ssize_t w = write(g_log_fd, buf, len);
        (void)w;
    }
}

static int contains(const char *hay, const char *needle) {
    if (hay == NULL || needle == NULL)
        return 0;
    return strstr(hay, needle) != NULL;
}

/* 跑一条命令并把输出原样打出来；成功返回 0 并把输出给 *out_out（调用方 free）。 */
static int do_step(const char *label, const char *cmd, char **out_out) {
    emit("\n===== step: %s =====\n", label);
    emit("$ %s\n", cmd);

    int rc = aevis_ish_run(cmd);
    if (rc != AEVIS_ISH_OK) {
        emit("  [FAIL] aevis_ish_run -> %d (%s)\n", rc, aevis_ish_last_message());
        if (out_out != NULL)
            *out_out = NULL;
        return rc;
    }
    rc = aevis_ish_wait(60000);
    if (rc != AEVIS_ISH_OK) {
        emit("  [FAIL] aevis_ish_wait -> %d (%s)\n", rc, aevis_ish_last_message());
        if (out_out != NULL)
            *out_out = NULL;
        return rc;
    }

    char *out = aevis_ish_take_output();
    emit("--- output ---\n");
    if (out != NULL)
        emit("%s", out);
    else
        emit("(无输出)\n");
    emit("--- end output ---\n");
    emit("exit_code=%d\n", aevis_ish_last_exit_code());

    if (out_out != NULL)
        *out_out = out;
    else
        free(out);
    return AEVIS_ISH_OK;
}

#define SELFTEST_FAIL(...)                                              \
    do {                                                                \
        emit("AEVIS_ISH_EMBED_SELFTEST_FAIL ");                         \
        emit(__VA_ARGS__);                                              \
        emit("\n");                                                     \
        fflush(stdout);                                                 \
        _exit(1);                                                       \
    } while (0)

int main(int argc, char **argv) {
    /* 先保住原始 stdout */
    int saved = dup(STDOUT_FILENO);
    if (saved >= 0)
        g_log_fd = saved;

    emit("===== Aevis iSH embed self-test =====\n");
    emit("version : %s\n", aevis_ish_version());

    if (argc < 2) {
        emit("usage: %s <rootfsDir> <tmpDir>\n", argv[0]);
        fflush(stdout);
        _exit(2);
    }
    const char *rootfs = argv[1];
    const char *tmpdir = (argc >= 3) ? argv[2] : NULL;
    emit("rootfs  : %s\n", rootfs);
    emit("tmpdir  : %s\n", tmpdir != NULL ? tmpdir : "(null)");

    /* -----------------------------------------------------------------------
     * 负例：**必须在真正 boot 之前跑**（iSH 全局状态只能 boot 一次）。
     * 目的：证明 aevis_ish_boot 遇到坏 rootfs 会**干净拒绝**（返回 ERR_ROOTFS），
     *       绝不 abort、也绝不留半初始化状态。断言版构建（-Db_ndebug=false）
     *       会打开这条拒绝路径旁的上游 assert（fs/fake.c:984），正是它的价值所在。
     * --------------------------------------------------------------------- */
    emit("\n----- negative cases (must run before boot) -----\n");

    /* 负例 1：传 rootfs 的**父目录**——末段必然不叫 data ⇒ 期望 ERR_ROOTFS。 */
    char parent[4096];
    snprintf(parent, sizeof(parent), "%s", rootfs);
    char *slash = strrchr(parent, '/');
    if (slash == NULL)
        snprintf(parent, sizeof(parent), ".");
    else if (slash == parent)
        parent[1] = '\0';   /* rootfs 形如 "/x" ⇒ 父目录就是 "/" */
    else
        *slash = '\0';
    emit("负例1: boot(父目录 %s)  —— 期望 ERR_ROOTFS\n", parent);
    int nrc = aevis_ish_boot(parent, tmpdir);
    if (nrc != AEVIS_ISH_ERR_ROOTFS)
        SELFTEST_FAIL("负例1 期望 ERR_ROOTFS(%d)，实际 rc=%d msg=%s",
                      AEVIS_ISH_ERR_ROOTFS, nrc, aevis_ish_last_message());
    if (aevis_ish_is_booted() != 0)
        SELFTEST_FAIL("负例1 之后 is_booted 应为 0（不得留半初始化状态），实际=%d",
                      aevis_ish_is_booted());
    emit("  [ok] rc=%d，未 abort，is_booted=0\n", nrc);

    /* 负例 2：完全不存在的路径 ⇒ 期望 ERR_ROOTFS。 */
    emit("负例2: boot(/nonexistent/aevis-not-here) —— 期望 ERR_ROOTFS\n");
    nrc = aevis_ish_boot("/nonexistent/aevis-not-here", tmpdir);
    if (nrc != AEVIS_ISH_ERR_ROOTFS)
        SELFTEST_FAIL("负例2 期望 ERR_ROOTFS(%d)，实际 rc=%d msg=%s",
                      AEVIS_ISH_ERR_ROOTFS, nrc, aevis_ish_last_message());
    if (aevis_ish_is_booted() != 0)
        SELFTEST_FAIL("负例2 之后 is_booted 应为 0（不得留半初始化状态），实际=%d",
                      aevis_ish_is_booted());
    emit("  [ok] rc=%d，未 abort，is_booted=0\n", nrc);

    /* 负例全过：明确打一行，CI 好 grep。 */
    emit("AEVIS_ISH_EMBED_NEGATIVE_OK\n");

    emit("\n----- boot -----\n");
    int rc = aevis_ish_boot(rootfs, tmpdir);
    if (rc != AEVIS_ISH_OK)
        SELFTEST_FAIL("aevis_ish_boot rc=%d msg=%s", rc, aevis_ish_last_message());
    emit("boot OK；is_booted=%d\n", aevis_ish_is_booted());

    char *out = NULL;

    /* step 1：内核版本 */
    if (do_step("uname -a", "uname -a", &out) != AEVIS_ISH_OK)
        SELFTEST_FAIL("uname -a 这一步失败");
    if (!contains(out, "Linux"))
        SELFTEST_FAIL("uname -a 输出里没有 Linux；实际=[%s]", out ? out : "(null)");
    free(out);
    out = NULL;

    /* step 2：Alpine 版本 */
    if (do_step("cat /etc/alpine-release", "cat /etc/alpine-release", &out) != AEVIS_ISH_OK)
        SELFTEST_FAIL("cat /etc/alpine-release 这一步失败");
    if (!contains(out, "3.21"))
        SELFTEST_FAIL("/etc/alpine-release 里没有 3.21；实际=[%s]", out ? out : "(null)");
    free(out);
    out = NULL;

    /* step 3：echo */
    if (do_step("echo hello-from-alpine", "echo hello-from-alpine", &out) != AEVIS_ISH_OK)
        SELFTEST_FAIL("echo 这一步失败");
    if (!contains(out, "hello-from-alpine"))
        SELFTEST_FAIL("echo 输出不对；实际=[%s]", out ? out : "(null)");
    if (aevis_ish_last_exit_code() != 0)
        SELFTEST_FAIL("echo 的退出码应为 0，实际=%d", aevis_ish_last_exit_code());
    free(out);
    out = NULL;

    /* step 4：for 循环（多行输出） */
    if (do_step("for 循环", "({ for i in 1 2 3; do echo n=$i; done; })", &out) != AEVIS_ISH_OK)
        SELFTEST_FAIL("for 循环这一步失败");
    if (!contains(out, "n=1") || !contains(out, "n=2") || !contains(out, "n=3"))
        SELFTEST_FAIL("for 循环输出不对；实际=[%s]", out ? out : "(null)");
    free(out);
    out = NULL;

    /* step 5：退出码传播（关键）——`exit 7` 必须让外壳读到 7，
     *         而且**绝不能把 init 干掉**（见下一条 step 6 验证）。 */
    if (do_step("exit 7", "exit 7", &out) != AEVIS_ISH_OK)
        SELFTEST_FAIL("exit 7 这一步失败");
    if (aevis_ish_last_exit_code() != 7)
        SELFTEST_FAIL("exit 7 的退出码应为 7，实际=%d", aevis_ish_last_exit_code());
    free(out);
    out = NULL;

    /* step 6：`exit 7` 之后 shell 还活着吗？
     *   —— 这条同时验证「命令必须用子 shell 包起来」这个设计：
     *      init（pid 1）要是被 exit 干掉了，iSH 会 halt_system() → _exit(0)，
     *      整个自检进程会**静默消失**，下面这行根本跑不到。 */
    if (do_step("shell 仍存活", "echo still-alive-after-exit", &out) != AEVIS_ISH_OK)
        SELFTEST_FAIL("exit 7 之后 shell 已经不在了（init 可能被干掉了）");
    if (!contains(out, "still-alive-after-exit"))
        SELFTEST_FAIL("shell 存活探测输出不对；实际=[%s]", out ? out : "(null)");
    free(out);
    out = NULL;

    emit("\nAEVIS_ISH_EMBED_SELFTEST_OK %s\n", aevis_ish_version());
    fflush(stdout);
    /* 内核跑在别的线程上，正常退出不安全；直接 _exit。 */
    _exit(0);
}
