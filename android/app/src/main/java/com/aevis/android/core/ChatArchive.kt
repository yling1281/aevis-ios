package com.aevis.android.core

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import com.aevis.android.data.Api
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * 聊天记录打包（2026-11-16，117）：**ZIP + 图片**。
 *
 * 以前的导出是纯 JSON，`img` 里存的是本机绝对路径 —— 换台手机导进去，
 * 图片全变成空白块（路径在这台机器上不存在）。这一版改成：
 *
 * ```
 * aevis-chat-YYYYMMDD-HHMM.zip
 * ├─ manifest.json   { ver, exported_at, app, convs, msgs, images, missing }
 * ├─ chats.json      现有导出 JSON 结构（`{app, version, exported_at, convs:{pid:[msg...]}}`）
 * └─ images/         p1_001.jpg / p1_002.png …
 * ```
 *
 * `chats.json` 里含图消息的 `i` 改写成**相对路径**（`images/p1_001.jpg`），
 * 导入时再还原成这台机器上的绝对路径（`files/chatimg/...`）。
 *
 * 兼容：导入同时认 ZIP 和**旧版纯 JSON**（老用户手里的文件不能导不进去）。
 *
 * ⚠️ 图片命名里带的是「会话序号_消息序号」，不是原始文件名 —— 原始文件名可能重复、
 *    也可能带中文/空格，进 zip 之后容易踩路径问题。
 */
object ChatArchive {

    /** 导出结果（`file == null` 时看 `err`）。*/
    data class ExportResult(
        val file: File?,
        val convs: Int = 0,
        val msgs: Int = 0,
        val images: Int = 0,
        val missing: Int = 0,
        val err: String = ""
    )

    /**
     * 导入前的「预检」结果 —— 只解析不落盘。
     *
     * 界面拿它弹确认框（「N 个会话 / M 条消息 / K 张图片，覆盖还是合并」），
     * 用户点了才 `apply()`。`src` 是已经复制到 cacheDir 的临时文件。
     */
    data class Plan(
        val src: File,
        val isZip: Boolean,
        val convs: Int,
        val msgs: Int,
        val images: Int,
        val note: String = ""
    )

    data class ImportResult(
        val convs: Int = 0,
        val msgs: Int = 0,
        val images: Int = 0,
        val err: String = ""
    )

    private const val MANIFEST = "manifest.json"
    private const val CHATS = "chats.json"
    private const val IMG_DIR = "images/"

    // ---------------------------------------------------------------- 导出

