package com.aevis.android.ui

import android.Manifest
import android.content.pm.PackageManager
import android.annotation.SuppressLint
import android.os.Build
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.activity.compose.BackHandler
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.core.content.ContextCompat
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.window.Dialog
import androidx.compose.material3.TextButton
import kotlinx.coroutines.delay
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.aevis.android.BuildConfig
import com.aevis.android.R
import com.aevis.android.core.LiveUpdate
import com.aevis.android.core.LocalPersonaStore
import com.aevis.android.core.NativeCore
import com.aevis.android.core.PersonaLib
import com.aevis.android.core.NeteaseAuth
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 二级页面（2026-11-14）。
 *
 * 用户那天把所有入口点了一遍，回来说：
 * 「商城正在接入安卓版，朋友圈打不开…浏览器打不开…你啥也不行」。
 * 之前这些全是 `Toast("正在接入安卓版")` —— **摆出来又点不动，比没有更糟**。
 * 这里把能真开的先做成真页面。
 */

// ------------------------------------------------------------------ 通用外壳

@Composable
private fun PageScaffold(
    title: String,
    onBack: () -> Unit,
    // 2026-11-16：给 `ColumnScope` —— 商城页要在标题下面放一个 `weight(1f)` 的内容区，
    // 不然分段内容会按内容高度撑开、把整页顶出屏幕（用户报的「直接全屏了，会员什么都看不到」）。
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit
) {
    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            // 🔴 2026-11-14 用户：「上面那个商城还是被…你没有安全区」——
            // 一级页（Shell）修过了，但**二级页走的是这个 PageScaffold**，漏了。
            // 商城 / 网易云 / 浏览器 / 通知 / 关于 全都会顶到状态栏下面。
            .statusBarsPadding()
    ) {
        // 顶栏（2026-11-16）：换成公共的 `SubPageHeader` ——
        // 商城 / 网易云 / 浏览器 / 通知 / 关于 五个页面都走这里，换一次就全统一了。
        SubPageHeader(title = title, onBack = onBack)
        content()
    }
}

// ------------------------------------------------------------------ 商城

/**
 * 商城：人设 + 表情包。
 *
 * 后端 `/v1/psquare/list` 是真人设广场（`persona_public`，已过审的才上）。
 * 之前「商城」是个紫色渐变卡片，点了弹「正在接入」。
 */
/**
 * 广场 / 商城（2026-11-16 重排成两套分段，同一个页面两个入口）。
 *
 * 用户把两块分得很清楚：
 *   · **广场**（`plaza`）= 逛：「人设」「表情包」—— 人设来自 `/v1/psquare/list`
 *     全站公共人设（**不是** `mine=true`，那是"我发布的"），表情包来自 `/v1/emoji/list`；
 *   · **商城**（`mall`）= 买：「会员」「音色包」「墨点」—— 会员和墨点**能真买**，
 *     走 `payOrder` → 服务端一次性收银台链接。
 *
 * `startTab` 让首页的「充值」直接落到墨点那一段（`mallpt`），少点一次。
 */
@Composable
fun MallScreen(
    onBack: () -> Unit,
    onOpenPersona: (String) -> Unit = {},
    // 广场「创建人设」入口（2026-11-24）：跳 personanew 走本地创建页。
    onCreatePersona: () -> Unit = {},
    title: String = "广场",
    isPlaza: Boolean = true,
    startTab: Int = 0
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    // 商城多两段（2026-11-27）：会员 / 额度 彻底分开（用户：「会员是签到+赠送+充值卡，
    // 额度是聊天额度，两个不一样的东西」）。index 保持向后兼容：
    //   0 会员 / 1 额度 / 2 墨点（mallpt startTab=2 不受影响）/ 3 按次（startTab=3）/ 4 音色包
    val tabNames = if (isPlaza) listOf(tr("人设"), tr("表情包"))
    else listOf(tr("会员"), tr("额度"), tr("墨点"), tr("按次"), tr("音色包"))

    var tab by remember { mutableIntStateOf(startTab.coerceIn(0, tabNames.size - 1)) }
    // 2026-11-24 硬缓存：冷启动先同步读本地缓存 → 立刻显示；云端有更新才覆盖。
    val cached = remember { com.aevis.android.core.PlazaCache.load(ctx) }
    var list by remember {
        mutableStateOf<List<Api.Persona>?>(cached.personas.ifEmpty { null })
    }
    var packs by remember {
        mutableStateOf<List<Api.EmojiPack>?>(cached.packs.ifEmpty { null })
    }
    var err by remember { mutableStateOf("") }
    // 落盘签名：只有内容真变了才写盘，省电省 IO
    var cacheSig by remember { mutableStateOf(cached.signature) }
    // 连不上服务器提示（有旧缓存时才显示）
    var offline by remember { mutableStateOf(false) }
    // 余额（只有商城显示；拿不到就不显示，不占位）
    var points by remember { mutableIntStateOf(-1) }
    // 2026-11-24：商城商品（会员/按次）服务端驱动 —— 价格、档位数量都不写死
    // 2026-11-25：冷启动先读缓存立即显示，再联网刷新
    var products by remember {
        mutableStateOf<List<Api.ShopProduct>>(com.aevis.android.core.ColdCache.loadProducts(ctx))
    }
    // 广场里点表情 → 大图预览（跟表情页同一个 sheet）
    var preview by remember { mutableStateOf<String?>(null) }

    // 商城下单（会员 / 额度共用）：走 /v1/shop/order，本地出二维码 + 轮询查单。
    // 2026-11-27 之前会员走 /v1/pay/session（只给收银台跳转，没聚合码也轮询不到到账），
    // 现在与 iOS 同源。
    var shopPay by remember { mutableStateOf<PayInfo?>(null) }
    var shopPaying by remember { mutableStateOf(false) }

    fun buyShopProduct(p: Api.ShopProduct) {
        if (shopPaying) return
        shopPaying = true
        scope.launch(Dispatchers.IO) {
            val o = runCatching {
                // 2026-11-27：聚合支付，固定 wxpay（服务端按扫码 UA 自动分流微信/支付宝）
                Api.shopOrder(p.id, "wxpay")
            }.getOrNull()
            withContext(Dispatchers.Main) {
                shopPaying = false
                if (o == null) {
                    Toast.makeText(
                        ctx, Api.lastPayError.ifBlank { "下单失败" }, Toast.LENGTH_LONG
                    ).show()
                } else {
                    val got = when {
                        o.points > 0 -> "%d 墨点".format(o.points)
                        p.points > 0 -> "%d 墨点".format(p.points)
                        o.uses > 0 -> "%d 次".format(o.uses)
                        o.days > 0 -> "%d 天".format(o.days)
                        else -> p.title
                    }
                    shopPay = PayInfo(
                        orderNo = o.orderId,
                        title = p.title,
                        amountYuan = "%.2f".format(java.util.Locale.US, p.priceCents / 100.0),
                        qty = got,
                        qrContent = o.qrContent,
                        kind = if (p.kind == "quota") "quota" else "member",
                        shop = true
                    )
                }
            }
        }
    }

    LaunchedEffect(Unit) {
        if (!isPlaza) {
            points = withContext(Dispatchers.IO) {
                runCatching { Api.balance() }.getOrNull() ?: -1
            }
            val fresh = withContext(Dispatchers.IO) {
                runCatching { Api.shopProducts() }.getOrDefault(emptyList())
            }
            if (fresh.isNotEmpty()) {
                products = fresh
                withContext(Dispatchers.IO) {
                    com.aevis.android.core.ColdCache.saveProducts(ctx, fresh)
                }
            }
        }
    }

    // 只有广场这两段需要网络；商城几段本地就能画。
    // 2026-11-24：失败时**保留本地缓存**，只把 offline 亮起来，不再清空成空列表。
    LaunchedEffect(tab, isPlaza) {
        if (!isPlaza) return@LaunchedEffect
        if (tab == 0) {
            val r = withContext(Dispatchers.IO) { runCatching { Api.personasChecked() } }
            val res = r.getOrNull()
            if (res != null && res.ok) {
                offline = false
                err = ""
                list = res.items
                // 还没看过表情 tab 时 packs 是 null —— 用缓存里的表情，别抹掉已缓存的表情
                val keepPacks = packs ?: cached.packs
                val sig = com.aevis.android.core.PlazaCache.signature(res.items, keepPacks)
                if (sig != cacheSig) {
                    cacheSig = sig
                    withContext(Dispatchers.IO) {
                        com.aevis.android.core.PlazaCache.save(
                            ctx,
                            com.aevis.android.core.PlazaCache.Payload(
                                personas = res.items, packs = keepPacks,
                                signature = sig, checkedAt = System.currentTimeMillis()
                            )
                        )
                    }
                }
            } else if (list == null) {
                // 没缓存又没有网：才显示错误；有缓存就仅提示 offline
                err = r.exceptionOrNull()?.message?.ifEmpty { null } ?: tr("连不上服务器，显示本地缓存")
            } else {
                offline = true
            }
        }
        if (tab == 1) {
            val r = withContext(Dispatchers.IO) { runCatching { Api.emojiPacksChecked() } }
            val res = r.getOrNull()
            if (res != null && res.ok) {
                offline = false
                packs = res.items
                // 只先看了表情 tab 时 list 还是 null —— 用缓存里的人设，别把已缓存的人设抹成空
                val keepPersons = list ?: cached.personas
                val sig = com.aevis.android.core.PlazaCache.signature(keepPersons, res.items)
                if (sig != cacheSig) {
                    cacheSig = sig
                    withContext(Dispatchers.IO) {
                        com.aevis.android.core.PlazaCache.save(
                            ctx,
                            com.aevis.android.core.PlazaCache.Payload(
                                personas = keepPersons, packs = res.items,
                                signature = sig, checkedAt = System.currentTimeMillis()
                            )
                        )
                    }
                }
            } else if (packs == null) {
                offline = true
            } else {
                offline = true
            }
        }
    }

    PageScaffold(title, onBack) {
        // ---------- 余额（2026-11-29：按 iOS ShopView 的玻璃余额卡重做）----------
        if (!isPlaza) {
            V2Card(
                Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
            ) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Column(Modifier.weight(1f)) {
                        Text(tr("当前余额"), fontSize = 12.sp, color = ink.copy(alpha = 0.45f))
                        Spacer(Modifier.height(4.dp))
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(
                                if (points >= 0) "$points" else "—",
                                fontSize = 26.sp, fontWeight = FontWeight.Bold,
                                // 2026-11-24：墨点夜间配色用语义色，不再写死浅色紫
                                color = pointAccentColor(), letterSpacing = (-1).sp
                            )
                            Spacer(Modifier.width(5.dp))
                            Text(
                                tr("墨点"), fontSize = 12.sp,
                                color = ink.copy(alpha = 0.42f),
                                modifier = Modifier.padding(bottom = 5.dp)
                            )
                        }
                    }
                    Text(
                        tr("1 元 = 100 墨点"), fontSize = 11.sp,
                        color = ink.copy(alpha = 0.35f)
                    )
                }
            }
        }

        // ---------- 连不上服务器：用本地缓存时明确告诉用户（2026-11-24）----------
        if (isPlaza && offline) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 2.dp)
                    .clip(squircle(10.dp))
                    .background(V2.alert.copy(alpha = 0.12f))
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    tr("连不上服务器，正在显示本地缓存"),
                    fontSize = V2.micro, color = V2.alert
                )
            }
            Spacer(Modifier.height(6.dp))
        }

        // ---------- 分段（2026-11-16 换成公共的 SegmentedTabs：有滑动指示块 + 内容过渡）----------
        SegmentedTabs(tabs = tabNames, selected = tab, onSelect = { tab = it })

        Spacer(Modifier.height(10.dp))

        // 2026-11-16 修布局（用户报「直接全屏了，会员什么都看不到」）：
        //   ① 内容区自己吃 `weight(1f)`，撑满标题下面的剩余高度；
        //   ② **滚动放进每个分支里面** —— 以前是外层 `Column(fillMaxSize + verticalScroll)`
        //      套 AnimatedContent，子内容在"无界高度"下测量，整页被顶出屏幕；
        //   ③ AnimatedContent 用 `SizeTransform(clip = false)`，切换时不被裁切。
        Box(Modifier.weight(1f).fillMaxWidth()) {
            SegmentedContent(selected = tab) { seg ->
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            if (isPlaza) {
                if (seg == 0) {
                    // ---------- 广场 · 人设 ----------
                    // 2026-11-24「添加不了」：以前广场只有"下载别人"，没有"创建自己的"。
                    // 顶部常驻一张「创建人设」卡，点进去走 personanew（本地创建 + 可选投稿广场）。
                    V2Card(
                        Modifier.padding(horizontal = V2.gutter, vertical = 2.dp),
                        pad = 14.dp
                    ) {
                        Row(
                            Modifier.fillMaxWidth().tapable { onCreatePersona() },
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Box(
                                Modifier.size(40.dp).clip(squircle(13.dp))
                                    .background(V2.accent.copy(alpha = 0.14f)),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    painterResource(R.drawable.ic_row_create), null,
                                    tint = V2.accent, modifier = Modifier.size(20.dp)
                                )
                            }
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    tr("创建我的人设"), fontSize = V2.sub,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Spacer(Modifier.height(2.dp))
                                Text(
                                    tr("名字、标签、头像、设定自己写，创建后本地可见"),
                                    fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
                                )
                            }
                            Icon(
                                painterResource(R.drawable.ic_chevron_right), null,
                                tint = ink.copy(alpha = 0.3f), modifier = Modifier.size(16.dp)
                            )
                        }
                    }
                    Spacer(Modifier.height(8.dp))

                    val items = list
                    when {
                        items == null -> Box(
                            Modifier.fillMaxWidth().padding(vertical = 60.dp),
                            contentAlignment = Alignment.Center
                        ) { Text(tr("正在加载…"), fontSize = V2.tiny,
                                color = ink.copy(alpha = 0.45f)) }

                        items.isEmpty() -> Box(
                            Modifier.fillMaxWidth().padding(vertical = 60.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            // 措辞要让人看出这是**公共广场**（不是"我的人设"）
                            Text(
                                err.ifEmpty { tr("公共广场上还没有人设") },
                                fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)
                            )
                        }

                        else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                            items.forEachIndexed { i, p ->
                                if (i > 0) RowDividerPublic()
                                // 首屏错峰淡入（2026-11-16）：key 用人设 id，滚动/刷新不重播
                                EnterOnce(p.id, i) {
                                    PersonaCardRow(p) { onOpenPersona(p.id) }
                                }
                            }
                        }
                    }
                } else {
                    // ---------- 广场 · 表情包 ----------
                    val ps = packs
                    when {
                        ps == null -> Box(
                            Modifier.fillMaxWidth().padding(vertical = 60.dp),
                            contentAlignment = Alignment.Center
                        ) { Text(tr("正在加载…"), fontSize = V2.tiny,
                                color = ink.copy(alpha = 0.45f)) }

                        ps.isEmpty() -> Box(
                            Modifier.fillMaxWidth().padding(vertical = 60.dp),
                            contentAlignment = Alignment.Center
                        ) { Text(tr("暂时没有表情包"), fontSize = V2.tiny,
                                color = ink.copy(alpha = 0.45f)) }

                        else -> EmojiGallery(ps, onTap = { preview = it })
                    }
                }
            } else {
                when (seg) {
                    // ---------- 商城 · 会员（2026-11-24 服务端驱动）----------
                    0 -> {
                        // 档位数量 / 价格 / 权益全读 /v1/shop/products，客户端不写死。
                        // 2026-11-25 线上只有一档会员 p_x（服务端 1990 分 = ¥19.9/月），
                        // 此前写死的 14.9 / 21.9 两档已删除；语音分钟权益已下线。
                        val memberProducts = products.filter {
                            it.kind == "member" && it.priceCents > 0
                        }
                        if (memberProducts.isEmpty()) {
                            Text(
                                tr("套餐加载中或暂不可用"),
                                fontSize = V2.tiny, color = ink.copy(alpha = 0.45f),
                                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 30.dp)
                            )
                        } else {
                            memberProducts.forEachIndexed { pi, p ->
                                if (pi > 0) Spacer(Modifier.height(14.dp))
                                val cents = p.priceCents / 100.0
                                val orig = if (p.listPriceCents > 0) p.listPriceCents / 100.0
                                           else (cents / 0.9).let { k ->
                                               Math.ceil(k * 10) / 10.0 - 0.1
                                           }
                                MemberCard(
                                    tier = p.label.ifBlank { tr("月卡") },
                                    origPrice = "¥%.1f".format(java.util.Locale.US, orig),
                                    price = "¥%.1f".format(java.util.Locale.US, cents),
                                    days = tr("/ %d 天", p.days),
                                    weeklyPoints = p.weekTotal,
                                    // 服务端 benefits[] 优先；缺字段时用产品口径占位（语音分钟已下线，不再列）
                                    benefits = p.benefits.ifEmpty {
                                        listOf(tr("开通立得 300 墨点"), tr("本周用量一次回满"),
                                            tr("每天签到翻倍"))
                                    },
                                    bestValue = pi == memberProducts.lastIndex && memberProducts.size > 1,
                                    onBuy = { buyShopProduct(p) }
                                )
                            }
                        }
                    }

                    // ---------- 商城 · 额度（2026-11-27 新增，聊天额度包）----------
                    1 -> QuotaSection(
                        serverProducts = products.filter { it.kind == "quota" },
                        onBuy = { buyShopProduct(it) }
                    )

                    // ---------- 商城 · 墨点（真能买）----------
                    2 -> PointPacks()

                    // ---------- 商城 · 按次（2026-11-24，对标 iOS ShopView）----------
                    3 -> PerCallSection(products.filter { it.kind == "uses" })

                    // ---------- 商城 · 音色包（还没接，禁用）----------
                    else -> {
                        V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                            listOf(
                                Triple("voice_10", "10 元", "1 万字"),
                                Triple("voice_30", "30 元", "3 万字"),
                                Triple("voice_70", "70 元", "7 万字")
                            ).forEachIndexed { i, (_, price, amount) ->
                                if (i > 0) Box(
                                    Modifier.fillMaxWidth().height(0.5.dp)
                                        .background(ink.copy(alpha = 0.07f))
                                )
                                Row(
                                    Modifier.fillMaxWidth()
                                        .padding(horizontal = V2.gutter, vertical = 14.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column(Modifier.weight(1f)) {
                                        Text(
                                            "$price · $amount", fontSize = V2.body,
                                            fontWeight = FontWeight.Medium,
                                            color = ink.copy(alpha = 0.55f)
                                        )
                                        Spacer(Modifier.height(2.dp))
                                        Text(
                                            tr("音色包"), fontSize = 11.5.sp,
                                            color = ink.copy(alpha = 0.35f)
                                        )
                                    }
                                    // 禁用态：**不给 tapable** —— 点了没反应比点了弹"敬请期待"更诚实
                                    Text(
                                        tr("即将开放"), fontSize = 12.sp,
                                        color = ink.copy(alpha = 0.38f),
                                        modifier = Modifier.clip(squircle(9.dp))
                                            .background(ink.copy(alpha = 0.05f))
                                            .padding(horizontal = 11.dp, vertical = 5.dp)
                                    )
                                }
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            tr("正在接入 TTS 计费。"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.4f),
                            modifier = Modifier.padding(horizontal = V2.gutter)
                        )
                    }

                }
            }
                    Spacer(Modifier.height(30.dp))
                }   // Column（每个分支自己的滚动容器）
            }       // SegmentedContent
        }           // Box(weight(1f))
    }

    // 广场里点表情 → 预览（跟表情包页共用同一个 sheet）
    val pv = preview
    if (pv != null) {
        EmojiPreviewSheet(url = pv, onDismiss = { preview = null })
    }

    // 商城下单弹层（会员 / 额度共用，和充值页同一个 PayDialog）
    val sp = shopPay
    if (sp != null) {
        PayDialog(
            info = sp,
            onClose = { shopPay = null },
            onPaid = { qty ->
                shopPay = null
                Toast.makeText(ctx, "已到账 $qty", Toast.LENGTH_LONG).show()
                com.aevis.android.core.ChatPrefs.bumpUi()
            }
        )
    }
}

