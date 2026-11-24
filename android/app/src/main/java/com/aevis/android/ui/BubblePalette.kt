package com.aevis.android.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance

/**
 * 气泡配色（2026-11-16）。
 *
 * 用户：「气泡颜色我要自己能调，两个人不能是一样的颜色」。
 *
 * 为什么单开一个文件：这套色值 **iOS 端要照抄同一份**，散在界面里的话
 * 两边各写一个值，早晚会漂。预设写在 `presets` 里，界面只负责画圆点，
 * 不负责编颜色。
 *
 * 每组的 `mine` = 主色那六个（跟 `V2.accentPalette` 一一对应），
 * `ai` = 同色压暗压灰后的那一层（暗色主题直接用它，浅色主题再往白里提），
 * 这样两个人在同一套色系里，但一眼能分清谁是谁。
 */
object BubblePalette {

    /** 一组预览色。`mine` / `ai` 都是 ARGB（用 Long 存，写 0xFF… 时不用 .toInt()）。*/
    data class Preset(val name: String, val mine: Long, val ai: Long)

    /**
     * 六组预设，顺序与 `V2.accentPalette` 完全一致：
     * 淡紫 / 淡蓝 / 青 / 玫红 / 橙 / 绿。
     */
    val presets: List<Preset> = listOf(
        Preset("淡紫", 0xFF9B8AF0, 0xFF3B3652),
        Preset("淡蓝", 0xFF6FA8E8, 0xFF313C50),
        Preset("青", 0xFF21A394, 0xFF203B3E),
        Preset("玫红", 0xFFE05185, 0xFF4A293B),
        Preset("橙", 0xFFEB8C2E, 0xFF4D3628),
        Preset("绿", 0xFF669E33, 0xFF2F3A29)
    )

    /** 我的气泡底色。`pref == 0`（没设过）回落到主题主色。*/
    fun mineColor(pref: Int): Color = if (pref == 0) V2.accent else Color(pref)

    /**
     * 对方气泡底色。`pref == 0` 回落到主题玻璃色 —— 跟聊天页原来那套一致：
     * 暗色是很淡的白（透明玻璃），浅色是白玻璃。
     *
     * 预设的 `ai` 是按**暗色底**调的，浅色主题下直接铺会显脏，
     * 所以浅色走「往白里提 72%」+ 更高不透明度。
     */
    fun aiColor(pref: Int, dark: Boolean): Color {
        if (pref == 0) {
            return if (dark) Color.White.copy(alpha = 0.06f)
            else Color.White.copy(alpha = 0.78f)
        }
        val c = Color(pref)
        return if (dark) c.copy(alpha = 0.55f)
        else mix(c, Color.White, 0.72f).copy(alpha = 0.85f)
    }

    /**
     * 底色亮配深字、暗配白字。
     *
     * 用户取浅黄 / 浅粉的时候白字直接看不见 —— 所以字色**必须**跟着底色算，
     * 不能再无脑 `Color.White`。
     */
    fun textOn(bg: Color): Color =
        if (bg.luminance() > 0.55f) Color(0xFF1B1A1F) else Color.White

    /** 线性混色。`t = 0` 全是 a，`t = 1` 全是 b。*/
    private fun mix(a: Color, b: Color, t: Float): Color {
        val k = t.coerceIn(0f, 1f)
        return Color(
            red = a.red + (b.red - a.red) * k,
            green = a.green + (b.green - a.green) * k,
            blue = a.blue + (b.blue - a.blue) * k,
            alpha = 1f
        )
    }
}
