import io

base = r'F:/WorkBuddy/2026-10-17-23-43-43/aevis-ios/android/app/src/main/java/com/aevis/android/'

# ---------- pingLineById：给界面按 id 探测（每条一个 LaunchedEffect = 天然并发） ----------
p = base + 'data/Api.kt'
s = io.open(p, encoding='utf-8').read()
if 'fun pingLineById' not in s:
    anchor = '''    fun pingLine(direct: Boolean): Long {'''
    add = '''    /**
     * 按线路 id 探测（2026-11-16，105）。
     * id：0 北京（只反代图片，测也白测）/ 1 直连 / 2 香港 / 3 新线路（隧道反代）。
     *
     * 界面里每条线路各自一个 `LaunchedEffect` 调它 → **天然并发**，
     * 不会串行把 3 秒超时叠加成 9 秒。
     */
    fun pingLineById(id: Int): Long {
        val host = when (id) {
            1 -> DIRECT
            3 -> FASTLINE
            else -> BASE
        }
        val t0 = System.currentTimeMillis()
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(host + "/v1/app/config").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 3000
                readTimeout = 3000
            }
            conn.responseCode
            val dt = System.currentTimeMillis() - t0
            if (dt >= 3000) -1L else dt
        } catch (e: Exception) {
            -1L
        } finally {
            runCatching { conn?.disconnect() }
        }
    }

''' + anchor
    assert anchor in s
    s = s.replace(anchor, add, 1)

# lines()：加第四条（id=3 新线路，可对话）
old2 = '''    fun lines(): List<Line> = listOf(
        Line(0, com.aevis.android.core.I18n.tr("北京"), com.aevis.android.core.I18n.tr("图片加速"), false),
        Line(1, com.aevis.android.core.I18n.tr("直连"), com.aevis.android.core.I18n.tr("主力线路"), true),
        Line(2, com.aevis.android.core.I18n.tr("香港"), com.aevis.android.core.I18n.tr("备用线路"), true)
    )'''
new2 = '''    fun lines(): List<Line> = listOf(
        Line(0, com.aevis.android.core.I18n.tr("北京"), com.aevis.android.core.I18n.tr("图片加速"), false),
        Line(1, com.aevis.android.core.I18n.tr("直连"), com.aevis.android.core.I18n.tr("主力线路"), true),
        Line(2, com.aevis.android.core.I18n.tr("香港"), com.aevis.android.core.I18n.tr("备用线路"), true),
        // 105：新线路（隧道反代），实测 0.2s 左右，最快的一条
        Line(3, com.aevis.android.core.I18n.tr("加速"), com.aevis.android.core.I18n.tr("推荐线路"), true)
    )'''
assert old2 in s, 'lines anchor missing'
s = s.replace(old2, new2, 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('pingLineById + Line(3) added')

# ---------- keep 规则（minify 已开，补反射/JSON） ----------
p2 = base.replace('java/com/aevis/android/', '') + 'proguard-rules.pro'
s2 = io.open(p2, encoding='utf-8').read()
if 'kotlinx.serialization' not in s2:
    s2 += '''
# ---------------- 105：minifyEnabled/shrinkResources 已开，补齐反射相关 ----------------
# org.json：Api 全量用它解析返回，R8 会把 JSONObject/JSONArray 的方法名改掉导致 NoSuchMethod
-keep class org.json.** { *; }
-dontwarn org.json.**
# kotlinx.serialization（如果以后引）
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
# Api 里的 DTO（data class 靠字段名反射成 JSON）
-keep class com.aevis.android.data.** { *; }
# Compose 反射（Preview/反射调用）
-dontwarn androidx.compose.**
'''
    io.open(p2, 'w', encoding='utf-8', newline='\n').write(s2)
    print('keep rules appended')