/**
 * 会员卡（2026-11-16 重做）。
 *
 * 用户：「会员这个你可以重新改一下」—— 上一版就一行「15 元 · 30 天会员 + 1200 点额度」，
 * 信息太薄，看不出买的是什么。现在按商品卡排：
 *   角标（月卡 / 更划算）→ 大字价格 + 周期 → 三条权益（带对勾）→ 通栏按钮 → 灰字说明。
 *
 * 两张卡只差价格/额度/角标，所以参数化，不写两遍。
 * 「立即开通」走 `payOrder`（服务端一次性收银台链接），SKU 由调用方传，别在这里写死。
 */
@Composable
private fun MemberCard(
    tier: String,           // 档位短名（服务端 label，兜"月卡"）
    origPrice: String,      // 划线原价（服务端 list_price_cents / 现价推算）
    price: String,          // 现价（服务端 price_cents，如 ¥19.9）
    days: String,           // "/ 30 天"
    weeklyPoints: Int,      // 每周刷新的额度
    benefits: List<String>, // 服务端下发权益文案；空用占位
    bestValue: Boolean,     // 右上「更划算」
    onBuy: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    V2Card(Modifier.padding(horizontal = V2.gutter)) {
        // 角标行：档位名（X 用量 / XL 用量）+ 更划算
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                tier, fontSize = 10.sp, color = V2.accent,
                modifier = Modifier.clip(squircle(6.dp))
                    .background(V2.accent.copy(alpha = 0.13f))
                    .padding(horizontal = 7.dp, vertical = 2.dp)
            )
            Spacer(Modifier.weight(1f))
            if (bestValue) {
                Text(
                    tr("更划算"), fontSize = 10.sp, color = V2.accent,
                    modifier = Modifier.clip(squircle(6.dp))
                        .background(V2.accent.copy(alpha = 0.13f))
                        .padding(horizontal = 7.dp, vertical = 2.dp)
                )
            }
        }
        Spacer(Modifier.height(10.dp))

        // 价格：划线原价 + 现价（2026-11-24「所有价格标面」）
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                origPrice, fontSize = 12.sp, color = ink.copy(alpha = 0.38f),
                textDecoration = androidx.compose.ui.text.style.TextDecoration.LineThrough,
                modifier = Modifier.padding(bottom = 6.dp)
            )
            Spacer(Modifier.width(7.dp))
            Text(
                price, fontSize = 30.sp, fontWeight = FontWeight.Bold,
                color = V2.accent, letterSpacing = (-1).sp
            )
            Spacer(Modifier.width(5.dp))
            Text(
                days, fontSize = 12.sp, color = ink.copy(alpha = 0.45f),
                modifier = Modifier.padding(bottom = 6.dp)
            )
        }
        Spacer(Modifier.height(6.dp))
        // 用量数字翻动（对标 iOS AnimatedNumber：切档位数字滚一下）
        AnimatedNumber(
            value = weeklyPoints,
            style = TextStyle(fontSize = V2.body, fontWeight = FontWeight.SemiBold),
            color = ink,
            suffix = tr(" 点 / 周")
        )
        Spacer(Modifier.height(8.dp))

        // 会员权益（服务端 benefits[] 下发；缺字段时显示占位文案）
        if (weeklyPoints > 0) {
            BenefitLine(tr("每周 %d 点额度，每周一 0 点刷新", weeklyPoints))
        }
        benefits.forEach { BenefitLine(it) }
        BenefitLine(tr("到期不自动续费"))

        Spacer(Modifier.height(14.dp))
        // 通栏按钮
        Box(
            Modifier.fillMaxWidth()
                .clip(squircle(14.dp))
                .background(V2.accent)
                .tapable { onBuy() }
                .padding(vertical = 12.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                tr("立即开通"), fontSize = V2.body, fontWeight = FontWeight.Medium,
                color = Color.White
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(
            // 旧文案「等额折成墨点」从按周发放这一刻起是错的，换成不累计的说明
            tr("额度按周发放，没用完不累计。"),
            fontSize = V2.micro, color = ink.copy(alpha = 0.4f)
        )
    }
}

