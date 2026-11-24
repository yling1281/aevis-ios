package com.aevis.android.ui

import androidx.compose.ui.graphics.asImageBitmap
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 充值（2026-11-15）。
 *
 * 用户：「充值页面也没做」+「不管选的是微信还是支付宝，都通通直接跳到这个收银台」。
 *
 * 所以这里**不自己做微信/支付宝按钮** —— 点套餐统一跳我们自己的收银台：
 *   `https://aevis.cn/pay/?product=pt_30&name=<用户名>`
 * 收银台里再选支付方式，手机端会直接用 `weixin://` / `alipays://` 拉起 App。
 *
 * 商品名和订单号由收银台拼（`用户名 商品名 订单号`），后台对账能认出是谁买的。
 */
@Composable
fun RechargeScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var points by remember { mutableIntStateOf(-1) }
    var me by remember { mutableStateOf<Api.MeInfo?>(Api.cachedMe()) }

    LaunchedEffect(Unit) {
        points = withContext(Dispatchers.IO) {
            runCatching { Api.balance() }.getOrNull() ?: -1
        }
        runCatching { Api.me() }.getOrNull()?.let { me = it }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "充值", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {

            // 当前余额
            V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(tr("当前余额"), fontSize = 12.sp,
                            color = ink.copy(alpha = 0.45f))
                        Spacer(Modifier.height(4.dp))
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(
                                if (points >= 0) "$points" else "—",
                                fontSize = 30.sp, fontWeight = FontWeight.Bold,
                                color = ink, letterSpacing = (-1).sp
                            )
                            Spacer(Modifier.width(5.dp))
                            Text(tr("墨点"), fontSize = 12.sp,
                                color = ink.copy(alpha = 0.42f),
                                modifier = Modifier.padding(bottom = 6.dp))
                        }
                    }
                    Text(
                        tr("1 元 = 100 墨点"),
                        fontSize = 11.sp, color = ink.copy(alpha = 0.35f)
                    )
                }
            }

            Spacer(Modifier.height(V2.sectionGap))
            Text(
                tr("选一个套餐"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
            )

            PointPacks()

            // 183：会员三档（7/30/90 天），与积分共用同一个扫码弹层
            Spacer(Modifier.height(14.dp))
            Text(
                tr("会员"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
            )
            MemberPacks()

            Spacer(Modifier.height(18.dp))
            Text(
                tr("扫码后自动到账；若二维码打不开，可点「打开收银台」。"),
                fontSize = 11.sp, color = ink.copy(alpha = 0.35f), lineHeight = 16.sp,
                modifier = Modifier.padding(horizontal = V2.gutter)
            )

            Spacer(Modifier.height(34.dp))
        }
    }
}

/**
 * 统一下单 → 拉起收银台（2026-11-16 从充值页抽出来）。
 *
 * 为什么抽：商城页的「会员」和「墨点」两段都要能真买，跟充值页是同一个链路。
 * 复制一份的话，以后改下单接口（比如加签名）得改两处。
 *
 * 链路：先打**我们服务端** `Api.paySession(sku)` 拿一次性 URL（只有 token、
 * 不含用户名/商品），再 `ACTION_VIEW` 丢给浏览器/收银台。
 */
internal fun payOrder(
    ctx: android.content.Context,
    scope: kotlinx.coroutines.CoroutineScope,
    sku: String
) {
    // 2026-11-16（100）：不再直接开浏览器 —— 交给半窗（PaySheetHost）。
    // 用户原话：「点微信不是跳微信，而是把要在微信里打开的链接直接在当前浏览器打开了，付不了」。
    // 收银台那边会把微信改成 Native 二维码、支付宝改 H5，客户端这边先把半窗做好。
    PayState.request(sku)
}

/** 支付半窗的全局状态（从非 Composable 的 `payOrder` 里也能触发）。*/
internal object PayState {
    var sku by mutableStateOf<String?>(null)
    fun request(s: String) { sku = s }
    fun clear() { sku = null }
}

