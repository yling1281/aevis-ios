// JNI 桥：把共享 C++ 核心暴露给 Kotlin（2026-11-13）
#include <jni.h>

#include <string>

#include "aevis_core.h"

namespace {

std::string to_std(JNIEnv* env, jstring s) {
    if (!s) return std::string();
    const char* p = env->GetStringUTFChars(s, nullptr);
    std::string out = p ? p : "";
    if (p) env->ReleaseStringUTFChars(s, p);
    return out;
}

jstring to_java(JNIEnv* env, const char* s) {
    return env->NewStringUTF(s ? s : "");
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_aevis_android_core_NativeCore_version(JNIEnv* env, jobject) {
    return to_java(env, aevis_core_version());
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_aevis_android_core_NativeCore_apiBase(JNIEnv* env, jobject) {
    return to_java(env, aevis_api_base());
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_aevis_android_core_NativeCore_formatPoints(JNIEnv* env, jobject, jlong value) {
    char buf[40];
    if (aevis_format_points(static_cast<long long>(value), buf, sizeof(buf)) < 0) {
        return to_java(env, "0");
    }
    return to_java(env, buf);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_aevis_android_core_NativeCore_normalizeAccount(JNIEnv* env, jobject, jstring raw) {
    std::string in = to_std(env, raw);
    char buf[256];
    if (aevis_normalize_account(in.c_str(), buf, sizeof(buf)) < 0) {
        return to_java(env, "");
    }
    return to_java(env, buf);
}