/** 会员权益的一行：对勾 + 文案。*/
@Composable
private fun BenefitLine(text: String) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.padding(vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            painterResource(R.drawable.ic_login_check), null,
            tint = ink.copy(alpha = 0.7f), modifier = Modifier.size(14.dp)
        )
        Spacer(Modifier.width(7.dp))
        Text(text, fontSize = V2.tiny, color = ink.copy(alpha = 0.75f))
    }
}

/**
 * 聊天额度包（2026-11-27 新增）。
 *
 * 用户原话：「除了会员还有一个额度，XXL 那个……那个是聊天额度，会员是签到加每日赠送，
 * 每日签到加充值卡」——所以这里是**独立一栏**，不和会员混：
 *   · 一次性到账墨点，永久有效，不随会员到期清零
 *   · 不占每周额度，也不改变会员身份
 * 商品来自 `/v1/shop/products` 里 `kind=="quota"`；下单走 `/v1/shop/order`（与 iOS 同源）。
 */
@Composable
internal fun QuotaSection(
    serverProducts: List<Api.ShopProduct>,
    onBuy: (Api.ShopProduct) -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.padding(horizontal = V2.gutter)) {
        Text(
            tr("聊天额度包"), fontSize = V2.sub,
            fontWeight = FontWeight.SemiBold, color = ink
        )
        Spacer(Modifier.height(4.dp))
        Text(
            tr("一次到账聊天额度 · 不随周一清零 · 不占每周额度"),
            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
        )
        Spacer(Modifier.height(12.dp))

        if (serverProducts.isEmpty()) {
            Text(
                tr("额度包加载中或暂不可用"),
                fontSize = V2.tiny, color = ink.copy(alpha = 0.45f),
                modifier = Modifier.padding(vertical = 26.dp)
            )
        } else {
            serverProducts.forEachIndexed { i, p ->
                if (i > 0) Spacer(Modifier.height(14.dp))
                QuotaCard(
                    p = p,
                    bestValue = i == serverProducts.lastIndex && serverProducts.size > 1,
                    onBuy = { onBuy(p) }
                )
            }
        }

        Spacer(Modifier.height(14.dp))
        Text(
            tr("额度包只加聊天额度，不改变会员身份；开通会员请到「会员」。"),
            fontSize = V2.micro, color = ink.copy(alpha = 0.4f), lineHeight = 17.sp
        )
    }
}

/** 额度包卡片：价格 → 到账墨点（数字翻动）→ 权益 → 通栏按钮。*/
@Composable
private fun QuotaCard(p: Api.ShopProduct, bestValue: Boolean, onBuy: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    V2Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                p.label.ifBlank { tr("额度包") }, fontSize = 10.sp, color = V2.accent,
                modifier = Modifier.clip(squircle(6.dp))
                    .background(V2.accent.copy(alpha = 0.13f))
                    .padding(horizontal = 7.dp, vertical = 2.dp)
            )
            Spacer(Modifier.weight(1f))
            if (bestValue) {
                Text(
                    tr("更划算"), fontSize = 10.sp, color = V2.accent,
                    modifier = Modifier.clip(squircle(6.dp))
                        .background(V2.accent.copy(alpha = 0.13f))
                        .padding(horizontal = 7.dp, vertical = 2.dp)
                )
            }
        }
        Spacer(Modifier.height(10.dp))

        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                "¥%.1f".format(java.util.Locale.US, p.priceCents / 100.0),
                fontSize = 30.sp, fontWeight = FontWeight.Bold,
                color = V2.accent, letterSpacing = (-1).sp
            )
            Spacer(Modifier.width(5.dp))
            Text(
                tr("/ 一次"), fontSize = 12.sp, color = ink.copy(alpha = 0.45f),
                modifier = Modifier.padding(bottom = 6.dp)
            )
        }
        Spacer(Modifier.height(6.dp))
        // 2026-11-27 用户：「额度是百分比，按 token 来，和模型」。
        // 不再展示「N 点 / 约 N 条」，统一讲「万 token」——条数随模型浮动太大，会误导。
        AnimatedNumber(
            value = (if (p.tokensTotal > 0) p.tokensTotal else p.points * 4500) / 10000,
            style = TextStyle(fontSize = V2.body, fontWeight = FontWeight.SemiBold),
            color = ink,
            suffix = tr(" 万 token 额度")
        )
        Spacer(Modifier.height(2.dp))
        Text(
            tr("按实际 token 扣，模型越贵扣得越多"),
            fontSize = V2.micro, color = V2.accent
        )
        Spacer(Modifier.height(8.dp))
        p.benefits.forEach { BenefitLine(it) }

        Spacer(Modifier.height(14.dp))
        Box(
            Modifier.fillMaxWidth()
                .clip(squircle(14.dp))
                .background(V2.accent)
                .tapable { onBuy() }
                .padding(vertical = 12.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                tr("立即购买"), fontSize = V2.body, fontWeight = FontWeight.Medium,
                color = Color.White
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(
            tr("一次性到账，用完为止；不随会员到期清零。"),
            fontSize = V2.micro, color = ink.copy(alpha = 0.4f)
        )
    }
}

/**
 * 按次套餐（2026-11-24，对标 iOS ShopView tab「按次」）。
 *
 * 产品口径：DeepSeek 按次 1 元 = 50 次、2 元 = 100 次、**100 次起卖**；
 * 所有价格明面展示（原价 + 现价都写），另附 token 限量说明。
 * ⚠️ 后端目前没有按次商品 / 下单接口 —— 本段只做明示价格的 UI，
 *    购买入口灰着并写清"待后端补齐"，不假装能下单（等后端-shop 确认后再接）。
 */
@Composable
internal fun PerCallSection(serverProducts: List<Api.ShopProduct> = emptyList()) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    // 服务端下发优先（kind=uses：1 元=50 次 / 2 元=100 次，100 次起卖）；
    // 服务端没给时用产品口径兜底，价格仍明面展示，不写死购买。
    val packs = if (serverProducts.isNotEmpty()) {
        serverProducts.map { p ->
            val cents = p.priceCents / 100.0
            val usesLabel = if (p.uses > 0) "${p.uses} 次"
                            else if (p.usesPerYuan > 0) "${p.usesPerYuan} 次 / 元" else p.title
            Triple(p.id, "¥%.1f".format(java.util.Locale.US, cents), usesLabel)
        }
    } else {
        listOf(
            Triple("ds_use_100", "¥1.0", "100 次"),
            Triple("ds_use_200", "¥2.0", "200 次")
        )
    }
    Column(Modifier.padding(horizontal = V2.gutter)) {
        Text(tr("DeepSeek 按次"), fontSize = V2.sub, fontWeight = FontWeight.SemiBold, color = ink)
        Spacer(Modifier.height(4.dp))
        Text(
            tr("默认 100 次起卖 · 即用即扣，所有价格明面展示"),
            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
        )
        Spacer(Modifier.height(10.dp))

        V2Card(pad = 0.dp) {
            packs.forEachIndexed { i, (sku, price, times) ->
                if (i > 0) HorizontalDivider(
                    Modifier.padding(start = 78.dp), thickness = 0.5.dp,
                    color = ink.copy(alpha = 0.07f)
                )
                Row(
                    Modifier.fillMaxWidth()
                        .tapable { payOrder(ctx, scope, sku) }
                        .padding(horizontal = V2.gutter, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(times, fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tr("即用即扣 · 100 次起卖"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.4f)
                        )
                    }
                    Text(
                        price, fontSize = V2.sub, fontWeight = FontWeight.SemiBold,
                        color = pointAccentColor()
                    )
                }
            }
        }

        Spacer(Modifier.height(14.dp))
        V2Card {
            Text(tr("token 限量说明"), fontSize = V2.tiny, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(5.dp))
            Text(
                tr("每一轮对话最多计入 2000 token，超出部分按服务端实际口径另计；设置上限是为了防止次数包被少量高消耗对话吃穿。具体上限以服务端配置为准。"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.6f), lineHeight = 17.sp
            )
        }
        if (serverProducts.isEmpty()) {
            Spacer(Modifier.height(10.dp))
            Text(
                tr("按次商品正从服务端拉取；暂时按产品口径明价展示，下单以服务端返回为准。"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.45f),
                modifier = Modifier.clip(squircle(9.dp))
                    .background(ink.copy(alpha = 0.05f))
                    .padding(horizontal = 11.dp, vertical = 7.dp)
            )
        }
    }
}

/**
 * 广场列表一行（2026-11-16 加右侧「下载」）。
 *
 * 用户：「人设广场下载去哪了」—— 以前必须点进详情页才看得到「下载到本地」，
 * 列表上完全没有入口。现在行尾直接给一颗胶囊：
 *   · 未下载 → 主色「下载」，点了**同步落本地**（不等网络）+ 后台只给服务端加个计数
 *   · 已下载 → 灰底「已下载」，不可点
 *
 * 两个点击区不打架：整行的 `tapable` 挂在 Row 上，按钮是 Row 的最后一个子项、
 * 自己再套一个 `tapable` —— Compose 里子项先命中，点按钮不会顺带触发整行。
 */
@Composable
private fun PersonaCardRow(p: Api.Persona, onClick: () -> Unit = {}) {
    val ink = MaterialTheme.colorScheme.onSurface
    val scope = rememberCoroutineScope()
    // 有没有下载过（BUG-A）：先按 id 比，**再按同名兜底** ——
    // 以前只比 id，广场 id 和早期「下载到本地」存下的 id 不一致时就显示成「下载」，
    // 点一下又多出一条同名角色（用户截图里两个「沈砚之」就是这么来的）。
    var downloaded by remember(p.id, p.name) {
        mutableStateOf(
            LocalPersonaStore.has(p.id) ||
                LocalPersonaStore.all().any { it.name.trim() == p.name.trim() }
        )
    }
    Row(
        Modifier.fillMaxWidth().tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Avatar(p.avatar, p.name, 48.dp)
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.name, fontSize = V2.body, fontWeight = FontWeight.Medium, maxLines = 1)
                if (p.official) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "官方", fontSize = 9.5.sp, color = V2.accent,
                        modifier = Modifier.clip(squircle(5.dp))
                            .background(V2.accent.copy(alpha = 0.13f))
                            .padding(horizontal = 5.dp, vertical = 1.5.dp)
                    )
                }
            }
            if (p.tagline.isNotEmpty()) {
                Spacer(Modifier.height(2.dp))
                Text(p.tagline, fontSize = V2.tiny, maxLines = 2,
                    color = ink.copy(alpha = 0.45f))
            }
            // 2026-11-14 用户：「领养数删掉…其实并没有真正的人领养」→ 换成人设编号
            if (p.id.isNotEmpty()) {
                Spacer(Modifier.height(3.dp))
                Text("编号 ${p.id}", fontSize = V2.micro,
                    color = ink.copy(alpha = 0.32f), maxLines = 1)
            }
        }

        // ---- 「下载」胶囊 ----
        Spacer(Modifier.width(10.dp))
        Box(
            // 44dp = iOS 的最小可点高度，比行内文字高一点才戳得准。
            // 116：`heightIn(min)` + 上下 6dp —— 大字号下「已下载 / 下载」不会被裁。
            Modifier.heightIn(min = 44.dp)
                .clip(squircle(14.dp))
                .background(if (downloaded) ink.copy(alpha = 0.06f) else V2.accent)
                .tapable(enabled = !downloaded) {
                    // 本地立刻落盘：点完就该显示「已下载」，不该等网络回来才变色。
                    // BUG-A：**upsert** —— 已有的只更新字段，绝不新建第二条。
                    val exist = LocalPersonaStore.find(p.id)
                        ?: LocalPersonaStore.all().firstOrNull { it.name.trim() == p.name.trim() }
                    if (exist != null) {
                        LocalPersonaStore.update(
                            exist.id,
                            name = p.name,
                            avatar = p.avatar,
                            persona = if (p.tagline.isBlank()) exist.persona else p.tagline
                        )
                    } else {
                        LocalPersonaStore.save(
                            LocalPersonaStore.Item(
                                id = p.id,
                                name = p.name,
                                avatar = p.avatar,
                                persona = p.tagline,
                                style = "",
                                origin = "square",
                                updatedAt = 0L   // save() 内部会补成当前时间
                            )
                        )
                    }
                    downloaded = true
                    // 服务端那侧只做计数（+1），失败不影响本地这份
                    scope.launch(Dispatchers.IO) { runCatching { Api.adopt(p.id) } }
                }
                .padding(horizontal = 14.dp, vertical = 6.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                if (downloaded) tr("已下载") else tr("下载"),
                fontSize = V2.tiny, fontWeight = FontWeight.Medium, maxLines = 1,
                color = if (downloaded) ink.copy(alpha = 0.45f) else Color.White
            )
        }
    }
}

