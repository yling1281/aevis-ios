package com.aevis.android.core

import android.content.Context
import android.net.Uri
import com.aevis.android.data.Api
import org.json.JSONObject
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * 整机搬家（2026-11-16，124）。
 *
 * 跟 [ChatArchive] 的区别：那个只搬聊天记录，这个把**整个 App 的本地数据**打一包 ——
 * 角色（含头像/形象图）、我的头像和资料、聊天、聊天图片、设置、主/聊天背景原图。
 *
 * ```
 * aevis-backup-YYYYMMDD-HHmm.zip
 * ├─ manifest.json   {ver:2, …}
 * ├─ me/profile.json + avatar.jpg
 * ├─ roles/<pid>/role.json + avatar.jpg + gallery/1.jpg…
 * ├─ chats/<pid>.json
 * ├─ images/<pid>/001.jpg…
 * ├─ settings.json
 * └─ backgrounds/app.jpg · chat.jpg
 * ```
 *
 * 三条硬规矩：
 *   1. 所有 json 里的图片字段都是**相对路径**（这台机器上重建），绝不写绝对路径；
 *   2. 单张图片取不到只跳过，manifest 记 `missing`，不中断整包；
 *   3. 导入沿用 [ChatArchive.applyJson] 的会话写回（去重 / 占位角色都复用），不另写一套。
 */
object FullBackup {

    const val VER = 2

    data class ExportResult(
        val file: File?,
        val roles: Int = 0,
        val convs: Int = 0,
        val msgs: Int = 0,
        val images: Int = 0,
        val missing: Int = 0,
        val err: String = ""
    )

    data class Plan(
        val src: File,
        val ver: Int,
        val roles: Int,
        val convs: Int,
        val msgs: Int,
        val images: Int,
        val bgs: Int,
        val note: String = ""
    )

    data class ImportResult(
        val roles: Int = 0,
        val convs: Int = 0,
        val msgs: Int = 0,
        val images: Int = 0,
        val bgs: Int = 0,
        val err: String = ""
    )

    // ---------------------------------------------------------------- 导出

    fun export(ctx: Context): ExportResult {
        return try {
            val dir = File(ctx.cacheDir, "exports")
            if (!dir.exists()) dir.mkdirs()
            val stamp = java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US)
                .format(java.util.Date())
            val out = File(dir, "aevis-backup-$stamp.zip")

            var nRole = 0
            var nConv = 0
            var nMsg = 0
            var nImg = 0
            var missing = 0
            var bgCount = 0

            // 先把所有图片读成字节（写 zip 时一次性顺序写，失败不会留半个包）
            val entries = LinkedHashMap<String, ByteArray>()   // zip 内路径 → 内容
            val convsOut = JSONObject()                        // pid → 消息数组（图片改相对路径）

            // ---------- 角色 ----------
            LocalPersonaStore.all().forEach { it ->
                if (it.id.isBlank()) return@forEach
                val base = "roles/${san(it.id)}/"
                val role = JSONObject()
                    .put("id", it.id)
                    .put("name", it.name)
                    .put("persona", it.persona)
                    .put("style", it.style)
                    .put("origin", it.origin)
                    .put("updatedAt", it.updatedAt)
                // 头像：本地文件就带上，网络图先下载
                val av = ChatArchive.readImage(ctx, it.avatar)
                if (av != null) {
                    val ext = av.second
                    entries[base + "avatar.$ext"] = av.first
                    role.put("avatar", "avatar.$ext")
                } else {
                    role.put("avatar", "")
                    if (it.avatar.isNotBlank()) missing++
                }
                // 形象图：目前客户端没有这个数据源，只有目录存在时才带上（未来兼容）
                val gal = File(ctx.filesDir, "persona_gallery/${san(it.id)}")
                if (gal.isDirectory) {
                    gal.listFiles()?.sortedBy { f -> f.name }?.forEachIndexed { i, f ->
                        if (!f.isFile || f.length() < 64) return@forEachIndexed
                        val ext = ChatArchive.extOf(f.readBytes(), f.name)
                        entries[base + "gallery/${i + 1}.$ext"] = f.readBytes()
                    }
                }
                entries[base + "role.json"] = role.toString().toByteArray()
                nRole++
            }

            // ---------- 聊天 ----------
            val all = Api.packConvs()
            all.keys().forEach { pid ->
                val arr = all.optJSONArray(pid) ?: return@forEach
                val msgs = JSONObject()
                var count = 0
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    count++
                    val img = o.optString("i")
                    if (img.isNotBlank()) {
                        val payload = ChatArchive.readImage(ctx, img)
                        if (payload != null) {
                            val name = "%03d.%s".format(i + 1, payload.second)
                            val dir = pid.replace('/', '_')
                            entries["images/$dir/$name"] = payload.first
                            o.put("i", "images/$dir/$name")
                            nImg++
                        } else {
                            missing++
                        }
                    }
                    msgs.put(i.toString(), o)
                }
                if (count == 0) return@forEach
                entries["chats/${pid.replace('/', '_')}.json"] = arr.toString().toByteArray()
                convsOut.put(pid, arr)
                nConv++
                nMsg += count
            }

