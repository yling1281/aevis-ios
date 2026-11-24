# 侧载包，暂无额外规则；Compose / Material3 的规则随 AAR 自带


# ---------------- 105：minifyEnabled/shrinkResources 已开，补齐反射相关 ----------------
# org.json：Api 全量用它解析返回，R8 改掉方法名会 NoSuchMethod
-keep class org.json.** { *; }
-dontwarn org.json.**
-keepattributes *Annotation*, InnerClasses
-keep class com.aevis.android.data.** { *; }
-dontwarn androidx.compose.**

# Class.forName 反射入口（AeviService）
-keep class com.aevis.android.MainActivity { *; }