/** 分割线（`RowDivider` 是 private，跨文件用不了，这里给个同款）。*/
@Composable
private fun RowDividerPublic() {
    HorizontalDivider(
        Modifier.padding(start = 78.dp),
        thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
    )
}

// ------------------------------------------------------------------ 浏览器

/**
 * 内置浏览器（2026-11-14 第二版）。
 *
 * 用户：「浏览器你不应该跟那个一样吗？是输入网址的，默认用那个微软的搜索引擎」——
 * 第一版只是个全屏 WebView，没有地址栏，打开就是 aevis.lingyan.cyou，用户没法输网址。
 * 现在：顶部一条地址栏，默认首页是 Bing（cn.bing.com）；
 * 输入的东西像网址就直接去，不像就当关键词丢给 Bing 搜。
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun BrowserScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val HOME = "https://cn.bing.com"
    var addr by remember { mutableStateOf(HOME) }       // 地址栏里显示的文字
    var target by remember { mutableStateOf(HOME) }     // 真正要加载的地址
    var wv by remember { mutableStateOf<WebView?>(null) }
    var loading by remember { mutableStateOf(false) }

    fun go(raw: String) {
        val t = raw.trim()
        if (t.isEmpty()) return
        val looksUrl = t.startsWith("http://") || t.startsWith("https://") ||
            (t.contains(".") && !t.contains(" "))
        target = if (looksUrl) {
            if (t.startsWith("http")) t else "https://" + t
        } else {
            "https://cn.bing.com/search?q=" + java.net.URLEncoder.encode(t, "UTF-8")
        }
        addr = target
    }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // 地址栏（2026-11-16）：这页的顶栏中间是地址输入框，没法直接换 `SubPageHeader`，
        // 但左右留白和返回箭头的尺寸统一到同一套（18dp 箭头 + V2.gutter）
        Row(
            Modifier.fillMaxWidth()
                .padding(horizontal = V2.gutter, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(34.dp).clip(CircleShape).tapable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    painterResource(R.drawable.ic_row_chevron), null,
                    tint = ink.copy(alpha = 0.7f),
                    modifier = Modifier.size(18.dp).rotate(180f)
                )
            }
            Spacer(Modifier.width(6.dp))
            Box(
                Modifier.weight(1f).clip(squircle(12.dp))
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.055f))
                    .padding(horizontal = 12.dp, vertical = 9.dp)
            ) {
                BasicTextField(
                    value = addr,
                    onValueChange = { addr = it },
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(
                        fontSize = 14.sp, color = ink
                    ),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = androidx.compose.ui.text.input.KeyboardType.Uri,
                        imeAction = androidx.compose.ui.text.input.ImeAction.Go
                    ),
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                        onGo = { go(addr) }
                    ),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                tr("前往"), fontSize = 14.sp, fontWeight = FontWeight.Medium,
                color = V2.accent,
                modifier = Modifier
                    .clip(squircle(12.dp))
                    .background(V2.accent.copy(alpha = 0.12f))
                    .tapable { go(addr) }
                    .padding(horizontal = 13.dp, vertical = 9.dp)
            )
        }

        if (loading) {
            androidx.compose.material3.LinearProgressIndicator(
                Modifier.fillMaxWidth().height(2.dp),
                color = V2.accent,
                trackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
            )
        }

        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                WebView(ctx).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.useWideViewPort = true
                    settings.loadWithOverviewMode = true
                    settings.setSupportZoom(true)
                    settings.builtInZoomControls = true
                    settings.displayZoomControls = false
                    webViewClient = object : WebViewClient() {
                        override fun onPageStarted(v: WebView?, url: String?, fav: android.graphics.Bitmap?) {
                            loading = true
                            if (!url.isNullOrEmpty()) addr = url
                        }
                        override fun onPageFinished(v: WebView?, url: String?) {
                            loading = false
                        }
                    }
                    loadUrl(HOME)
                    wv = this
                }
            },
            update = { view ->
                // 只有地址真的变了才 load，否则每次重组都会重新加载页面
                if (view.url != target) view.loadUrl(target)
            }
        )
    }
}

// ------------------------------------------------------------------ 站内信

/** 站内信。`/v1/inbox/list`，用 `X-Account` 头。*/
@Composable
fun InboxScreen(onBack: () -> Unit) {
    var list by remember { mutableStateOf<List<Api.InboxItem>?>(null) }
    val ink = MaterialTheme.colorScheme.onSurface

    LaunchedEffect(Unit) {
        list = withContext(Dispatchers.IO) {
            runCatching { Api.inbox().first }.getOrElse { emptyList() }
        }
        // 打开就把「已读」上报、红点消失（2026-11-16，104）
        withContext(Dispatchers.IO) { runCatching { com.aevis.android.core.InboxBadge.clear() } }
    }

    PageScaffold("通知", onBack) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            val items = list
            when {
                items == null -> Box(
                    Modifier.fillMaxWidth().padding(vertical = 60.dp),
                    contentAlignment = Alignment.Center
                ) { Text(tr("正在加载…"), fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)) }

                items.isEmpty() -> Box(
                    Modifier.fillMaxWidth().padding(vertical = 60.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(tr("没有新消息"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(5.dp))
                        Text(tr("有公告会出现在这里"), fontSize = V2.tiny,
                            color = ink.copy(alpha = 0.42f))
                    }
                }

                else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                    items.forEachIndexed { i, m ->
                        if (i > 0) RowDividerPublic()
                        Column(Modifier.fillMaxWidth().padding(V2.gutter)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (!m.read) {
                                    Box(
                                        Modifier.size(6.dp).clip(CircleShape)
                                            .background(V2.alert)
                                    )
                                    Spacer(Modifier.width(6.dp))
                                }
                                Text(
                                    m.title.ifEmpty { "公告" },
                                    fontSize = V2.body, fontWeight = FontWeight.Medium,
                                    maxLines = 1, modifier = Modifier.weight(1f, false)
                                )
                            }
                            if (m.body.isNotEmpty()) {
                                Spacer(Modifier.height(4.dp))
                                Text(m.body, fontSize = V2.tiny,
                                    color = ink.copy(alpha = 0.5f), maxLines = 4)
                            }
                            if (m.createdAt.isNotEmpty()) {
                                Spacer(Modifier.height(5.dp))
                                Text(m.createdAt, fontSize = V2.micro,
                                    color = ink.copy(alpha = 0.3f))
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}

// ------------------------------------------------------------------ 关于

/**
 * 关于（2026-11-14 第二版）。
 *
 * 用户逐条点过：「关于里面这个路线是可以点击切换的」「还有核心版本账号」
 * 「还有一个检测更新」「关于里面的这个应用图标都没有切换到我们自己的那个」。
 * 第一版是个死页面：一个字母 A 当图标、线路是一串只读文字、没有任何操作。
 */
@Composable
fun AboutScreen(
    onBack: () -> Unit,
    onOpenChangelog: () -> Unit = {},
    onOpenServerStatus: () -> Unit = {}
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var line by remember { mutableStateOf(Api.lineName()) }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf("") }
    // 关于页里点「检查更新」查到的结果（有新版就弹同一个 UpdateDialog）
    var update by remember { mutableStateOf<Api.UpdateInfo?>(null) }

    PageScaffold("关于", onBack) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Column(
                Modifier.fillMaxWidth().padding(top = 26.dp, bottom = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // Logo（2026-11-16）：用户说「logo 也没有」——以前那块是自绘的字母 A。
                // 现在直接**用 App 的启动图标**（圆角裁切），哪怕图标是纯色块也不会是空白。
                Box(
                    Modifier.size(64.dp).clip(squircle(18.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center
                ) {
                    Image(
                        painterResource(R.mipmap.ic_launcher),
                        contentDescription = "Aevis",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize()
                    )
                }
                Spacer(Modifier.height(10.dp))
                Text("Aevis", fontSize = V2.title, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(3.dp))
                Text(
                    // 2026-11-16（112）：版本号改成 `1.1.02` 这种语义化格式，
                    // **不再拼 build 号**（用户明确要求）。versionCode 只做内部单调递增。
                    "v${BuildConfig.VERSION_NAME}",
                    fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)
                )
            }

            // ---------- 官方链接（2026-11-16 补齐：用户说「隐私政策也没有、官网打不开」）----------
                        // 更新日志（2026-11-16，104）：内容全在服务端，客户端不写死
            V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 5.dp), pad = 0.dp) {
                Row(
                    Modifier.fillMaxWidth().tapable { onOpenChangelog() }
                        .padding(horizontal = V2.gutter, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(tr("更新日志"), fontSize = V2.body)
                    Spacer(Modifier.weight(1f))
                    Text("›", fontSize = 18.sp, color = ink.copy(alpha = 0.3f))
                }
            }

V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                AboutLink("官网", "https://aevis.lingyan.cyou")
                RowDividerPublic()
                AboutLink("隐私政策", "https://aevis.lingyan.cyou/privacy")
                RowDividerPublic()
                AboutLink("服务条款", "https://aevis.lingyan.cyou/terms")
                RowDividerPublic()
                AboutRow(
                    "检查更新",
                    if (busy) "检查中…" else (msg.ifEmpty { "点一下检查" }),
                    onClick = {
                        if (!busy) {
                            busy = true
                            msg = ""
                            scope.launch {
                                val r = withContext(Dispatchers.IO) {
                                    runCatching { Api.checkUpdate() }.getOrNull()
                                }
                                busy = false
                                if (r == null) {
                                    msg = "检查失败，稍后再试"
                                } else if (r.update) {
                                    msg = "有新版本 ${r.latest}"
                                    update = r
                                } else {
                                    msg = "已是最新版本"
                                    android.widget.Toast.makeText(
                                        ctx, "已是最新版本", android.widget.Toast.LENGTH_SHORT
                                    ).show()
                                }
                            }
                        }
                    },
                    hint = "v${BuildConfig.VERSION_NAME}"
                )
            }

            Spacer(Modifier.height(16.dp))

            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                AboutRow("核心版本", runCatching { NativeCore.version() }.getOrDefault("—"))
                RowDividerPublic()
                AboutRow(
                    "接口线路", line,
                    onClick = { line = Api.switchLine() },
                    hint = "点一下切换"
                )
                RowDividerPublic()
                // 2026-11-25：线路状态 / 自动选择是基础入口，任何开关下都可达
                AboutRow("线路状态", tr("延迟与繁忙"), onClick = onOpenServerStatus)
                RowDividerPublic()
                AboutRow("账号", Api.email().ifEmpty { "未登录" })
            }

            Spacer(Modifier.height(16.dp))
            Text(
                tr("Aevis · 和你的 AI 伙伴"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.3f),
                textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(30.dp))
        }
    }

    // 有新版 → 同一个更新弹窗（跟冷启动那处共用一份实现）
    update?.let { u ->
        UpdateDialog(u) {
            com.aevis.android.core.ChatPrefs.markUpdateSkipped(u.latest)
            update = null
        }
    }
}