            // ---------- 我的资料 / 头像 ----------
            val me = Api.cachedMe()
            val profile = JSONObject()
                .put("nickname", me?.nickname.orEmpty())
                .put("avatar", "")
                .put("membership", me?.membership.orEmpty())
                .put("city", ChatPrefs.city)
            val myAvatar = ChatArchive.readImage(ctx, me?.avatar.orEmpty())
            if (myAvatar != null) {
                entries["me/avatar.${myAvatar.second}"] = myAvatar.first
                profile.put("avatar", "avatar.${myAvatar.second}")
            } else if (!me?.avatar.isNullOrBlank()) missing++
            entries["me/profile.json"] = profile.toString().toByteArray()

            // ---------- 背景原图 ----------
            val bgApp = File(ctx.filesDir, "bg/app.jpg")
            val bgChat = File(ctx.filesDir, "bg/chat.jpg")
            if (bgApp.exists() && bgApp.length() > 64) {
                entries["backgrounds/app.jpg"] = bgApp.readBytes(); bgCount++
            }
            if (bgChat.exists() && bgChat.length() > 64) {
                entries["backgrounds/chat.jpg"] = bgChat.readBytes(); bgCount++
            }

            // ---------- 设置 ----------
            entries["settings.json"] = dumpSettings(bgApp.exists(), bgChat.exists())
                .toString().toByteArray()

            // ---------- manifest ----------
            val manifest = JSONObject()
                .put("ver", VER)
                .put("exported_at", System.currentTimeMillis())
                .put("app", com.aevis.android.BuildConfig.VERSION_NAME)
                .put("roles", nRole)
                .put("convs", nConv)
                .put("msgs", nMsg)
                .put("images", nImg)
                .put("backgrounds", bgCount)
                .put("missing", missing)

