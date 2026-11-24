package com.aevis.android.core

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * App 内下载 / 安装 APK（2026-11-24）。
 *
 * 之前「检查更新」点确认走 `openUrl()` 跳浏览器，用户还得自己去下载目录找安装包；
 * 现在 App 内直接下载到私有目录，再用 FileProvider + ACTION_VIEW 调起系统安装器。
 *
 * 设计要点：
 *  - 工程**没有 OkHttp 依赖**（见 app/build.gradle.kts），因此用 JDK 自带的
 *    [HttpURLConnection]，不新增库、不动任何版本号。
 *  - 下载落在 [Context.getFilesDir]（内部私有、系统不会像 cacheDir 那样自动清理），
 *    FileProvider 的 `<files-path path=".">` 已覆盖该目录，无需改 file_paths.xml。
 *  - 先写 `.part` 再 rename，避免下载中断留下半截文件被当成安装包。
 *  - 所有失败（HTTP 非 2xx、空文件、IO 异常）都抛带原因的 [IOException]，绝不静默。
 */
object ApkInstaller {
    private const val APK_NAME = "update.apk"
    private const val PART_NAME = "update.apk.part"
    private const val AUTHORITY_SUFFIX = ".fileprovider"
    private const val CONNECT_TIMEOUT_MS = 15_000
    private const val READ_TIMEOUT_MS = 20_000
    private const val BUFFER_SIZE = 16 * 1024

    /** 安装包最终路径（filesDir，系统不会清理）。 */
    fun apkFile(ctx: Context): File = File(ctx.filesDir, APK_NAME)

    /** Android 8+（API 26）安装未知来源应用必须用户授权；更低版本恒为 true。 */
    fun canInstallUnknownApps(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || ctx.packageManager.canRequestPackageInstalls()

    /** 引导用户去「安装未知应用」设置页给本 App 授权。 */
    fun unknownAppsSettingsIntent(ctx: Context): Intent {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        return intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    /**
     * 下载 APK（在 [Dispatchers.IO] 上执行）。
     *
     * @param onProgress 0..100 的百分比；服务端未返回 Content-Length 时为 -1（UI 用不确定进度）。
     * @return 下载完成的安装包；任何失败都抛 [IOException]（含 HTTP 码 / 异常原因）。
     */
    suspend fun download(ctx: Context, url: String, onProgress: (Int) -> Unit): File =
        withContext(Dispatchers.IO) {
            if (url.isBlank()) throw IOException("下载地址为空，请联系客服")
            val finalFile = apkFile(ctx)
            val partFile = File(ctx.filesDir, PART_NAME)
            // 清理上次残留：既避免装到半截包，也避免重复占用空间
            if (partFile.exists()) partFile.delete()
            if (finalFile.exists()) finalFile.delete()

            var conn: HttpURLConnection? = null
            try {
                conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = CONNECT_TIMEOUT_MS
                conn.readTimeout = READ_TIMEOUT_MS
                conn.requestMethod = "GET"
                conn.instanceFollowRedirects = true
                val code = conn.responseCode
                if (code !in 200..299) throw IOException("下载失败：HTTP $code")

                val total = conn.contentLength // -1 表示服务端没给长度
                var downloaded = 0L
                var lastShown = -2
                conn.inputStream.use { input ->
                    FileOutputStream(partFile).use { out ->
                        val buf = ByteArray(BUFFER_SIZE)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            if (n == 0) continue
                            out.write(buf, 0, n)
                            downloaded += n
                            val pct = if (total > 0) {
                                ((downloaded * 100) / total).toInt().coerceAtMost(100)
                            } else -1
                            if (pct != lastShown) {
                                lastShown = pct
                                withContext(Dispatchers.Main) { onProgress(pct) }
                            }
                        }
                        out.flush()
                    }
                }
                if (partFile.length() <= 0L) throw IOException("下载失败：安装包为空")
                if (!partFile.renameTo(finalFile)) {
                    // 少数系统 rename 会失败，退回复制
                    partFile.copyTo(finalFile, overwrite = true)
                    if (!partFile.delete()) partFile.deleteOnExit()
                }
                withContext(Dispatchers.Main) { onProgress(100) }
                finalFile
            } catch (e: IOException) {
                if (partFile.exists()) partFile.delete()
                throw e
            } catch (e: Exception) {
                if (partFile.exists()) partFile.delete()
                throw IOException("下载失败：${e.message ?: e.javaClass.simpleName}", e)
            } finally {
                conn?.disconnect()
            }
        }

    /**
     * 调起系统安装器。调用前应确保 [canInstallUnknownApps] 为 true。
     * 失败抛 [IOException]（含原因），由 UI 展示并可重试。
     */
    fun install(ctx: Context, apk: File) {
        if (!apk.exists() || apk.length() <= 0L) throw IOException("安装包不存在，请重新下载")
        val uri = try {
            FileProvider.getUriForFile(ctx, ctx.packageName + AUTHORITY_SUFFIX, apk)
        } catch (e: Exception) {
            throw IOException("无法读取安装包：${e.message ?: e.javaClass.simpleName}", e)
        }
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(intent)
        } catch (e: Exception) {
            throw IOException("无法打开安装器：${e.message ?: e.javaClass.simpleName}", e)
        }
    }
}