/** 关于页里的外链行：点了用系统浏览器打开（没有浏览器会 Toast，不崩）。*/
@Composable
private fun AboutLink(label: String, url: String) {
    val ctx = LocalContext.current
    AboutRow(label, url.removePrefix("https://"), onClick = { openUrl(ctx, url) })
}

@Composable
private fun AboutRow(
    k: String,
    v: String,
    onClick: (() -> Unit)? = null,
    hint: String? = null
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth()
            .then(if (onClick != null) Modifier.tapable { onClick() } else Modifier)
            .padding(horizontal = V2.gutter, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(tr(k), fontSize = V2.body)
            if (hint != null) {
                Spacer(Modifier.height(2.dp))
                Text(hint, fontSize = V2.micro, color = ink.copy(alpha = 0.35f))
            }
        }
        Spacer(Modifier.width(12.dp))
        Text(
            v, fontSize = V2.tiny,
            color = if (onClick != null) V2.accent else ink.copy(alpha = 0.45f),
            maxLines = 1, textAlign = TextAlign.End
        )
        if (onClick != null) {
            Spacer(Modifier.width(6.dp))
            Icon(
                painterResource(R.drawable.ic_row_chevron), null,
                tint = V2.accent.copy(alpha = 0.5f),
                modifier = Modifier.size(13.dp)
            )
        }
    }
}
// ------------------------------------------------------------------ 网易云

/**
 * 网易云音乐（2026-11-14）。
 *
 * 用户：「发现页把网易云接上」＋「播放页你也没做」。
 *
 * 搜索走网易明文接口（客户端直连），播放地址走我们后端 `/v1/music/url` 代取 ——
 * 客户端直连取地址会被风控（-110），后端带 `Cookie: os=ios` 才给。
 * 音频流本身是直连网易 CDN 的，不经过我们服务器。
 *
 * ⚠️ **还没有网易云账号登录**。iOS 那边走 weapi 那套（AES-CBC + RSA 加密），
 * 安卓要移植 `NeteaseCrypto`，这版没做 —— 所以「我喜欢的音乐 / 我的歌单」
 * 这些需要登录的页拿不到数据，界面上如实写清楚，不装作能用。
 */
@Composable
fun MusicScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var kw by remember { mutableStateOf("") }
    var list by remember { mutableStateOf<List<Api.Track>?>(null) }
    var loading by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }
    var current by remember { mutableStateOf<Api.Track?>(null) }
    var playing by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var full by remember { mutableStateOf(false) }   // 全屏播放页

    val scope = rememberCoroutineScope()
    val player = remember { android.media.MediaPlayer() }
    val ctx = LocalContext.current
    val notifPerm = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    DisposableEffect(Unit) {
        onDispose {
            runCatching { if (player.isPlaying) player.stop() }
            runCatching { player.release() }
            LiveUpdate.stop(ctx)
        }
    }

    /** 挂/更新状态栏那颗胶囊（Android 16 才有，低版本自动不发）。*/
    fun pushLive(t: Api.Track) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            runCatching { notifPerm.launch(Manifest.permission.POST_NOTIFICATIONS) }
            return
        }
        LiveUpdate.start(ctx, "正在播放", t.name, -1, R.drawable.ic_row_music)
    }

    fun play(t: Api.Track) {
        if (busy) return
        if (current?.id == t.id) {
            runCatching {
                if (player.isPlaying) {
                    player.pause(); playing = false
                    LiveUpdate.stop(ctx)
                } else {
                    player.start(); playing = true
                    pushLive(t)
                }
            }
            return
        }
        busy = true
        note = ""
        scope.launch {
            val url = withContext(Dispatchers.IO) {
                runCatching { Api.musicUrl(t.id) }.getOrNull()
            }
            if (url.isNullOrEmpty()) {
                note = "这首歌拿不到播放地址（可能没版权或要会员）"
                busy = false
                return@launch
            }
            runCatching {
                player.reset()
                player.setDataSource(url)
                player.setOnPreparedListener {
                    it.start()
                    playing = true
                    current = t
                    pushLive(t)
                }
                player.setOnCompletionListener { playing = false; LiveUpdate.stop(ctx) }
                player.setOnErrorListener { _, _, _ ->
                    note = "播放出错了，换一首试试"
                    playing = false
                    LiveUpdate.stop(ctx)
                    true
                }
                player.prepareAsync()
            }.onFailure { note = "播放器打不开：" + (it.message ?: "") }
            busy = false
        }
    }

    // ---------------- 全屏播放页 ----------------
    if (full) {
        val c = current
        if (c == null) {
            full = false
        } else {
            BackHandler { full = false }
            Column(
                Modifier.fillMaxSize()
                    .background(MaterialTheme.colorScheme.background)
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(horizontal = 26.dp)
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier.size(34.dp).clip(CircleShape).tapable { full = false },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            painterResource(R.drawable.ic_row_chevron), null,
                            tint = ink.copy(alpha = 0.7f),
                            modifier = Modifier.size(18.dp).rotate(90f)
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                    Text(c.album.ifEmpty { tr("正在播放") }, fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.45f), maxLines = 1)
                }

                Spacer(Modifier.weight(0.6f))
                // 大封面
                Box(
                    Modifier.fillMaxWidth().aspectRatio(1f)
                        .clip(squircle(24.dp))
                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f)),
                    contentAlignment = Alignment.Center
                ) {
                    Avatar(c.cover, c.name, 200.dp)
                }
                Spacer(Modifier.height(28.dp))
                Text(c.name, fontSize = 21.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 2, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(6.dp))
                Text(c.artist.ifEmpty { "—" }, fontSize = V2.sub,
                    color = ink.copy(alpha = 0.45f), maxLines = 1,
                    textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())

                Spacer(Modifier.weight(0.5f))

                // 进度
                val pos = runCatching {
                    if (player.isPlaying || playing) player.currentPosition else 0
                }.getOrDefault(0)
                val dur = runCatching { player.duration }.getOrDefault(0)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(fmtMs(pos), fontSize = V2.micro, color = ink.copy(alpha = 0.4f))
                    Text(fmtMs(dur), fontSize = V2.micro, color = ink.copy(alpha = 0.4f))
                }
                Spacer(Modifier.height(6.dp))
                androidx.compose.material3.LinearProgressIndicator(
                    progress = { if (dur > 0) pos.toFloat() / dur else 0f },
                    modifier = Modifier.fillMaxWidth().height(3.dp),
                    color = V2.accent,
                    trackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
                )

                Spacer(Modifier.height(26.dp))
                // 播放 / 暂停
                Box(
                    Modifier.align(Alignment.CenterHorizontally)
                        .size(64.dp).clip(CircleShape)
                        .background(V2.accent)
                        .tapable { play(c) },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        painterResource(
                            if (playing) R.drawable.ic_pause else R.drawable.ic_play
                        ),
                        contentDescription = if (playing) "暂停" else "播放",
                        tint = Color.White,
                        modifier = Modifier.size(22.dp)
                    )
                }
                Spacer(Modifier.height(40.dp))
            }
            return
        }
    }

    PageScaffold("网易云音乐", onBack) {
        Row(
            Modifier.padding(horizontal = V2.gutter, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.weight(1f).clip(squircle(12.dp))
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                BasicTextField(
                    value = kw,
                    onValueChange = { kw = it },
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(
                        fontSize = 14.5.sp, color = ink
                    ),
                    decorationBox = { inner ->
                        if (kw.isEmpty()) {
                            Text(tr("歌名、歌手、或者一句歌词"),
                                fontSize = 14.5.sp, color = ink.copy(alpha = 0.35f))
                        }
                        inner()
                    },
                    modifier = Modifier.fillMaxWidth()
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                if (loading) tr("找…") else tr("搜"),
                fontSize = 14.sp, fontWeight = FontWeight.Medium,
                color = V2.accent,
                modifier = Modifier
                    .clip(squircle(12.dp))
                    .background(V2.accent.copy(alpha = 0.12f))
                    .tapable {
                        if (!loading && kw.isNotBlank()) {
                            loading = true
                            note = ""
                            scope.launch {
                                val r = withContext(Dispatchers.IO) { Api.searchMusic(kw) }
                                list = r
                                if (r.isEmpty()) note = "没搜到，换个词试试"
                                loading = false
                            }
                        }
                    }
                    .padding(horizontal = 15.dp, vertical = 10.dp)
            )
        }

        // 登录态
        var ncName by remember { mutableStateOf(NeteaseAuth.nickName(ctx)) }
        var ncLogged by remember { mutableStateOf(NeteaseAuth.loggedIn(ctx)) }
        var showNcLogin by remember { mutableStateOf(false) }

        if (showNcLogin) {
            NeteaseLoginDialog(
                onClose = { showNcLogin = false },
                onDone = {
                    showNcLogin = false
                    ncLogged = NeteaseAuth.loggedIn(ctx)
                    ncName = NeteaseAuth.nickName(ctx)
                }
            )
        }

        Row(
            Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
                .fillMaxWidth()
                .clip(squircle(12.dp))
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.04f))
                .tapable { if (!ncLogged) showNcLogin = true }
                .padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                if (ncLogged) {
                    "已登录网易云" + (if (ncName.isNotEmpty()) "：$ncName" else "")
                } else {
                    "还没登录网易云 · 点这里登录（搜索和播放不需要登录）"
                },
                fontSize = V2.micro,
                color = if (ncLogged) V2.accent else ink.copy(alpha = 0.45f),
                modifier = Modifier.weight(1f)
            )
            if (!ncLogged) {
                Text(tr("登录"), fontSize = V2.micro, color = V2.accent)
            }
        }

        if (note.isNotEmpty()) {
            Text(
                note, fontSize = V2.tiny, color = V2.alert,
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
            )
        }

        Box(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                val items = list
                when {
                    items == null -> Box(
                        Modifier.fillMaxWidth().padding(vertical = 50.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(tr("搜一首歌开始听"), fontSize = V2.tiny,
                            color = ink.copy(alpha = 0.4f))
                    }

                    items.isEmpty() -> Box(
                        Modifier.fillMaxWidth().padding(vertical = 50.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(tr("没有结果"), fontSize = V2.tiny, color = ink.copy(alpha = 0.4f))
                    }

                    else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                        items.forEachIndexed { i, t ->
                            if (i > 0) RowDividerPublic()
                            Row(
                                Modifier.fillMaxWidth().tapable { play(t) }
                                    .padding(horizontal = V2.gutter, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Avatar(t.cover, t.name, 42.dp)
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        t.name, fontSize = V2.body, maxLines = 1,
                                        fontWeight = if (current?.id == t.id)
                                            FontWeight.SemiBold else FontWeight.Normal,
                                        color = if (current?.id == t.id) V2.accent else ink
                                    )
                                    if (t.artist.isNotEmpty()) {
                                        Spacer(Modifier.height(2.dp))
                                        Text(t.artist, fontSize = V2.tiny, maxLines = 1,
                                            color = ink.copy(alpha = 0.45f))
                                    }
                                }
                            }
                        }
                    }
                }
                Spacer(Modifier.height(if (current != null) 78.dp else 24.dp))
            }

            // 迷你播放条 —— 点一下进全屏
            val c = current
            if (c != null) {
                Row(
                    Modifier.align(Alignment.BottomCenter)
                        .padding(horizontal = V2.gutter, vertical = 10.dp)
                        .fillMaxWidth()
                        .clip(squircle(18.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        .border(
                            0.5.dp,
                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                            squircle(18.dp)
                        )
                        .tapable { full = true }
                        .padding(horizontal = 12.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Avatar(c.cover, c.name, 34.dp)
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(c.name, fontSize = V2.sub, maxLines = 1,
                            fontWeight = FontWeight.Medium)
                        Text(
                            if (busy) tr("正在取地址…") else if (playing) tr("正在播放")
                            else tr("已暂停"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.42f)
                        )
                    }
                    Box(
                        Modifier.size(34.dp).clip(CircleShape)
                            .background(V2.accent.copy(alpha = 0.14f))
                            .tapable { play(c) },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                        painterResource(
                            if (playing) R.drawable.ic_pause else R.drawable.ic_play
                        ),
                        contentDescription = if (playing) "暂停" else "播放",
                        tint = V2.accent,
                        modifier = Modifier.size(14.dp)
                    )
                    }
                }
            }
        }
    }
}

