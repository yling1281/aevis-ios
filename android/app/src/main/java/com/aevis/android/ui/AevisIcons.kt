package com.aevis.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * 全 App 图标 —— **逐像素照搬 iOS 的 `DesignSystem/PaperIcons.swift`**。
 *
 * 用户 2026-11-14：「所有的图标都用 iOS 的那个我们画的矢量图直接照搬过来」。
 *
 * iOS 那套不是 SF Symbols，是老板自己用 Path 手画的（归一化 0~1 坐标），
 * 所以这里把坐标一比一搬过来 —— 两端必须是同一个视觉语言，
 * 换 Material 图标就会出现"安卓味"。
 *
 * ⚠️ 改坐标要**两边一起改**，不然 iOS / 安卓会长得不一样。
 */
// MARK: - 会话（对话气泡）
@Composable
fun IcChat(color: Color, dim: Dp = 22.dp) {
    Canvas(Modifier.size(dim)) {
        val w = size.width
        val p = Path().apply {
            moveTo(w * 0.14f, w * 0.20f)
            lineTo(w * 0.86f, w * 0.20f)
            lineTo(w * 0.86f, w * 0.68f)
            lineTo(w * 0.44f, w * 0.68f)
            lineTo(w * 0.24f, w * 0.86f)
            lineTo(w * 0.24f, w * 0.68f)
            lineTo(w * 0.14f, w * 0.68f)
            close()
        }
        drawPath(p, color, style = Ic_Stroke(w * 0.075f))
    }
}

// MARK: - 发现（罗盘）
@Composable
fun IcCompass(color: Color, dim: Dp = 22.dp) {
    Canvas(Modifier.size(dim)) {
        val w = size.width
        drawCircle(
            color = color,
            radius = w * 0.36f,
            center = Offset(w * 0.5f, w * 0.5f),
            style = Ic_Stroke(w * 0.075f)
        )
        val p = Path().apply {
            moveTo(w * 0.62f, w * 0.36f)
            lineTo(w * 0.54f, w * 0.54f)
            lineTo(w * 0.36f, w * 0.62f)
            lineTo(w * 0.46f, w * 0.46f)
            close()
        }
        drawPath(p, color, style = Fill)
    }
}

// MARK: - 通讯录（两个人）
@Composable
fun IcPeople(color: Color, dim: Dp = 22.dp) {
    Canvas(Modifier.size(dim)) {
        val w = size.width
        val sw = Ic_Stroke(w * 0.07f)
        drawCircle(color, w * 0.115f, Offset(w * 0.34f, w * 0.34f), style = sw)
        drawCircle(color, w * 0.095f, Offset(w * 0.70f, w * 0.38f), style = sw)

        val b1 = Path().apply {
            moveTo(w * 0.14f, w * 0.80f)
            cubicTo(w * 0.14f, w * 0.60f, w * 0.54f, w * 0.60f, w * 0.54f, w * 0.80f)
        }
        drawPath(b1, color, style = sw)

        val b2 = Path().apply {
            moveTo(w * 0.62f, w * 0.78f)
            cubicTo(w * 0.63f, w * 0.64f, w * 0.88f, w * 0.64f, w * 0.88f, w * 0.78f)
        }
        drawPath(b2, color, style = sw)
    }
}

// MARK: - 我的（单个人）
@Composable
fun IcPerson(color: Color, dim: Dp = 22.dp) {
    Canvas(Modifier.size(dim)) {
        val w = size.width
        val sw = Ic_Stroke(w * 0.075f)
        drawCircle(color, w * 0.14f, Offset(w * 0.50f, w * 0.34f), style = sw)
        val p = Path().apply {
            moveTo(w * 0.22f, w * 0.84f)
            cubicTo(w * 0.22f, w * 0.58f, w * 0.78f, w * 0.58f, w * 0.78f, w * 0.84f)
        }
        drawPath(p, color, style = sw)
    }
}

// MARK: - 加号
@Composable
fun IcPlus(color: Color, dim: Dp = 18.dp) {
    Canvas(Modifier.size(dim)) {
        val w = size.width
        val sw = Ic_Stroke(w * 0.09f)
        val p = Path().apply {
            moveTo(w * 0.5f, w * 0.22f)
            lineTo(w * 0.5f, w * 0.78f)
            moveTo(w * 0.22f, w * 0.5f)
            lineTo(w * 0.78f, w * 0.5f)
        }
        drawPath(p, color, style = sw)
    }
}

// MARK: - 扫一扫（四角取景框）
@Composable
fun IcScan(color: Color, dim: Dp = 18.dp) {
    Canvas(Modifier.size(dim)) {
        val w = size.width
        val sw = Ic_Stroke(w * 0.08f)
        val pad = w * 0.16f
        val p = Path().apply {
            // 左上
            moveTo(pad, w * 0.38f); lineTo(pad, pad); lineTo(w * 0.38f, pad)
            // 右上
            moveTo(w - pad, w * 0.38f); lineTo(w - pad, pad); lineTo(w * 0.62f, pad)
            // 左下
            moveTo(pad, w * 0.62f); lineTo(pad, w - pad); lineTo(w * 0.38f, w - pad)
            // 右下
            moveTo(w - pad, w * 0.62f); lineTo(w - pad, w - pad); lineTo(w * 0.62f, w - pad)
        }
        drawPath(p, color, style = sw)
    }
}

/** 圆头圆角的描边 —— iOS 那套全是 `lineCap: .round, lineJoin: .round`。*/
private fun Ic_Stroke(width: Float) = Stroke(
    width = width,
    cap = StrokeCap.Round,
    join = StrokeJoin.Round
)

// MARK: - 商城（购物袋）—— 对 iOS `bag.fill`
@Composable
fun IcBag(color: Color, dim: Dp = 19.dp) {
    Canvas(Modifier.size(dim)) {
        val w = size.width
        // 提手：一个半圆，线要压住袋口
        val handle = Path().apply {
            moveTo(w * 0.335f, w * 0.42f)
            cubicTo(w * 0.335f, w * 0.16f, w * 0.665f, w * 0.16f, w * 0.665f, w * 0.42f)
        }
        drawPath(
            handle, color,
            style = Stroke(width = w * 0.085f, cap = StrokeCap.Round, join = StrokeJoin.Round)
        )
        // 袋身
        val body = Path().apply {
            moveTo(w * 0.17f, w * 0.37f)
            lineTo(w * 0.83f, w * 0.37f)
            lineTo(w * 0.80f, w * 0.86f)
            cubicTo(w * 0.80f, w * 0.90f, w * 0.77f, w * 0.92f, w * 0.73f, w * 0.92f)
            lineTo(w * 0.27f, w * 0.92f)
            cubicTo(w * 0.23f, w * 0.92f, w * 0.20f, w * 0.90f, w * 0.20f, w * 0.86f)
            close()
        }
        drawPath(body, color, style = Fill)
    }
}