/**
 * 支付半窗（2026-11-16，100）。
 *
 * 流程：点「立即支付」→ 抬起半窗「正在创建订单…」→ 拿到收银台地址后原地换内容：
 * 二维码（内容 = `code_url`，没有就退化成收银台 url）+ 「在微信中打开」+「用浏览器打开」；
 * 失败显示服务端 msg（`Api.lastPayError`），不是一句"失败"。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun PaySheetHost() {
    val sku = PayState.sku ?: return
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val ink = androidx.compose.material3.MaterialTheme.colorScheme.onSurface
    var phase by remember { mutableStateOf(0) }   // 0 创建中 / 1 就绪 / 2 失败
    var payUrl by remember { mutableStateOf("") }
    var codeUrl by remember { mutableStateOf("") }
    var err by remember { mutableStateOf("") }

    LaunchedEffect(sku) {
        phase = 0
        val r = withContext(Dispatchers.IO) { runCatching { Api.paySessionInfo(sku) }.getOrNull() }
        if (r == null) {
            phase = 2
            err = Api.lastPayError.ifBlank { "下单失败" }
        } else {
            payUrl = r.first
            codeUrl = r.second
            phase = 1
        }
    }

    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = { PayState.clear() },
        containerColor = dialogSurfaceColor()
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                .navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                when (phase) {
                    0 -> "正在创建订单…"
                    1 -> "扫码支付"
                    else -> "下单失败"
                },
                fontSize = 16.sp, fontWeight = FontWeight.SemiBold
            )
            Spacer(Modifier.height(14.dp))

            when (phase) {
                0 -> {
                    androidx.compose.material3.CircularProgressIndicator(
                        modifier = Modifier.size(28.dp),
                        color = V2.accent, strokeWidth = 2.5.dp
                    )
                    Spacer(Modifier.height(18.dp))
                }
                1 -> {
                    // 二维码内容优先用 code_url（微信 Native），没有就用收银台地址
                    val content = codeUrl.ifBlank { payUrl }
                    val bmp = remember(content) { payQrBitmap(content, 512) }
                    if (bmp != null) {
                        androidx.compose.foundation.Image(
                            bitmap = bmp.asImageBitmap(), contentDescription = "支付二维码",
                            modifier = Modifier.size(180.dp)
                                .clip(squircle(10.dp))
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "用微信扫一扫付款",
                            fontSize = 12.sp, color = ink.copy(alpha = 0.5f)
                        )
                    }
                    Spacer(Modifier.height(14.dp))
                    // 在微信中打开（收银台还没改成 Native 时，这是唯一能付的路）
                    Box(
                        Modifier.fillMaxWidth().clip(squircle(14.dp))
                            .background(androidx.compose.ui.graphics.Color(0xFF4AB85C))
                            .tapable {
                                runCatching {
                                    ctx.startActivity(
                                        Intent(Intent.ACTION_VIEW, Uri.parse(payUrl))
                                            .setPackage("com.tencent.mm")
                                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    )
                                }.onFailure {
                                    Toast.makeText(
                                        ctx, "没装微信？用浏览器打开吧", Toast.LENGTH_SHORT
                                    ).show()
                                }
                            }
                            .padding(vertical = 13.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            "在微信中打开", fontSize = V2.body,
                            fontWeight = FontWeight.Medium,
                            color = androidx.compose.ui.graphics.Color.White
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    Box(
                        Modifier.fillMaxWidth().clip(squircle(14.dp))
                            .background(ink.copy(alpha = 0.06f))
                            .tapable {
                                runCatching {
                                    ctx.startActivity(
                                        Intent(Intent.ACTION_VIEW, Uri.parse(payUrl))
                                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    )
                                }
                            }
                            .padding(vertical = 12.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("用浏览器打开", fontSize = V2.sub, color = ink.copy(alpha = 0.65f))
                    }
                    Spacer(Modifier.height(10.dp))
                }
                else -> {
                    Text(
                        err, fontSize = 13.sp, color = V2.alert, lineHeight = 20.sp
                    )
                    Spacer(Modifier.height(16.dp))
                    Box(
                        Modifier.fillMaxWidth().clip(squircle(14.dp))
                            .background(ink.copy(alpha = 0.06f))
                            .tapable { PayState.clear() }
                            .padding(vertical = 12.dp),
                        contentAlignment = Alignment.Center
                    ) { Text("关闭", fontSize = V2.sub, color = ink.copy(alpha = 0.65f)) }
                    Spacer(Modifier.height(10.dp))
                }
            }
            Spacer(Modifier.height(6.dp))
        }
    }
}

/** 生成二维码位图（zxing 已在工程里，扫码页用的就是它）。*/
internal fun payQrBitmap(text: String, size: Int): android.graphics.Bitmap? = runCatching {
    val m = com.google.zxing.qrcode.QRCodeWriter()
        .encode(text, com.google.zxing.BarcodeFormat.QR_CODE, size, size)
    val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
    for (x in 0 until size) for (y in 0 until size) {
        bmp.setPixel(x, y, if (m[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
    }
    bmp
}.getOrNull()

/**
 * 墨点六档套餐（2026-11-16 从 `RechargeScreen` 抽出来，商城页复用）。
 *
 * 自带 `V2Card` 和外层 gutter —— 两个页面的位置都一样，调用方只管插进去。
 */
@Composable
internal fun PointPacks() {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    val packs = listOf(
        Triple("pt_1", "1 元", 100),
        Triple("pt_6", "6 元", 600),
        Triple("pt_18", "18 元", 1800),
        Triple("pt_30", "30 元", 3000),
        Triple("pt_68", "68 元", 6800),
        Triple("pt_128", "128 元", 12800)
    )

    // 182：支付方式（默认记上次）+ 扫码弹层宿主
    var channel by remember { mutableStateOf(com.aevis.android.core.ChatPrefs.payChannel) }
    var paying by remember { mutableStateOf(false) }
    var payInfo by remember { mutableStateOf<PayInfo?>(null) }
    payInfo?.let { info ->
        PayDialog(
            info = info,
            onClose = { payInfo = null },
            onPaid = { qty ->
                payInfo = null
                Toast.makeText(ctx, "充值到账 $qty", Toast.LENGTH_LONG).show()
                com.aevis.android.core.ChatPrefs.bumpUi()
            }
        )
    }

    // 方式芯片（微信 / 支付宝都可用）
    Row(
        Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 6.dp)
            .height(40.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        listOf(
            Triple("wxpay", "微信支付", R.drawable.ic_wx),
            Triple("alipay", "支付宝", R.drawable.ic_alipay)
        ).forEach { (k, label, iconRes) ->
            val on = channel == k
            Row(
                Modifier.clip(RoundedCornerShape(9.dp))
                    .background(if (on) Color(0xFF101828) else ink.copy(alpha = 0.05f))
                    .tapable {
                        channel = k
                        com.aevis.android.core.ChatPrefs.payChannel = k
                    }
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    painterResource(iconRes), contentDescription = null,
                    tint = Color.Unspecified, modifier = Modifier.size(16.dp)
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    label, fontSize = 12.sp,
                    color = if (on) Color.White else ink.copy(alpha = 0.7f)
                )
            }
        }
    }
    V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
        packs.forEachIndexed { i, (code, label, pts) ->
            if (i > 0) Box(
                Modifier.fillMaxWidth().height(0.5.dp)
                    .background(ink.copy(alpha = 0.07f))
            )
            Row(
                Modifier.fillMaxWidth()
                    .tapable {
                        if (paying) return@tapable
                        paying = true
                        scope.launch(Dispatchers.IO) {
                            val o = runCatching { Api.rechargeQr(code, channel) }.getOrNull()
                            withContext(Dispatchers.Main) {
                                paying = false
                                if (o != null) {
                                    payInfo = PayInfo(
                                        o.orderNo, "Aevis 积分 ${o.points}",
                                        o.amountYuan, "${o.points} 积分", o.qrContent, "points"
                                    )
                                } else {
                                    Toast.makeText(
                                        ctx, Api.lastPayError.ifBlank { "下单失败" }, Toast.LENGTH_LONG
                                    ).show()
                                }
                            }
                        }
                    }
                    .padding(horizontal = V2.gutter, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f)) {
                    Text(label, fontSize = V2.body, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(2.dp))
                    Text("$pts 墨点", fontSize = 11.5.sp, color = ink.copy(alpha = 0.42f))
                }
                Text(
                    tr("去支付"), fontSize = 12.5.sp, color = V2.accent,
                    modifier = Modifier.clip(RoundedCornerShape(9.dp))
                        .background(V2.accent.copy(alpha = 0.12f))
                        .padding(horizontal = 11.dp, vertical = 5.dp)
                )
            }
        }
    }
}