/** 大图（方形铺满 + 加密缓存），跟 `Avatar` 共用同一套缓存键。*/
@Composable
private fun BigImage(url: String, name: String, modifier: Modifier) {
    val appCtx = LocalContext.current.applicationContext
    var bmp by remember(url) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(url) {
        if (url.isEmpty()) return@LaunchedEffect
        // 2026-11-16：只有**真·本地路径**（`isLocalFile`）才读文件。
        // 这里原来判的是 `startsWith("/")` —— 服务端相对路径 `/v1/media/xxx.jpg`
        // 也以 / 开头，于是详情页大图被当成本地文件 decodeFile → null → 显示首字母。
        if (isLocalFile(url)) {
            bmp = withContext(Dispatchers.IO) {
                val b = runCatching {
                    android.graphics.BitmapFactory.decodeFile(localImagePath(url))
                }.getOrNull()
                if (b == null) android.util.Log.w("AevisAvatar", "local decode null: $url")
                b
            }
            return@LaunchedEffect
        }
        bmp = withContext(Dispatchers.IO) {
            val ck = "img:" + url
            val cached = com.aevis.android.core.SecureCache.getBytes(appCtx, ck)
            if (cached != null) {
                android.graphics.BitmapFactory.decodeByteArray(cached, 0, cached.size)
            } else {
                val b = runCatching { Api.fetchImage(url) }.getOrNull()
                if (b != null) {
                    runCatching {
                        val out = java.io.ByteArrayOutputStream()
                        b.compress(android.graphics.Bitmap.CompressFormat.JPEG, 88, out)
                        com.aevis.android.core.SecureCache.putBytes(appCtx, ck, out.toByteArray())
                    }
                }
                b
            }
        }
    }
    val f = bmp
    if (f != null) {
        Image(
            bitmap = f.asImageBitmap(), contentDescription = name,
            contentScale = ContentScale.Crop, modifier = modifier
        )
    } else {
        Box(modifier, contentAlignment = Alignment.Center) {
            Text(
                name.take(1), fontSize = 64.sp,
                color = V2.accent.copy(alpha = 0.5f)
            )
        }
    }
}

/** 毫秒 → m:ss */
private fun fmtMs(ms: Int): String {
    if (ms <= 0) return "0:00"
    val s = ms / 1000
    return "%d:%02d".format(s / 60, s % 60)
}
// ------------------------------------------------------------------ 人设详情

/**
 * 人设详情（2026-11-14，2026-11-16 改成「广场只浏览 / 下载才进我的」）。
 *
 * 用户：「人设点进去应该是有个大图展示的…还能添加到联系人里面」，
 * 后面又把流程定死：**广场只用来浏览**，看到喜欢的点「下载到本地」，
 * 下载下来的才进「我的 / 聊天」，之后还能改（头像、性格、说话风格）。
 *
 * 所以这颗底部按钮只有两种状态：
 *   · 没下载 → 「下载到本地」（落到 `LocalPersonaStore`，服务端只 +1 计数）
 *   · 下载过 → 「开始聊天」（进对话，不再重复下载）
 *
 * ⚠️ 领养关系始终只记在本地（后端 `/psquare/adopt` 只加计数，没有关系表）。
 */
@Composable
fun PersonaDetailScreen(
    pid: String,
    onBack: () -> Unit,
    onStartChat: (String) -> Unit = {},
    onEdit: (String) -> Unit = {}
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val scope = rememberCoroutineScope()
    var p by remember(pid) { mutableStateOf<Api.Persona?>(null) }
    var busy by remember(pid) { mutableStateOf(false) }
    // 「下载过没有」= 本地库里有没有这一条。
    // 以前判断的是 `Api.isAdopted`（老那套领养记录），跟用户嘴里的「下载」不是一回事。
    var downloaded by remember(pid) { mutableStateOf(LocalPersonaStore.has(pid)) }
    // 说话风格只在本地有（服务端没这个字段），单独拿出来，避免在组合里反复读盘
    var localStyle by remember(pid) { mutableStateOf("") }

    LaunchedEffect(pid) {
        p = withContext(Dispatchers.IO) {
            // 本地这份优先：下载过的角色，用户改过的名字/头像/性格要立刻反映在详情页。
            // 没下载过（从广场点进来）就按老路子查广场列表 —— 一次网络就能命中，
            // `merged()` 只留作兜底（「我在服务端发布的、但本地还没下载」这种）。
            PersonaLib.localOf(pid)?.let { PersonaLib.toPersona(it) }
                ?: runCatching { Api.personas() }.getOrNull()?.firstOrNull { it.id == pid }
                ?: PersonaLib.localList().firstOrNull { it.id == pid }
        }
        localStyle = withContext(Dispatchers.IO) { PersonaLib.styleText(pid) }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // 顶栏：换成公共的 `SubPageHeader`（2026-11-16「视觉统一」的第一步）
        SubPageHeader(title = "人设详情", onBack = onBack)

        val cur = p
        if (cur == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(tr("正在加载…"), fontSize = V2.tiny, color = ink.copy(alpha = 0.4f))
            }
            return
        }

        Box(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                // 大图：优先 cover，没有就用头像放大
                // 大图：**方形铺满**（圆角），不是圆形 —— 圆形会把画像的头和背景裁掉一半
                Box(
                    Modifier.padding(horizontal = V2.gutter).fillMaxWidth()
                        .aspectRatio(0.78f)
                        .clip(squircle(24.dp))
                        .background(V2.accent.copy(alpha = 0.10f)),
                    contentAlignment = Alignment.Center
                ) {
                    BigImage(cur.avatar, cur.name, Modifier.fillMaxSize())
                }

                Spacer(Modifier.height(16.dp))
                Column(Modifier.padding(horizontal = V2.gutter)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(cur.name, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
                        if (cur.official) {
                            Spacer(Modifier.width(8.dp))
                            Text(
                                tr("官方"), fontSize = 10.sp, color = V2.accent,
                                modifier = Modifier.clip(squircle(6.dp))
                                    .background(V2.accent.copy(alpha = 0.13f))
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                            )
                        }
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        tr("编号 %s", cur.id), fontSize = V2.micro,
                        color = ink.copy(alpha = 0.4f)
                    )
                    if (cur.tagline.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        Text(cur.tagline, fontSize = V2.body, color = ink.copy(alpha = 0.75f))
                    }
                }

                Spacer(Modifier.height(20.dp))
                V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    if (cur.relation.isNotEmpty()) {
                        InfoLine("关系", relationCn(cur.relation))
                        Spacer(Modifier.height(10.dp))
                    }
                    InfoLine("性格", cur.tagline.ifEmpty { "—" })
                    // 说话风格是本地的二改内容，广场上本来没有这一项 ——
                    // 有才显示，没有就不要摆一个空的「—」出来占位
                    if (localStyle.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        InfoLine("说话风格", localStyle)
                    }
                }

                // 「编辑这个角色」只给下载过的。
                // 广场上没下载的角色没有本地副本，点进去也没有能改的东西 ——
                // 后端没有「改别人发布的角色」这条通道，硬给入口就是骗人。
                if (downloaded) {
                    Spacer(Modifier.height(12.dp))
                    Row(
                        Modifier.padding(horizontal = V2.gutter).fillMaxWidth()
                            .clip(squircle(V2.cardRadius))
                            .background(MaterialTheme.colorScheme.surface)
                            .border(
                                0.5.dp,
                                MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                                squircle(V2.cardRadius)
                            )
                            .tapable { onEdit(cur.id) }
                            .padding(horizontal = V2.gutter, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            tr("编辑这个角色"), fontSize = V2.body,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f)
                        )
                        Icon(
                            painterResource(R.drawable.ic_row_chevron), null,
                            tint = ink.copy(alpha = 0.28f),
                            modifier = Modifier.size(14.dp)
                        )
                    }
                }

                Spacer(Modifier.height(110.dp))
            }

            // 底部主按钮：**「下载到本地」**（2026-11-16）
            //
            // 用户把流程定死了：广场只浏览 → 点下载 → 才进「我的 / 聊天」。
            // 所以不再是以前「领养 + 已在聊天列表里了」那套自造文案，就两种状态：
            //   没下载 → 「下载到本地」（落本地库，服务端只做计数）
            //   下载过 → 「开始聊天」（进对话，不再重复下载）
            Column(
                Modifier.align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = V2.gutter, vertical = 14.dp)
            ) {
                Row(
                    Modifier.fillMaxWidth()
                        .clip(squircle(16.dp))
                        .background(V2.accent)
                        .tapable {
                            if (busy) return@tapable
                            if (downloaded) { onStartChat(cur.id); return@tapable }
                            busy = true
                            // 本地**立刻**落盘：用户点完就该能在「聊天」里看到，
                            // 不该等网络。服务端那颗计数（adopt）失败也不影响本地这份。
                            LocalPersonaStore.save(
                                LocalPersonaStore.Item(
                                    id = cur.id,
                                    name = cur.name,
                                    avatar = cur.avatar,
                                    persona = cur.tagline,
                                    style = "",
                                    origin = "square",
                                    updatedAt = 0L   // save() 内部会补成当前时间
                                )
                            )
                            downloaded = true
                            busy = false
                            scope.launch {
                                withContext(Dispatchers.IO) {
                                    runCatching { Api.adopt(cur.id) }
                                }
                            }
                        }
                        .padding(vertical = 15.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center
                ) {
                    Text(
                        when {
                            busy -> tr("正在下载…")
                            downloaded -> tr("开始聊天")
                            else -> tr("下载到本地")
                        },
                        fontSize = 16.sp, fontWeight = FontWeight.Medium,
                        color = Color.White
                    )
                }
                // 下载完的那一句提示 —— 让用户知道这事**已经成了**，
                // 而不是盯着按钮猜「我刚才点的是下载还是开始聊天」
                if (downloaded) {
                    Spacer(Modifier.height(7.dp))
                    Text(
                        tr("已加入我的角色"),
                        fontSize = V2.micro, color = ink.copy(alpha = 0.45f),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        }
    }
}

@Composable
private fun InfoLine(k: String, v: String) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column {
        Text(tr(k), fontSize = V2.micro, color = ink.copy(alpha = 0.4f))
        Spacer(Modifier.height(3.dp))
        Text(v, fontSize = V2.body)
    }
}