            ZipOutputStream(out.outputStream().buffered()).use { zos ->
                fun put(name: String, bytes: ByteArray) {
                    zos.putNextEntry(ZipEntry(name))
                    zos.write(bytes)
                    zos.closeEntry()
                }
                put("manifest.json", manifest.toString().toByteArray())
                entries.forEach { (k, v) -> put(k, v) }
            }
            ExportResult(out, nRole, nConv, nMsg, nImg, missing)
        } catch (e: Exception) {
            ExportResult(null, err = e.message ?: "打包失败")
        }
    }

    /** 设置全量（2026-11-16，124）：只存"文件名"，不存绝对路径。*/
    private fun dumpSettings(hasAppBg: Boolean, hasChatBg: Boolean): JSONObject = JSONObject()
        .put("themeMode", ThemePrefs.mode)
        .put("appBgType", ChatPrefs.appBgType)
        .put("appBgFile", if (hasAppBg) "app.jpg" else "")
        .put("appBgValueIsColor", ChatPrefs.appBgValue.startsWith("#"))
        .put("appBgColor", if (ChatPrefs.appBgValue.startsWith("#")) ChatPrefs.appBgValue else "")
        .put("appTint", ChatPrefs.appTint)
        .put("bgOpacity", ChatPrefs.bgOpacity)
        .put("glassAlpha", ChatPrefs.glassAlpha)
        .put("chatBgKind", ChatPrefs.bgKind)
        .put("chatBgPreset", ChatPrefs.bgPreset)
        .put("chatBgBlur", ChatPrefs.bgBlur)
        .put("chatBgDim", ChatPrefs.bgDim)
        .put("chatBgFile", if (hasChatBg) "chat.jpg" else "")
        .put("avatarSize", ChatPrefs.avatarSize)
        .put("bubbleStyle", ChatPrefs.bubbleStyle)
        .put("gap", ChatPrefs.gap)
        .put("msgSize", ChatPrefs.msgSize)
        .put("bubbleWidthPct", ChatPrefs.bubbleWidthPct)
        .put("mineBubble", ChatPrefs.mineBubble)
        .put("aiBubble", ChatPrefs.aiBubble)
        .put("typeSpeed", ChatPrefs.typeSpeed)
        .put("soundOn", ChatPrefs.soundOn)
        .put("autoRestore", ChatPrefs.autoRestore)
        .put("dialogStyle", ChatPrefs.dialogStyle)
        .put("autoLine", ChatPrefs.autoLine)
        .put("replyLen", ChatPrefs.replyLen)
        .put("parenOwnLine", ChatPrefs.parenOwnLine)
        .put("stripSplitPunct", ChatPrefs.stripSplitPunct)
        .put("mergeSend", ChatPrefs.mergeSend)
        .put("ctxWindow", ChatPrefs.ctxWindow)

    // ---------------------------------------------------------------- 预检 / 导入

    /** 复制到 cacheDir 并读 manifest。返回 null = 认不出（调用方回落旧格式）。*/
    fun prepare(ctx: Context, uri: Uri): Plan? {
        return try {
            val dst = File(ctx.cacheDir, "import_full.bin")
            ctx.contentResolver.openInputStream(uri)?.use { ins ->
                dst.outputStream().use { o -> ins.copyTo(o) }
            } ?: return null
            var manifest: JSONObject? = null
            var roles = 0; var convs = 0; var msgs = 0; var images = 0; var bgs = 0
            ZipInputStream(dst.inputStream().buffered()).use { zis ->
                var e = zis.nextEntry
                while (e != null) {
                    if (!e.isDirectory) {
                        when {
                            e.name == "manifest.json" ->
                                manifest = JSONObject(zis.readBytes().toString(Charsets.UTF_8))
                            e.name.startsWith("roles/") && e.name.endsWith("/role.json") -> roles++
                            e.name.startsWith("chats/") && e.name.endsWith(".json") -> convs++
                            e.name.startsWith("images/") -> images++
                            e.name.startsWith("backgrounds/") -> bgs++
                        }
                    }
                    zis.closeEntry()
                    e = zis.nextEntry
                }
            }
            val m = manifest ?: return null
            val ver = m.optInt("ver", 0)
            if (ver != VER) return null          // 交给旧格式（ChatArchive）
            msgs = m.optInt("msgs", 0)
            Plan(dst, ver, roles, convs, msgs, images, bgs)
        } catch (e: Exception) {
            null
        }
    }

    fun apply(ctx: Context, plan: Plan, merge: Boolean = true): ImportResult {
        return try {
            val tmp = File(ctx.cacheDir, "import_full_unzip")
            tmp.deleteRecursively(); tmp.mkdirs()

            ZipInputStream(plan.src.inputStream().buffered()).use { zis ->
                var e = zis.nextEntry
                while (e != null) {
                    if (!e.isDirectory) {
                        val f = File(tmp, e.name)
                        f.parentFile?.mkdirs()
                        runCatching { f.outputStream().use { o -> zis.copyTo(o) } }
                    }
                    zis.closeEntry()
                    e = zis.nextEntry
                }
            }

            var nRoles = 0
            var nImg = 0
            var nBg = 0

            // ---------- 角色 ----------
            val rolesDir = File(tmp, "roles")
            rolesDir.listFiles()?.forEach { rd ->
                val rj = File(rd, "role.json")
                if (!rj.isFile) return@forEach
                val o = runCatching { JSONObject(rj.readText()) }.getOrNull() ?: return@forEach
                val pid = o.optString("id").ifBlank { rd.name }
                if (pid.isBlank()) return@forEach
                // 头像：roles/<pid>/avatar.* → files/personas/<pid>.<ext>
                var avatar = LocalPersonaStore.find(pid)?.avatar.orEmpty()
                rd.listFiles()?.firstOrNull {
                    it.isFile && it.name.startsWith("avatar.")
                }?.let { av ->
                    val dstDir = File(ctx.filesDir, "personas").also { if (!it.exists()) it.mkdirs() }
                    val dst = File(dstDir, sanitizeFile(pid) + "." + av.extension.ifEmpty { "jpg" })
                    runCatching { av.copyTo(dst, overwrite = true); avatar = dst.absolutePath }
                }
                // 形象图
                File(rd, "gallery").listFiles()?.sortedBy { it.name }?.forEach { g ->
                    if (!g.isFile || g.length() < 64) return@forEach
                    val gd = File(ctx.filesDir, "persona_gallery/${sanitizeFile(pid)}")
                    gd.mkdirs()
                    runCatching { g.copyTo(File(gd, g.name), overwrite = true) }
                }
                // 本地已有角色 → 不覆盖名字/人设（合并模式下以本地为准），只补空字段
                val exist = LocalPersonaStore.find(pid)
                if (exist != null && merge) {
                    LocalPersonaStore.update(
                        pid,
                        avatar = if (exist.avatar.isBlank()) avatar else exist.avatar,
                        persona = if (exist.persona.isBlank()) o.optString("persona") else exist.persona,
                        style = if (exist.style.isBlank()) o.optString("style") else exist.style
                    )
                } else {
                    LocalPersonaStore.save(
                        LocalPersonaStore.Item(
                            id = pid,
                            name = o.optString("name").ifBlank { exist?.name ?: "恢复的角色" },
                            avatar = avatar,
                            persona = o.optString("persona"),
                            style = o.optString("style"),
                            origin = o.optString("origin").ifBlank { "restore" },
                            updatedAt = 0L
                        )
                    )
                }
                nRoles++
            }

            // ---------- 聊天（消息里的图片路径先还原成本机绝对路径） ----------
            val chatConvs = JSONObject()
            File(tmp, "chats").listFiles()?.forEach { cf ->
                if (!cf.isFile || !cf.name.endsWith(".json")) return@forEach
                val pid = cf.nameWithoutExtension
                val arr = runCatching { org.json.JSONArray(cf.readText()) }.getOrNull() ?: return@forEach
                for (i in 0 until arr.length()) {
                    val m = arr.optJSONObject(i) ?: continue
                    val img = m.optString("i")
                    if (img.startsWith("images/")) {
                        val rel = img.removePrefix("images/")
                        val src = File(File(tmp, "images"), rel)
                        if (src.isFile) {
                            val dstDir = File(ctx.filesDir, "chatimg").also { d -> if (!d.exists()) d.mkdirs() }
                            val dst = File(dstDir, rel.replace('/', '_'))
                            runCatching { src.copyTo(dst, overwrite = true) }
                            m.put("i", dst.absolutePath)
                            nImg++
                        } else {
                            m.put("i", "")
                        }
                    }
                }
                chatConvs.put(pid, arr)
            }
            // dedup=false：整包声明为完整记录，导入时不做内容去重
            val manObj = runCatching {
                org.json.JSONObject(File(tmp, "manifest.json").readText(Charsets.UTF_8))
            }.getOrNull()
            val noDedup = manObj != null && manObj.has("dedup") && !manObj.optBoolean("dedup", true)
            val chatRes = if (chatConvs.length() > 0) {
                ChatArchive.applyJson(
                    ctx, JSONObject().put("convs", chatConvs).toString(), merge, null, noDedup
                )
            } else ChatArchive.ImportResult()

            // ---------- 我的资料 ----------
            val meDir = File(tmp, "me")
            val pj = File(meDir, "profile.json")
            if (pj.isFile) {
                val o = runCatching { JSONObject(pj.readText()) }.getOrNull()
                if (o != null) {
                    meDir.listFiles()?.firstOrNull { it.isFile && it.name.startsWith("avatar.") }?.let { av ->
                        val dstDir = File(ctx.filesDir, "avatars").also { if (!it.exists()) it.mkdirs() }
                        val dst = File(dstDir, "me." + av.extension.ifEmpty { "jpg" })
                        runCatching { av.copyTo(dst, overwrite = true) }
                        Api.saveMe(
                            Api.MeInfo(
                                nickname = o.optString("nickname"),
                                avatar = dst.absolutePath,
                                email = Api.email(),
                                uid = Api.uid(),
                                membership = o.optString("membership")
                            )
                        )
                    }
                    if (o.optString("city").isNotBlank()) ChatPrefs.city = o.optString("city")
                }
            }

            // ---------- 背景 ----------
            val bgs = File(tmp, "backgrounds")
            val bgDir = File(ctx.filesDir, "bg").also { if (!it.exists()) it.mkdirs() }
            File(bgs, "app.jpg").takeIf { it.isFile }?.let {
                runCatching { it.copyTo(File(bgDir, "app.jpg"), overwrite = true); nBg++ }
            }
            File(bgs, "chat.jpg").takeIf { it.isFile }?.let {
                runCatching { it.copyTo(File(bgDir, "chat.jpg"), overwrite = true); nBg++ }
            }

            // ---------- 设置 ----------
            File(tmp, "settings.json").takeIf { it.isFile }?.let { sf ->
                runCatching { applySettings(JSONObject(sf.readText()), ctx, nBg) }
            }

            tmp.deleteRecursively()
            plan.src.delete()
            ImportResult(nRoles, chatRes.convs, chatRes.msgs, maxOf(nImg, chatRes.images), nBg)
        } catch (e: Exception) {
            ImportResult(err = e.message ?: "导入失败")
        }
    }

    /** 设置回写。**不动**账号身份（email/uid），只改外观与聊天行为。*/
    private fun applySettings(o: JSONObject, ctx: Context, restoredBgCount: Int) {
        runCatching { ThemePrefs.mode = o.optInt("themeMode", ThemePrefs.mode) }
        runCatching { ChatPrefs.avatarSize = o.optInt("avatarSize", ChatPrefs.avatarSize) }
        runCatching { ChatPrefs.bubbleStyle = o.optInt("bubbleStyle", ChatPrefs.bubbleStyle) }
        runCatching { ChatPrefs.gap = o.optInt("gap", ChatPrefs.gap) }
        runCatching { ChatPrefs.msgSize = o.optInt("msgSize", ChatPrefs.msgSize) }
        runCatching { ChatPrefs.bubbleWidthPct = o.optInt("bubbleWidthPct", ChatPrefs.bubbleWidthPct) }
        runCatching { ChatPrefs.mineBubble = o.optInt("mineBubble", ChatPrefs.mineBubble) }
        runCatching { ChatPrefs.aiBubble = o.optInt("aiBubble", ChatPrefs.aiBubble) }
        runCatching { ChatPrefs.typeSpeed = o.optInt("typeSpeed", ChatPrefs.typeSpeed) }
        runCatching { ChatPrefs.soundOn = o.optBoolean("soundOn", ChatPrefs.soundOn) }
        runCatching { ChatPrefs.autoRestore = o.optBoolean("autoRestore", ChatPrefs.autoRestore) }
        runCatching { ChatPrefs.dialogStyle = o.optInt("dialogStyle", ChatPrefs.dialogStyle) }
        runCatching { ChatPrefs.autoLine = o.optBoolean("autoLine", ChatPrefs.autoLine) }
        runCatching { ChatPrefs.replyLen = o.optInt("replyLen", ChatPrefs.replyLen) }
        runCatching { ChatPrefs.parenOwnLine = o.optBoolean("parenOwnLine", ChatPrefs.parenOwnLine) }
        runCatching { ChatPrefs.stripSplitPunct = o.optBoolean("stripSplitPunct", ChatPrefs.stripSplitPunct) }
        runCatching { ChatPrefs.mergeSend = o.optBoolean("mergeSend", ChatPrefs.mergeSend) }
        runCatching { ChatPrefs.ctxWindow = o.optInt("ctxWindow", ChatPrefs.ctxWindow) }
        runCatching { ChatPrefs.appTint = o.optBoolean("appTint", ChatPrefs.appTint) }
        runCatching { ChatPrefs.bgOpacity = o.optInt("bgOpacity", ChatPrefs.bgOpacity) }
        runCatching { ChatPrefs.glassAlpha = o.optInt("glassAlpha", ChatPrefs.glassAlpha) }
        // 聊天背景（chatbg 页那套）
        runCatching { ChatPrefs.bgKind = o.optInt("chatBgKind", ChatPrefs.bgKind) }
        runCatching { ChatPrefs.bgPreset = o.optInt("chatBgPreset", ChatPrefs.bgPreset) }
        runCatching { ChatPrefs.bgBlur = o.optInt("chatBgBlur", ChatPrefs.bgBlur) }
        runCatching { ChatPrefs.bgDim = o.optInt("chatBgDim", ChatPrefs.bgDim) }
        // 主背景：有原图就用图片模式，否则按导出的纯色还原
        val type = o.optString("appBgType")
        when {
            restoredBgCount > 0 && o.optString("appBgFile").isNotBlank() -> {
                ChatPrefs.appBgValue = File(ctx.filesDir, "bg/app.jpg").absolutePath
                ChatPrefs.appBgType = "image"
            }
            type == "solid" && o.optString("appBgColor").isNotBlank() -> {
                ChatPrefs.appBgValue = o.optString("appBgColor")
                ChatPrefs.appBgType = "solid"
            }
        }
    }

    /** zip 里的路径只留安全字符（pid 可能带 `@` / `.` / 中文）。*/
    private fun san(s: String): String =
        s.replace(Regex("[^A-Za-z0-9_\\-]"), "_")

    /** 落本地文件名（保留可读性，去掉路径分隔符）。*/
    private fun sanitizeFile(s: String): String =
        s.replace(Regex("[\\\\/:*?\"<>|]"), "_")
}
