package com.aevis.android.ui

/**
 * 人设里「正文」和「系统设定」的拆分（2026-11-16，94）。
 *
 * 用户填的性格栏里经常整段都是提示词模板（`/系统级命令（需要细致描述…`、`【物品】…`），
 * 编辑页不该把它当正文大段裸露。**按段落**判定（按空行/换行切）：
 * 只要该段命中下面任一关键字，整段进「高级设定」，默认收起。
 *
 * 判定用「段落」而不是「整段长度」—— 之前那个 150 字阈值对"整段都是系统命令、总长也才 150 字"
 * 的人设完全失效，等于没折叠。
 */
private val ADV_MARKERS = listOf("/系统级命令", "/系统", "【", "（需要细致描述")

/** 这段是不是系统设定。*/
internal fun isAdvancedParagraph(para: String): Boolean {
    val t = para.trim()
    if (t.isEmpty()) return false
    return ADV_MARKERS.any { t.contains(it) }
}

/** 拆出来的两半（`advancedIdx` 记住每段原来在第几段，重组时放回原位）。*/
internal data class PersonaSplit(
    val body: String,
    val advanced: String,
    val advancedParas: List<String>,
    val advancedIdx: List<Int>
)

/** 按段落切（连续空行算一个分隔）。*/
private fun paragraphs(text: String): List<String> =
    text.replace("\r\n", "\n")
        .split(Regex("\n\\s*\n"))
        .flatMap { block -> block.split("\n") }
        .map { it.trim() }
        .filter { it.isNotEmpty() }

/** 拆分：命中关键字的段进 advanced，其余留在 body，**各自保持原顺序**。*/
internal fun splitPersona(text: String): PersonaSplit {
    val paras = paragraphs(text)
    val body = ArrayList<String>()
    val adv = ArrayList<String>()
    val idx = ArrayList<Int>()
    paras.forEachIndexed { i, para ->
        if (isAdvancedParagraph(para)) {
            adv.add(para)
            idx.add(i)
        } else {
            body.add(para)
        }
    }
    return PersonaSplit(
        body = body.joinToString("\n\n"),
        advanced = adv.joinToString("\n\n"),
        advancedParas = adv,
        advancedIdx = idx
    )
}

/**
 * 重组：把 advanced 段落按原下标插回 body（下标越界就追加到末尾）。
 * 保存时用这个 —— **顺序不变、原文一个字都不改**。
 */
internal fun mergePersona(body: String, advancedParas: List<String>, advancedIdx: List<Int>): String {
    if (advancedParas.isEmpty()) return body
    val out = ArrayList<String>()
    paragraphs(body).forEach { out.add(it) }
    advancedParas.forEachIndexed { k, para ->
        val at = (advancedIdx.getOrNull(k) ?: out.size).coerceIn(0, out.size)
        out.add(at, para)
    }
    return out.joinToString("\n\n")
}