/** 后端存的是英文 relation，界面上给中文。*/
private fun relationCn(r: String): String = when (r) {
    "lover" -> "恋人"
    "friend" -> "朋友"
    "family" -> "家人"
    else -> r
}
// ------------------------------------------------------------------ 账号

/**
 * 账号与安全（2026-11-14）。
 *
 * 用户：「点击不能去看的这个账号页之类的」—— 「我」页那一行以前点了没反应。
 * 这页放：身份（昵称/邮箱/UID/会员）、登录设备（能踢）、退出登录。
 */
@Composable

/**
 * 会员等级转人话（2026-11-15）。
 *
 * 用户：「会员那里你再用的是英文，你用中文啊…很多东西不要用内部符号，要用中文代表这个意思」。
 * 服务端给的是 `free` / `monthly` / `yearly` 这种内部枚举，直接显示出去很难看。
 */
private fun membershipLabel(raw: String?): String {
    val v = (raw ?: "").trim().lowercase()
    return when {
        v.isEmpty() || v == "free" || v == "none" || v == "basic" || v == "0" -> "普通用户"
        v.startsWith("month") || v == "m" -> "月卡会员"
        v.startsWith("year") || v == "y" || v == "annual" -> "年卡会员"
        v.contains("forever") || v.contains("life") || v.contains("permanent") -> "永久会员"
        v == "pro" || v == "premium" || v == "vip" -> "会员"
        // 认不出来就原样显示，别硬翻成错的
        else -> raw ?: "普通用户"
    }
}

@Composable
fun AccountScreen(onBack: () -> Unit, onSignOut: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val scope = rememberCoroutineScope()
    var me by remember { mutableStateOf<Api.MeInfo?>(Api.cachedMe()) }
    var devices by remember { mutableStateOf<List<Api.Device>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }

    fun load() {
        scope.launch {
            val d = withContext(Dispatchers.IO) {
                runCatching { Api.sessions() }.getOrElse { emptyList() }
            }
            devices = d
            me = withContext(Dispatchers.IO) {
                runCatching { Api.me() }.getOrNull()?.also { runCatching { Api.saveMe(it) } }
            } ?: me
        }
    }

    LaunchedEffect(Unit) { load() }
    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // 顶栏（2026-11-16）：换成公共 `SubPageHeader`
        SubPageHeader(title = "账号与安全", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            // 名片
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.padding(horizontal = V2.gutter, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val name = me?.nickname?.takeIf { it.isNotBlank() }
                        ?: Api.email().substringBefore("@").ifEmpty { "A" }
                    // 175：头像**真入口** —— 点击选图 → AvatarStore.import → bumpUi 立即生效
                    MyAvatarPicker(
                        url = com.aevis.android.core.AvatarStore.displayOf("me", me?.avatar),
                        name = name
                    )
                    Spacer(Modifier.width(13.dp))
                    Column(Modifier.weight(1f)) {
                        Text(name, fontSize = V2.title, fontWeight = FontWeight.SemiBold,
                            maxLines = 1)
                        Spacer(Modifier.height(3.dp))
                        Text(Api.email().ifEmpty { tr("未登录") },
                            fontSize = V2.tiny, color = ink.copy(alpha = 0.45f),
                            maxLines = 1)
                    }
                }
                RowDividerPublic()
                AboutRow("UID", Api.uid().ifEmpty { "—" })
                RowDividerPublic()
                AboutRow("会员", membershipLabel(me?.membership))
            }

            // 登录设备
            Spacer(Modifier.height(18.dp))
            Text(
                tr("登录设备"),
                fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(start = V2.gutter, bottom = 8.dp)
            )
            val ds = devices
            when {
                ds == null -> V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Text(tr("正在加载…"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.4f),
                        modifier = Modifier.padding(vertical = 14.dp))
                }

                ds.isEmpty() -> V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Text(tr("还没有登录记录"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.4f),
                        modifier = Modifier.padding(vertical = 14.dp))
                }

                else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                    ds.forEachIndexed { i, d ->
                        if (i > 0) RowDividerPublic()
                        Row(
                            Modifier.fillMaxWidth()
                                .padding(horizontal = V2.gutter, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        d.device.ifEmpty { d.ip.ifEmpty { "—" } },
                                        fontSize = V2.body, maxLines = 1,
                                        fontWeight = FontWeight.Medium
                                    )
                                    if (d.current) {
                                        Spacer(Modifier.width(6.dp))
                                        Text(
                                            tr("当前设备"), fontSize = 9.5.sp,
                                            color = V2.accent,
                                            modifier = Modifier.clip(squircle(5.dp))
                                                .background(V2.accent.copy(alpha = 0.13f))
                                                .padding(horizontal = 5.dp, vertical = 1.5.dp)
                                        )
                                    }
                                }
                                Spacer(Modifier.height(2.dp))
                                Text(
                                    listOf(d.ip, d.createdAt).filter { it.isNotEmpty() }
                                        .joinToString(" · "),
                                    fontSize = V2.micro, color = ink.copy(alpha = 0.4f),
                                    maxLines = 1
                                )
                            }
                            if (!d.current) {
                                Text(
                                    tr("下线"), fontSize = V2.tiny, color = V2.alert,
                                    modifier = Modifier
                                        .clip(squircle(10.dp))
                                        .background(V2.alert.copy(alpha = 0.10f))
                                        .tapable {
                                            if (!busy) {
                                                busy = true
                                                scope.launch {
                                                    withContext(Dispatchers.IO) {
                                                        runCatching { Api.revokeSession(d.token) }
                                                    }
                                                    busy = false
                                                    load()
                                                }
                                            }
                                        }
                                        .padding(horizontal = 12.dp, vertical = 6.dp)
                                )
                            }
                        }
                    }
                }
            }

            if (note.isNotEmpty()) {
                Text(
                    note, fontSize = V2.tiny, color = V2.alert,
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
                )
            }

            Spacer(Modifier.height(18.dp))
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.fillMaxWidth().tapable { Api.signOut(); onSignOut() }
                        .padding(horizontal = V2.gutter, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(tr("退出登录"), fontSize = V2.body, color = V2.alert)
                }
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}
// ------------------------------------------------------------------ 网易云登录

/**
 * 网易云登录（2026-11-15 第三版，对齐 iOS）。
 *
 * iOS 那边（`Aevis/Core/NeteaseLogin.swift`）就是 **WKWebView 内嵌 + 监听 cookie 存储
 * 自动 harvest `MUSIC_U`**，一步都不用手抄。安卓按同一套做，三种方式并存：
 *
 *  ① **登录**（默认）：全屏 WebView 打开网易云登录页，手机号/验证码/扫码都行。
 *     登录一完成，`CookieManager` 里就会出现 `MUSIC_U`，这里每 1.5 秒扫一次，
 *     拿到就自动关页面、直接可用。
 *  ② **扫码**：App 内生成二维码，用**另一台设备**扫（同一台扫自己会被风控）。
 *  ③ **Token**：从电脑浏览器复制 `MUSIC_U` 贴进来，兜底用。
 *
 * ⚠️ 为什么不能用系统浏览器：cookie 是**按进程 + 域名隔离**的，
 *    浏览器里登完，App 读不到（除非 root）。只有 WebView 在 App 进程内，
 *    cookie 才归我们。用户说的「授权登录后返回就能读登录态」需要对方开放 OAuth，
 *    网易云没开放。
 */
@Composable
fun NeteaseLoginDialog(onClose: () -> Unit, onDone: () -> Unit) {
    var mode by remember { mutableIntStateOf(0) }
    if (mode == 0) {
        NeteaseWebLogin(onClose = onClose, onDone = onDone, onSwitchToQr = { mode = 1 })
    } else {
        val ink = MaterialTheme.colorScheme.onSurface
        Dialog(onDismissRequest = onClose) {
            Column(
                Modifier.clip(squircle(24.dp))
                    .background(MaterialTheme.colorScheme.surface)
                    .padding(horizontal = V2.gutter, vertical = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(tr("登录网易云"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(14.dp))
                Row(
                    Modifier.fillMaxWidth().clip(squircle(12.dp))
                        .background(ink.copy(alpha = 0.05f))
                        .padding(3.dp)
                ) {
                    listOf("账号登录", "扫码", "Token").forEachIndexed { i, label ->
                        val on = mode == i
                        Text(
                            tr(label), fontSize = 13.sp, textAlign = TextAlign.Center,
                            color = if (on) ink else ink.copy(alpha = 0.45f),
                            fontWeight = if (on) FontWeight.Medium else FontWeight.Normal,
                            modifier = Modifier.weight(1f)
                                .clip(squircle(10.dp))
                                .background(
                                    if (on) MaterialTheme.colorScheme.surface
                                    else androidx.compose.ui.graphics.Color.Transparent
                                )
                                .tapable { mode = i }
                                .padding(vertical = 8.dp)
                        )
                    }
                }
                Spacer(Modifier.height(14.dp))
                when (mode) {
                    1 -> QrLoginPane(onDone = onDone)
                    else -> TokenLoginPane(onDone = onDone)
                }
                Spacer(Modifier.height(10.dp))
                TextButton(onClick = onClose) {
                    Text(tr("取消"), fontSize = 14.sp, color = ink.copy(alpha = 0.5f))
                }
            }
        }
    }
}

/** 内嵌 WebView 登录（主力）。*/
@androidx.annotation.RequiresApi(21)
@androidx.compose.runtime.Composable
private fun NeteaseWebLogin(onClose: () -> Unit, onDone: () -> Unit, onSwitchToQr: () -> Unit) {
    val ctx = LocalContext.current
    val ink = MaterialTheme.colorScheme.onSurface
    var loading by remember { mutableStateOf(true) }
    var got by remember { mutableStateOf(false) }

    // 登录态一出现就收工。WebView 的 cookie 在 App 进程里，读得到。
    LaunchedEffect(Unit) {
        while (!got) {
            delay(1500)
            // 🔴 必须在**主线程**调 —— CookieManager 是 WebView 的 API，
            // 切到 IO 线程读会拿到 null（而且还被 runCatching 吃掉，看起来像"登录成功但读不到"）。
            // 之前就是栽在这里：用户说"读取登录太失败了"。
            val c = readNeteaseCookies()
            if (c != null && c.contains("MUSIC_U=")) {
                got = true
                NeteaseAuth.saveLogin(ctx, c, "", "")
                val acc = withContext(Dispatchers.IO) {
                    runCatching { NeteaseAuth.fetchAccount(ctx) }.getOrNull()
                }
                if (acc != null) NeteaseAuth.saveLogin(ctx, c, acc.first, acc.second)
                onDone()
            }
        }
    }

    Dialog(
        onDismissRequest = onClose,
        properties = androidx.compose.ui.window.DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        Column(
            Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)
                .statusBarsPadding()
        ) {
            // 顶栏：关 + 标题 + 扫一扫切换
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(tr("关闭"), fontSize = 14.sp, color = ink.copy(alpha = 0.6f),
                    modifier = Modifier.tapable { onClose() }.padding(6.dp))
                Spacer(Modifier.weight(1f))
                Text(tr("登录网易云"), fontSize = 15.sp, fontWeight = FontWeight.Medium)
                Spacer(Modifier.weight(1f))
                Text(tr("扫码"), fontSize = 14.sp, color = V2.accent,
                    modifier = Modifier.tapable { onSwitchToQr() }.padding(6.dp))
            }
            if (loading) {
                androidx.compose.material3.LinearProgressIndicator(
                    Modifier.fillMaxWidth().height(2.dp),
                    color = V2.accent,
                    trackColor = ink.copy(alpha = 0.06f)
                )
            }
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { c ->
                    android.webkit.WebView(c).apply {
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.databaseEnabled = true
                        settings.useWideViewPort = true
                        settings.loadWithOverviewMode = true
                        settings.userAgentString =
                            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
                                "(KHTML, like Gecko) Chrome/131.0 Mobile Safari/537.36"
                        android.webkit.CookieManager.getInstance().setAcceptCookie(true)
                        android.webkit.CookieManager.getInstance()
                            .setAcceptThirdPartyCookies(this, true)
                        webViewClient = object : android.webkit.WebViewClient() {
                            override fun onPageStarted(
                                view: android.webkit.WebView?, url: String?,
                                favicon: android.graphics.Bitmap?
                            ) { loading = true }

                            override fun onPageFinished(
                                view: android.webkit.WebView?, url: String?
                            ) {
                                loading = false
                                // 页面加载完再读一次（有些 cookie 是 JS 后写的）
                                view?.postDelayed({
                                    val ck = readNeteaseCookies()
                                    if (ck != null && ck.contains("MUSIC_U=")) {
                                        NeteaseAuth.saveLogin(ctx, ck, "", "")
                                    }
                                }, 800)
                            }

                            // 🔴 2026-11-15 关键：拦截**每一个子请求**的 Cookie 头。
                            // 网易云网页是 SPA（`#/login` hash 路由），登录成功后页面**不会重新加载**，
                            // onPageFinished 只触发一次，所以等回调拿 cookie 永远是空的。
                            // 改成从这里捞：只要页面发出任何带上 MUSIC_U 的请求，立刻存下来。
                            override fun shouldInterceptRequest(
                                view: android.webkit.WebView?,
                                request: android.webkit.WebResourceRequest?
                            ): android.webkit.WebResourceResponse? {
                                runCatching {
                                    val ck = request?.requestHeaders?.get("Cookie").orEmpty()
                                    if (ck.contains("MUSIC_U=")) {
                                        NeteaseAuth.saveLogin(ctx, ck, "", "")
                                    }
                                }
                                return null
                            }
                        }
                        loadUrl("https://music.163.com/#/login")
                    }
                }
            )
        }
    }
}