    /** 生成 zip（IO 线程调用）。失败返回 `ExportResult(null, err = …)`。*/
    fun export(ctx: Context, convsJson: String): ExportResult {
        return try {
            val root = JSONObject(convsJson)
            val convs = root.optJSONObject("convs") ?: JSONObject()
            val imgRoot = File(ctx.filesDir, "chatimg")
            if (!imgRoot.exists()) imgRoot.mkdirs()

            val dir = File(ctx.cacheDir, "exports")
            if (!dir.exists()) dir.mkdirs()
            val stamp = java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US)
                .format(java.util.Date())
            val out = File(dir, "aevis-chat-$stamp.zip")

            var msgCount = 0
            var imgCount = 0
            var missing = 0
            // 相对路径 → 字节（先全部准备好再写 zip：写一半失败不会留半个包）
            val images = LinkedHashMap<String, ByteArray>()

            val pids = convs.keys().asSequence().toList()
            pids.forEachIndexed { ci, pid ->
                val arr = convs.optJSONArray(pid) ?: return@forEachIndexed
                for (mi in 0 until arr.length()) {
                    val m = arr.optJSONObject(mi) ?: continue
                    msgCount++
                    val img = m.optString("i")
                    if (img.isBlank()) continue
                    val payload = readImage(ctx, img)
                    if (payload == null) {
                        // 下不下来就别中断整包 —— 保留原值，manifest 里记一笔
                        missing++
                        continue
                    }
                    val rel = IMG_DIR + "p${ci + 1}_" +
                        "%03d".format(mi + 1) + "." + payload.second
                    images[rel] = payload.first
                    m.put("i", rel)
                    imgCount++
                }
            }

            val manifest = JSONObject()
                .put("ver", 1)
                .put("exported_at", System.currentTimeMillis())
                .put("app", com.aevis.android.BuildConfig.VERSION_NAME)
                .put("convs", pids.size)
                .put("msgs", msgCount)
                .put("images", imgCount)
                .put("missing", missing)

            ZipOutputStream(out.outputStream().buffered()).use { zos ->
                zos.putNextEntry(ZipEntry(MANIFEST))
                zos.write(manifest.toString().toByteArray())
                zos.closeEntry()

                zos.putNextEntry(ZipEntry(CHATS))
                zos.write(root.toString().toByteArray())
                zos.closeEntry()

                images.forEach { (name, bytes) ->
                    zos.putNextEntry(ZipEntry(name))
                    zos.write(bytes)
                    zos.closeEntry()
                }
            }
            ExportResult(out, pids.size, msgCount, imgCount, missing)
        } catch (e: Exception) {
            ExportResult(null, err = e.message ?: "打包失败")
        }
    }

    /**
     * 读一张消息图片的原始字节 + 扩展名。
     *
     * 三种来源：本机绝对路径 / `file://` → 直接读文件；
     * `/v1/media/…`、`http(s)://` → 先看加密图片缓存，没命中再下载。
     * 拿不到返回 null（调用方记 missing）。
     */
    internal fun readImage(ctx: Context, img: String): Pair<ByteArray, String>? {
        // 1) 本地文件
        val local = when {
            img.startsWith("file://") -> Uri.parse(img).path.orEmpty()
            img.startsWith("/") && !img.startsWith("/v1/") -> img
            else -> ""
        }
        if (local.isNotEmpty()) {
            val f = File(local)
            if (f.exists() && f.length() > 64) {
                val bytes = runCatching { f.readBytes() }.getOrNull()
                if (bytes != null) return bytes to extOf(bytes, local)
            }
        }
        // 2) 网络图：先吃 Avatar 那套加密缓存，再下载
        val cached = runCatching { SecureCache.getBytes(ctx, "img:" + img) }.getOrNull()
        if (cached != null && cached.size > 64) return cached to extOf(cached, img)

        val bmp = runCatching {
            kotlinx.coroutines.runBlocking { Api.fetchImage(img) }
        }.getOrNull() ?: return null
        val bos = ByteArrayOutputStream()
        return if (bmp.hasAlpha()) {
            bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
            bos.toByteArray() to "png"
        } else {
            bmp.compress(Bitmap.CompressFormat.JPEG, 88, bos)
            bos.toByteArray() to "jpg"
        }
    }

    /** 按文件头判格式（不认扩展名 —— 服务端给的 `.jpg` 实际可能是 png）。*/
    internal fun extOf(bytes: ByteArray, fallback: String): String {
        if (bytes.size >= 8 &&
            bytes[0] == 0x89.toByte() && bytes[1] == 'P'.code.toByte()
        ) return "png"
        if (bytes.size >= 3 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()) return "jpg"
        if (bytes.size >= 12 &&
            bytes[8] == 'W'.code.toByte() && bytes[9] == 'E'.code.toByte() &&
            bytes[10] == 'B'.code.toByte() && bytes[11] == 'P'.code.toByte()
        ) return "webp"
        if (bytes.size >= 3 && bytes[0] == 'G'.code.toByte() && bytes[1] == 'I'.code.toByte()) return "gif"
        return fallback.substringAfterLast('.', "jpg").lowercase().ifEmpty { "jpg" }
    }

    // ---------------------------------------------------------------- 导入

    /**
     * 预检：把用户选的文件复制到 cacheDir，数一数里面有多少东西。
     *
     * ZIP 和旧版 JSON 都走这里（`isZip` 用来给界面换个提示词）。
     */
    fun prepare(ctx: Context, uri: Uri): Plan? {
        return try {
            val dst = File(ctx.cacheDir, "import_pending.bin")
            ctx.contentResolver.openInputStream(uri)?.use { ins ->
                dst.outputStream().use { out -> ins.copyTo(out) }
            } ?: return null
            if (dst.length() < 8) return null

            val head = dst.inputStream().use { i -> ByteArray(4).also { i.read(it) } }
            val isZip = head[0] == 'P'.code.toByte() && head[1] == 'K'.code.toByte()
            if (!isZip) {
                // 旧版 JSON：能归一成「会话 → 消息数组」就认（123：扁平 map 也认）
                val text = dst.readText()
                val convs = convsOf(JSONObject(text)) ?: return null
                var msgs = 0
                convs.keys().forEach { pid ->
                    msgs += convs.optJSONArray(pid)?.length() ?: 0
                }
                return Plan(dst, false, convs.length(), msgs, 0, "JSON（不含图片）")
            }

            var chats: String? = null
            var images = 0
            ZipInputStream(dst.inputStream().buffered()).use { zis ->
                var e = zis.nextEntry
                while (e != null) {
                    val name = e.name
                    if (!e.isDirectory) {
                        if (name == CHATS || name.endsWith("/" + CHATS) || name == "chats.json") {
                            chats = zis.readBytes().toString(Charsets.UTF_8)
                        } else if (name.startsWith(IMG_DIR) || name.contains("/images/")) {
                            images++
                        }
                    }
                    zis.closeEntry()
                    e = zis.nextEntry
                }
            }
            val convs = chats?.let { convsOf(JSONObject(it)) } ?: return null
            var msgs = 0
            convs.keys().forEach { pid ->
                msgs += convs.optJSONArray(pid)?.length() ?: 0
            }
            Plan(dst, true, convs.length(), msgs, images)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * 真正导入。`merge = true`（默认）追加并按 `(会话, 角色, 内容, 发言人, 图片名)` 去重；
     * `merge = false` 覆盖本地同 id 的会话。
     *
     * ⚠️ 消息模型里**没有时间字段**（`Api.Msg` 只有 role/content/who/img/skip/quote），
     * 所以这里的去重键用「角色 + 内容 + 发言人 + 引用 + 图片文件名」的哈希，
     * 而不是判据里写的「会话id, 时间, 内容hash」—— 时间根本不存在，硬凑会误伤。
     */
    fun apply(ctx: Context, plan: Plan, merge: Boolean = true): ImportResult {
        return try {
            val imgDir = File(ctx.filesDir, "chatimg")
            if (!imgDir.exists()) imgDir.mkdirs()

            val convsJson: String
            var noDedup = false
            if (plan.isZip) {
                var chats: String? = null
                // 第一遍：把图片还原到私有目录（先落地，chats.json 里才能写绝对路径）
                ZipInputStream(plan.src.inputStream().buffered()).use { zis ->
                    var e = zis.nextEntry
                    while (e != null) {
                        if (!e.isDirectory) {
                            val name = e.name
                            if (name == CHATS || name.endsWith("/" + CHATS)) {
                                chats = zis.readBytes().toString(Charsets.UTF_8)
                            } else if (name == MANIFEST || name.endsWith("/" + MANIFEST)) {
                                // dedup=false：包内是完整记录，导入时不要按 (role,content) 去重
                                val man = runCatching {
                                    org.json.JSONObject(zis.readBytes().toString(Charsets.UTF_8))
                                }.getOrNull()
                                if (man != null && man.has("dedup") && !man.optBoolean("dedup", true)) {
                                    noDedup = true
                                }
                            } else if (name.startsWith(IMG_DIR) || name.contains("/images/")) {
                                val base = if (name.startsWith(IMG_DIR))
                                    name.removePrefix(IMG_DIR)
                                else name.substringAfterLast("/images/")
                                val f = File(imgDir, base)
                                runCatching { f.outputStream().use { o -> zis.copyTo(o) } }
                            }
                        }
                        zis.closeEntry()
                        e = zis.nextEntry
                    }
                }
                convsJson = chats ?: return ImportResult(err = "压缩包里没有 chats.json")
            } else {
                convsJson = plan.src.readText()
            }
            applyJson(ctx, convsJson, merge, imgDir, noDedup)
        } catch (e: Exception) {
            ImportResult(err = e.message ?: "导入失败")
        } finally {
            runCatching { plan.src.delete() }
        }
    }

    /**
     * 把一段备份 JSON 写回本地（2026-11-16，119；123 起兼容三种形状）。
     *
     * 恢复码（`/v1/chat/recover`）拿到的 `payload` 是**扁平 map**（会话 id 直接在顶层，
     * 没有 `{"convs":{…}}` 这层），而 ZIP 里的 `chats.json` 是有 `convs` 的。
     * 所以入口先做**形状归一**，再走同一条写回路径 —— 去重、图片相对路径还原都在这里。
     */
    fun applyJson(
        ctx: Context,
        convsJson: String,
        merge: Boolean = true,
        imgDir: File? = null,
        noDedup: Boolean = false
    ): ImportResult {
        val dir = imgDir ?: File(ctx.filesDir, "chatimg").also { if (!it.exists()) it.mkdirs() }
        return try {
            val root = JSONObject(convsJson)
            val convs = convsOf(root)
                ?: return ImportResult(
                    err = "没能认出备份结构（顶层 ${root.length()} 个键，首个是 " +
                        "'${root.keys().asSequence().firstOrNull() ?: "空"}'）"
                )
            var nConv = 0
            var nMsg = 0
            var nImg = 0
            var nPlaceholder = 0
            // 123：同一个角色的两份键（`srv_<uid>_<uuid>` 与 `srv_<uid>_<email>`）内容完全重复，
            // 按「首条消息 + 条数」认一次重复，只写第一份。
            val seenConv = HashSet<String>()
            convs.keys().forEach { pid ->
                val arr = convs.optJSONArray(pid) ?: return@forEach
                val incoming = ArrayList<Api.Msg>(arr.length())
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    var img = o.optString("i")
                    // 相对路径 → 这台机器上的绝对路径（图片已在上一步还原）
                    val base = when {
                        img.startsWith(IMG_DIR) -> img.removePrefix(IMG_DIR)
                        img.contains("/images/") -> img.substringAfterLast("/images/")
                        else -> ""
                    }
                    if (base.isNotEmpty()) {
                        val f = File(dir, base)
                        if (f.exists()) {
                            img = f.absolutePath
                            nImg++
                        }
                    }
                    // 123：字段兼容 —— 服务端有的给 `content`，有的给 `body`；
                    // `role` 可能是 `ai`，统一按 assistant 处理（界面只认这两个值）。
                    val role = when (val r = o.optString("role").lowercase()) {
                        "ai", "assistant", "model" -> "assistant"
                        "human" -> "user"
                        else -> r
                    }
                    val content = o.optString("content")
                        .ifEmpty { o.optString("body") }
                    incoming.add(
                        Api.Msg(
                            role = role.ifEmpty { "user" },
                            content = content,
                            who = o.optString("w"),
                            img = img,
                            skip = o.optString("x") == "1",
                            quote = o.optString("q")
                        )
                    )
                }
                if (incoming.isEmpty()) return@forEach

                // 会话级去重：首条消息内容 + 条数相同就当同一份，只留第一份
                val first = incoming.first()
                val convKey = (first.content.take(60) + "|" + incoming.size)
                if (!seenConv.add(convKey)) {
                    android.util.Log.i(
                        "AevisArchive", "跳过重复会话 $pid（${incoming.size} 条，与已导入的重合）"
                    )
                    return@forEach
                }

                // 123（关键）：孤儿会话补一个**占位角色**。
                // 「季焚时」这种是纯本地角色（服务端 auth_persona 是空的、persona_public 里也没有），
                // 备份里只有消息没有人设 —— 不补占位的话消息写进去了但列表里看不到、点不进。
                if (LocalPersonaStore.find(pid) == null) {
                    LocalPersonaStore.save(
                        LocalPersonaStore.Item(
                            id = pid,
                            name = nameHintFor(incoming),
                            avatar = "",
                            persona = "",
                            style = "",
                            origin = "restore",   // 列表据此显示「待完善」
                            updatedAt = 0L
                        )
                    )
                    nPlaceholder++
                }

                val next = if (merge) {
                    val existing = Api.loadConv(pid)
                    if (noDedup) {
                        // 包内声明 dedup=false：完整记录，按序追加，不做内容去重
                        ArrayList<Api.Msg>(existing.size + incoming.size).apply {
                            addAll(existing); addAll(incoming)
                        }
                    } else {
                        val seen = HashSet<String>()
                        val out = ArrayList<Api.Msg>(existing.size + incoming.size)
                        (existing + incoming).forEach { m ->
                            val key = dedupKey(m)
                            if (seen.add(key)) out.add(m)
                        }
                        out
                    }
                } else incoming
                Api.saveConv(pid, next)
                nConv++
                nMsg += incoming.size
            }
            if (nConv == 0) ImportResult(err = "备份里没有可恢复的消息")
            else {
                // 诊断（123）：会话写回来了，但列表只列角色 —— 本地没有对应角色的话，
                // 用户点不到这个会话。日志里报个数，方便现场判断"是要补角色还是数据本来就没有"。
                if (nPlaceholder > 0) android.util.Log.i(
                    "AevisArchive", "给 $nPlaceholder 个孤儿会话建了占位角色（origin=restore）"
                )
                ImportResult(nConv, nMsg, nImg)
            }
        } catch (e: Exception) {
            ImportResult(err = e.message ?: "导入失败")
        }
    }

    /**
     * 把三种备份形状统一成「会话 id → 消息数组」（2026-11-16，123）：
     *
     * 1. `{"convs":{id:[…]}}`（ZIP 的 chats.json、老导出）
     * 2. `{"data":{"convs":{…}}}`（某些接口的包装）
     * 3. **扁平 map** `{"local_123":[…], "srv_9_xx":[…]}`（恢复码接口的 payload，就是这种）
     * 4. `{"data":{id:[…]}}`（扁平再包一层）
     *
     * 认不出返回 null（调用方给"收到 N 个键 / 首个键名"这种可诊断的错误）。
     */
    fun convsOf(root: JSONObject): JSONObject? {
        // 有显式 convs 就用它
        root.optJSONObject("convs")?.let { if (it.length() > 0) return it }
        val data = root.optJSONObject("data")
        data?.optJSONObject("convs")?.let { if (it.length() > 0) return it }
        // 扁平：顶层所有「值是数组」的键当会话
        pickArrays(root)?.let { return it }
        data?.let { pickArrays(it) }?.let { return it }
        return null
    }

    /** 从一个 JSONObject 里挑出「值全是数组」的键；一个都没有返回 null。*/
    private fun pickArrays(o: JSONObject): JSONObject? {
        val out = JSONObject()
        o.keys().forEach { k ->
            val v = o.opt(k)
            if (v is JSONArray) out.put(k, v)
            else if (v is JSONObject) {
                // 有的备份是 {"id": {"msgs":[…]}} 这种，也吃下来
                val inner = v.optJSONArray("msgs") ?: v.optJSONArray("messages")
                if (inner != null) out.put(k, inner)
            }
        }
        return if (out.length() > 0) out else null
    }

    /** 去重键：角色 + 内容 + 发言人 + 引用 + 图片**文件名**（绝对路径跨设备不同）。*/
    private fun dedupKey(m: Api.Msg): String {
        val imgKey = m.img.substringAfterLast('/')
        return m.role + "\u0001" + m.content + "\u0001" + m.who + "\u0001" + m.quote + "\u0001" + imgKey
    }

    /**
     * 占位角色的名字（2026-11-16，123）。
     *
     * 备份里**没有人设**，只能从首条用户消息里猜一个称呼：
     * 太长的句子（带标点/感叹）不当名字，招呼语也不当（「你好」「在吗」）。
     * 猜不出来就叫「恢复的角色」—— 宁可平淡，也不要编一个假名字。
     */
    private fun nameHintFor(msgs: List<Api.Msg>): String {
        val firstUser = msgs.firstOrNull { it.role == "user" && it.content.isNotBlank() }
        val t = firstUser?.content.orEmpty().trim().replace(Regex("\\s+"), " ")
        val ban = listOf("你好", "您好", "在吗", "在不在", "hi", "hello", "嗨", "哈喽")
        val okLen = t.length in 2..12
        val noPunct = t.none { it in "，。！？、,.!?～~…" }
        val notGreeting = ban.none { t.equals(it, ignoreCase = true) }
        return if (okLen && noPunct && notGreeting) t else "恢复的角色"
    }
}