/** 会员档位（2026-11-18，182）：7/30/90 天，走 `/v1/pay/member/qr`。*/
@Composable
internal fun MemberPacks() {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var paying by remember { mutableStateOf(false) }
    var payInfo by remember { mutableStateOf<PayInfo?>(null) }
    payInfo?.let { info ->
        PayDialog(
            info = info,
            onClose = { payInfo = null },
            onPaid = { qty ->
                payInfo = null
                Toast.makeText(ctx, "会员已开通 $qty", Toast.LENGTH_LONG).show()
                com.aevis.android.core.ChatPrefs.bumpUi()
            }
        )
    }
    val plans = listOf(
        Triple("member_7d", "7 天", "6.00"),
        Triple("member_30d", "30 天", "18.00"),
        Triple("member_90d", "90 天", "45.00")
    )
    V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
        plans.forEachIndexed { i, (code, label, yuan) ->
            if (i > 0) Box(
                Modifier.fillMaxWidth().height(0.5.dp).background(ink.copy(alpha = 0.07f))
            )
            Row(
                Modifier.fillMaxWidth().heightIn(min = 56.dp)
                    .tapable {
                        if (paying) return@tapable
                        paying = true
                        scope.launch(Dispatchers.IO) {
                            val m = runCatching { Api.memberQr(code) }.getOrNull()
                            withContext(Dispatchers.Main) {
                                paying = false
                                if (m != null) {
                                    payInfo = PayInfo(
                                        m.orderNo, "Aevis 会员 ${m.days} 天",
                                        m.amountYuan, "${m.days} 天", m.qrContent, "member"
                                    )
                                } else {
                                    Toast.makeText(
                                        ctx, Api.lastPayError.ifBlank { "下单失败" }, Toast.LENGTH_LONG
                                    ).show()
                                }
                            }
                        }
                    }
                    .padding(horizontal = V2.gutter, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f)) {
                    Text(label + "会员", fontSize = V2.body, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(2.dp))
                    Text("到期后自动失效，可续期", fontSize = 11.sp, color = ink.copy(alpha = 0.42f))
                }
                Text("¥$yuan", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** 弹层数据（积分/会员共用）。*/
internal data class PayInfo(
    val orderNo: String, val title: String, val amountYuan: String,
    val qty: String, val qrContent: String, val kind: String
)

/**
 * 扫码支付弹层（2026-11-18，182）。
 *
 * 二维码**本地画**（zxing core），不 WebView、不跳浏览器。
 * 轮询用 `LaunchedEffect(orderNo)` + `while (isActive)`：关层即取消。
 * 形态降级：`http://` 裸 IP（submit 降级）**不出码**，只给「打开收银台」。
 */
@Composable
internal fun PayDialog(info: PayInfo, onClose: () -> Unit, onPaid: (String) -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val bareHttp = info.qrContent.startsWith("http://")
    val bmp = remember(info.qrContent) {
        if (bareHttp) null else payQrBitmap(info.qrContent, 480)
    }
    var secs by remember(info.orderNo) { mutableIntStateOf(120) }
    var paid by remember(info.orderNo) { mutableStateOf(false) }
    var tip by remember(info.orderNo) { mutableStateOf("") }
    val created = remember(info.orderNo) {
        java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.US)
            .format(java.util.Date())
    }

    LaunchedEffect(info.orderNo) {
        launch {
            while (secs > 0) {
                kotlinx.coroutines.delay(1000)
                secs -= 1
            }
        }
        while (kotlin.coroutines.coroutineContext[kotlinx.coroutines.Job]?.isActive != false) {
            kotlinx.coroutines.delay(2000)
            if (paid) break
            val (st, _) = withContext(Dispatchers.IO) {
                runCatching { Api.rechargeStatus(info.orderNo) }.getOrDefault("" to 0)
            }
            if (st == "paid") { paid = true; onPaid(info.qty); break }
            if (st == "closed" || secs <= 0) break
        }
    }

    androidx.compose.ui.window.Dialog(onDismissRequest = onClose) {
        V2Card(Modifier.fillMaxWidth().padding(horizontal = 22.dp), pad = 18.dp) {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    if (paid) "充值成功" else if (info.kind == "member") "微信/支付宝扫码开通会员" else "微信/支付宝扫码支付",
                    fontSize = 15.sp, fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.height(8.dp))
                Text("¥${info.amountYuan}", fontSize = 34.sp, fontWeight = FontWeight.Bold)
                Text(info.qty, fontSize = 12.sp, color = ink.copy(alpha = 0.5f))
                Spacer(Modifier.height(10.dp))
                if (paid) {
                    Icon(
                        painterResource(R.drawable.ic_check), contentDescription = "已支付",
                        tint = Color.Unspecified, modifier = Modifier.size(52.dp)
                    )
                } else if (bmp != null) {
                    androidx.compose.foundation.Image(
                        bitmap = bmp.asImageBitmap(), contentDescription = "支付二维码",
                        modifier = Modifier.size(200.dp)
                    )
                } else {
                    Text(
                        "通道繁忙，请稍后重试", fontSize = 13.sp, color = V2.alert,
                        modifier = Modifier.padding(vertical = 24.dp)
                    )
                }
                Spacer(Modifier.height(8.dp))
                if (!paid) {
                    Text(
                        if (secs > 0) "%d:%02d 内有效，付完自动到账".format(secs / 60, secs % 60)
                        else "二维码已过期，请重新下单",
                        fontSize = 11.sp,
                        color = if (secs > 0) ink.copy(alpha = 0.45f) else V2.alert
                    )
                }
                Spacer(Modifier.height(10.dp))
                InfoRow("订单号", info.orderNo, copyable = true, ctx = ctx)
                InfoRow("商品", info.title)
                InfoRow("金额", "¥${info.amountYuan}")
                InfoRow(
                    "状态",
                    if (paid) "已支付" else "等待支付",
                    iconRes = if (paid) R.drawable.ic_check else R.drawable.ic_hourglass
                )
                InfoRow("创建时间", created)
                if (tip.isNotBlank()) {
                    Spacer(Modifier.height(6.dp))
                    Text(tip, fontSize = 11.sp, color = V2.alert)
                }
                if (!paid && info.qrContent.contains("wxjspay")) {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "若扫码后无法支付，请复制链接在微信中打开",
                        fontSize = 10.5.sp, color = ink.copy(alpha = 0.45f)
                    )
                }
                Spacer(Modifier.height(12.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (!paid) {
                        Box(
                            Modifier.weight(1f).heightIn(min = 42.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color(0xFF4AB85C))
                                .tapable {
                                    kotlinx.coroutines.MainScope().launch {
                                        val (st, _) = withContext(Dispatchers.IO) {
                                            runCatching { Api.rechargeStatus(info.orderNo) }
                                                .getOrDefault("" to 0)
                                        }
                                        if (st == "paid") { paid = true; onPaid(info.qty) }
                                        else tip = "还没收到支付结果，请稍候再试"
                                    }
                                },
                            contentAlignment = Alignment.Center
                        ) { Text("我已完成支付", fontSize = 13.sp, color = Color.White) }
                    }
                    if (bareHttp) {
                        Box(
                            Modifier.weight(1f).heightIn(min = 42.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .background(V2.accent.copy(alpha = 0.12f))
                                .tapable {
                                    runCatching {
                                        ctx.startActivity(
                                            Intent(Intent.ACTION_VIEW, Uri.parse(info.qrContent))
                                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        )
                                    }
                                },
                            contentAlignment = Alignment.Center
                        ) { Text("打开收银台", fontSize = 13.sp, color = V2.accent) }
                    }
                    Box(
                        Modifier.weight(1f).heightIn(min = 42.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(ink.copy(alpha = 0.06f))
                            .tapable { onClose() },
                        contentAlignment = Alignment.Center
                    ) { Text("关闭", fontSize = 13.sp, color = ink.copy(alpha = 0.6f)) }
                }
            }
        }
    }
}

@Composable
private fun InfoRow(
    k: String, v: String,
    copyable: Boolean = false,
    ctx: android.content.Context? = null,
    @androidx.annotation.DrawableRes iconRes: Int = 0
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().padding(vertical = 3.dp)
            .then(
                if (copyable && ctx != null) Modifier.tapable {
                    runCatching {
                        val cm = ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                                as android.content.ClipboardManager
                        cm.setPrimaryClip(android.content.ClipData.newPlainText("order", v))
                        Toast.makeText(ctx, "订单号已复制", Toast.LENGTH_SHORT).show()
                    }
                } else Modifier
            ),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(k, fontSize = 11.sp, color = ink.copy(alpha = 0.45f))
        Spacer(Modifier.weight(1f))
        if (iconRes != 0) {
            Icon(
                painterResource(iconRes), contentDescription = null,
                tint = Color.Unspecified, modifier = Modifier.size(14.dp)
            )
            Spacer(Modifier.width(4.dp))
        }
        Text(
            v, fontSize = 11.5.sp, color = if (copyable) V2.accent else ink.copy(alpha = 0.75f),
            fontFamily = if (copyable) androidx.compose.ui.text.font.FontFamily.Monospace else null
        )
    }
}