/** 扫码：二维码 + 轮询。*/
@Composable
private fun QrLoginPane(onDone: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    var qr by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    var status by remember { mutableStateOf("正在生成二维码…") }
    var round by remember { mutableIntStateOf(0) }

    LaunchedEffect(round) {
        qr = null
        status = "正在生成二维码…"
        val k = withContext(Dispatchers.IO) { runCatching { NeteaseAuth.qrKey() }.getOrNull() }
        if (k == null) {
            status = "拿不到二维码，稍后再试"
            return@LaunchedEffect
        }
        val bmp = withContext(Dispatchers.IO) { qrBitmap(k.url, 480) }
        if (bmp == null) {
            status = "二维码画不出来"
            return@LaunchedEffect
        }
        qr = bmp
        status = "用「另一台设备」的网易云 App 扫（别用这台手机扫自己）"

        repeat(90) {
            delay(2000)
            val (st, ck) = withContext(Dispatchers.IO) { NeteaseAuth.qrPoll(k.key) }
            when (st) {
                "ok" -> {
                    if (ck.contains("MUSIC_U=")) {
                        val acc = withContext(Dispatchers.IO) {
                            runCatching {
                                NeteaseAuth.saveLogin(ctx, ck, "", "")
                                NeteaseAuth.fetchAccount(ctx)
                            }.getOrNull()
                        }
                        if (acc != null) NeteaseAuth.saveLogin(ctx, ck, acc.first, acc.second)
                        onDone()
                    } else {
                        status = "没拿到凭证，改用「账号登录」试试"
                    }
                    return@LaunchedEffect
                }
                "scanned" -> status = "已扫码，请在另一台设备上点确认"
                "expired" -> { status = "二维码过期了"; return@LaunchedEffect }
                "err" -> { status = "轮询失败，换个网络或改用账号登录"; return@LaunchedEffect }
            }
        }
        status = "二维码过期了"
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(status, fontSize = 12.5.sp, color = ink.copy(alpha = 0.5f),
            textAlign = TextAlign.Center)
        Spacer(Modifier.height(12.dp))
        Box(
            Modifier.size(200.dp).clip(squircle(14.dp)).background(ink.copy(alpha = 0.04f)),
            contentAlignment = Alignment.Center
        ) {
            val b = qr
            if (b != null) {
                Image(bitmap = b.asImageBitmap(), contentDescription = "二维码",
                    modifier = Modifier.size(184.dp))
            } else {
                Text(tr("正在加载…"), fontSize = 13.sp, color = ink.copy(alpha = 0.4f))
            }
        }
        TextButton(onClick = { round++ }) {
            Text(tr("换一张"), fontSize = 13.sp, color = V2.accent)
        }
    }
}

/** Token：从电脑浏览器复制 MUSIC_U 贴进来。*/
@Composable
private fun TokenLoginPane(onDone: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    var text by remember { mutableStateOf("") }
    var err by remember { mutableStateOf("") }

    Column(Modifier.fillMaxWidth()) {
        Text(
            "在电脑上登录 music.163.com → F12 → Application → Cookies → "
                + "复制 MUSIC_U 的值，发到手机粘进来。只贴值就行，前缀会自动补。",
            fontSize = 12.5.sp, color = ink.copy(alpha = 0.55f), lineHeight = 19.sp
        )
        Spacer(Modifier.height(12.dp))
        Row(
            Modifier.fillMaxWidth().clip(squircle(11.dp))
                .background(ink.copy(alpha = 0.05f))
                .tapable {
                    val cm = ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                            as android.content.ClipboardManager
                    val clip = cm.primaryClip
                    val raw = if (clip != null && clip.itemCount > 0)
                        clip.getItemAt(0).coerceToText(ctx).toString() else ""
                    if (raw.isNotBlank()) { text = raw; err = "" }
                    else err = "剪贴板是空的"
                }
                .padding(vertical = 10.dp),
            horizontalArrangement = Arrangement.Center
        ) {
            Text(tr("从剪贴板粘贴"), fontSize = 13.sp, color = ink.copy(alpha = 0.66f))
        }
        Spacer(Modifier.height(8.dp))
        Box(
            Modifier.fillMaxWidth().heightIn(min = 70.dp).clip(squircle(12.dp))
                .background(ink.copy(alpha = 0.05f))
                .padding(horizontal = 11.dp, vertical = 9.dp)
        ) {
            BasicTextField(
                value = text, onValueChange = { text = it; err = "" },
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.5.sp, color = ink),
                decorationBox = { inner ->
                    if (text.isEmpty()) {
                        Text("粘贴 MUSIC_U 的值", fontSize = 12.5.sp,
                            color = ink.copy(alpha = 0.32f))
                    }
                    inner()
                },
                modifier = Modifier.fillMaxWidth()
            )
        }
        if (err.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            Text(err, fontSize = 12.sp, color = V2.alert)
        }
        Spacer(Modifier.height(10.dp))
        Row(
            Modifier.fillMaxWidth().clip(squircle(13.dp)).background(V2.accent)
                .tapable {
                    val t = text.trim()
                    when {
                        t.isEmpty() -> err = "先粘贴登录凭证"
                        t.contains("MUSIC_U=") -> { NeteaseAuth.saveLogin(ctx, t, "", ""); onDone() }
                        t.length >= 20 && !t.contains("=") -> {
                            NeteaseAuth.saveLogin(ctx, "MUSIC_U=" + t, "", ""); onDone()
                        }
                        else -> err = "没识别出 MUSIC_U，检查一下是不是粘错了"
                    }
                }
                .padding(vertical = 13.dp),
            horizontalArrangement = Arrangement.Center
        ) {
            Text(tr("完成登录"), fontSize = 14.sp,
                color = androidx.compose.ui.graphics.Color.White, fontWeight = FontWeight.Medium)
        }
    }
}


/**
 * 从 WebView 的 CookieManager 里把网易云的登录凭证捞出来。
 *
 * ⚠️ 三个要点，少一个就读不到：
 *   ① **必须主线程**（CookieManager 不是线程安全的，IO 线程读返回 null）
 *   ② 按**域名逐个问** —— `getCookie` 只返回该 URL 可见的那些；
 *      登录后 cookie 可能挂在 `.163.com` / `.music.163.com` / `music.163.com` 上，
 *      只问一个域名会漏。
 *   ③ 读完调 `flush()`，不然进程被杀就丢了。
 */
private fun readNeteaseCookies(): String? {
    val cm = android.webkit.CookieManager.getInstance()
    val out = LinkedHashMap<String, String>()
    listOf(
        "https://music.163.com",
        "https://.music.163.com",
        "https://163.com",
        "https://.163.com",
        "https://interface.music.163.com"
    ).forEach { url ->
        val raw = runCatching { cm.getCookie(url) }.getOrNull() ?: return@forEach
        raw.split(";").forEach { kv ->
            val t = kv.trim()
            if (t.isEmpty()) return@forEach
            val i = t.indexOf('=');
            if (i <= 0) return@forEach
            val k = t.substring(0, i)
            if (k !in out) out[k] = t.substring(i + 1)
        }
    }
    runCatching { cm.flush() }
    if (out.isEmpty()) return null
    return out.entries.joinToString("; ") { "${it.key}=${it.value}" }
}

/** 把内容画成二维码 Bitmap。*/
private fun qrBitmap(text: String, size: Int): android.graphics.Bitmap? = runCatching {
    val m = com.google.zxing.qrcode.QRCodeWriter()
        .encode(text, com.google.zxing.BarcodeFormat.QR_CODE, size, size)
    val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
    for (x in 0 until size) {
        for (y in 0 until size) {
            bmp.setPixel(x, y, if (m[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
        }
    }
    bmp
}.getOrNull()

/**
 * 我页头像 + 选图入口（2026-11-17，175，BUG-02）。
 *
 * 之前这个头像**完全没有点击处理**（QA 实测：点了没任何反应），所以"设置不了头像"。
 * 现在：点头像/相机角标 → 系统相册（`PickVisualMedia`，13+ 不需要存储权限）→
 * `AvatarStore.import(uri, "me")` → `ChatPrefs.bumpUi()`。
 * 失败弹 Toast 带原因（不静默）；取消什么都不做。
 */
@Composable
fun MyAvatarPicker(url: String, name: String) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    var shown by remember(url) { mutableStateOf(url) }
    var busy by remember { mutableStateOf(false) }

    val picker = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult   // 取消：静默
        busy = true
        scope.launch(kotlinx.coroutines.Dispatchers.IO) {
            val ok = runCatching { com.aevis.android.core.AvatarStore.import(ctx, "me", uri) }
                .getOrDefault(false)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                busy = false
                if (ok) {
                    // 本地路径优先（AvatarStore 返回的就是文件路径）
                    shown = com.aevis.android.core.AvatarStore.file("me").absolutePath
                    com.aevis.android.core.ChatPrefs.bumpUi()
                } else {
                    android.widget.Toast.makeText(
                        ctx, "头像保存失败：图片无法读取", android.widget.Toast.LENGTH_LONG
                    ).show()
                }
            }
        }
    }

    Box(
        Modifier.clip(androidx.compose.foundation.shape.CircleShape)
            .tapable { picker.launch(
                androidx.activity.result.PickVisualMediaRequest(
                    androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly
                )
            ) }
    ) {
        Avatar(shown, name, 56.dp)
        // 右下角相机角标（20dp），提示"这里能点"
        Box(
            Modifier.align(Alignment.BottomEnd)
                .size(20.dp)
                .clip(androidx.compose.foundation.shape.CircleShape)
                .background(MaterialTheme.colorScheme.surface),
            contentAlignment = Alignment.Center
        ) {
            androidx.compose.material3.Icon(
                painterResource(R.drawable.ic_att_camera),
                contentDescription = "更换头像",
                tint = V2.accent,
                modifier = Modifier.size(13.dp)
            )
        }
    }
}
