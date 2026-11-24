package com.aevis.android.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.hardware.Camera
import android.os.Bundle
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 原生扫一扫（2026-11-13）
 *
 * 用户要「APP 里扫码做原生的」。没有引 CameraX / ML Kit 那一整套，
 * 只用系统自带的 `android.hardware.Camera` + zxing 的解码核心（约 500KB）。
 *
 * 识别成功后把内容放在 `Intent.getStringExtra("code")` 里返回，
 * 由调用方（MainActivity）解析票号并弹确认框。
 */
class CameraScanActivity : Activity(), SurfaceHolder.Callback, Camera.PreviewCallback {

    private var camera: Camera? = null
    private var preview: SurfaceView? = null
    private val reader = MultiFormatReader()
    private val working = AtomicBoolean(false)
    private var finished = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = FrameLayout(this)
        root.setBackgroundColor(Color.BLACK)

        val surface = SurfaceView(this)
        root.addView(surface, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        preview = surface
        surface.holder.addCallback(this)

        // 顶部提示 + 关闭
        val tip = TextView(this)
        tip.text = "对准电脑上的登录二维码"
        tip.setTextColor(Color.WHITE)
        tip.textSize = 14f
        tip.gravity = Gravity.CENTER
        val lp = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        lp.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        lp.topMargin = 160
        root.addView(tip, lp)

        setContentView(root)

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), REQ_CAM)
        }
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, perms, results)
        if (code != REQ_CAM) return
        if (results.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        // 🔴 2026-11-14 修：首次进来时 `surfaceCreated` 早就在权限弹窗**之前**跑完了，
        //    用户点「允许」之后系统**不会再回调一次** surfaceCreated，
        //    于是相机永远不打开 —— 表现就是「扫一扫一片黑，用不了」。
        //    授权成功的这一刻，如果 surface 已经准备好，就补一次 openCamera。
        val holder = preview?.holder
        if (holder != null && holder.surface != null) {
            openCamera(holder)
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        openCamera(holder)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // 2026-11-14 用户：「扫码变畸形了」——
        // Camera1 的默认预览常常是 640x480（4:3），塞进 20:9 的全屏 SurfaceView
        // 就会被硬拉成一条——画面是歪的，码也扫不出来。
        // 这里把 SurfaceView 的**高度**按预览的真实宽高比算出来，超出的部分裁掉，
        // 视觉上是"填满屏幕"，但比例是真的。
        val pv = runCatching { camera?.parameters?.previewSize }.getOrNull()
        val sv = preview
        if (pv != null && sv != null && pv.width > 0 && pv.height > 0) {
            val screenW = resources.displayMetrics.widthPixels
            // ⚠️ 竖屏 + setDisplayOrientation(90) 之后，屏幕上看到的高度对应
            //    预览的**宽度**，所以比例是 pv.width / pv.height。
            //    上一次这里写反了（pv.height / pv.width），叠加上没转的 90°，
            //    就成了用户看到的"畸形"。
            val shownH = (screenW * pv.width.toFloat() / pv.height).toInt()
            sv.layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                maxOf(shownH, resources.displayMetrics.heightPixels),
                Gravity.CENTER
            )
        }
        camera?.startPreview()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        releaseCamera()
    }

    private fun openCamera(holder: SurfaceHolder) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) return
        try {
            val cam = Camera.open() ?: return
            camera = cam
            cam.setPreviewDisplay(holder)
            // 连续对焦：二维码在屏幕上通常不大，定焦容易糊
            val params = cam.parameters
            // 挑预览尺寸：优先接近 16:9 且不低 720p（太低解码糊，太高发热）
            runCatching {
                val sizes = params.supportedPreviewSizes ?: emptyList()
                var pick: Camera.Size? = null
                var best = Double.MAX_VALUE
                for (sz in sizes) {
                    if (sz.width < 720) continue
                    val ratio = sz.width.toDouble() / sz.height
                    val score = Math.abs(ratio - 16.0 / 9.0) * 20.0 +
                        Math.abs(sz.width - 1280) / 200.0
                    if (score < best) { best = score; pick = sz }
                }
                val chosen = pick
                if (chosen != null) params.setPreviewSize(chosen.width, chosen.height)
            }
            val modes = params.supportedFocusModes
            if (modes != null && modes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)) {
                params.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE
            }
            cam.parameters = params

            // 🔴 2026-11-15 用户：「扫码你变畸形了」——
            //    真机一看根本不是拉伸，是**整个画面躺倒了 90 度**。
            //    Camera1 的传感器是横向的，竖屏 App 不显式转就会这样。
            //    这里按官方推荐算法算：后置 = (传感器角度 - 屏幕旋转 + 360) % 360。
            //    （Activity 锁了 portrait，屏幕旋转恒为 0，所以结果就是传感器角度，
            //      但保留完整公式，以后放开横屏也不会错。）
            runCatching {
                val info = Camera.CameraInfo()
                Camera.getCameraInfo(0, info)
                val deg = when (windowManager.defaultDisplay.rotation) {
                    android.view.Surface.ROTATION_0 -> 0
                    android.view.Surface.ROTATION_90 -> 90
                    android.view.Surface.ROTATION_180 -> 180
                    android.view.Surface.ROTATION_270 -> 270
                    else -> 0
                }
                val result = if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) {
                    val r = (info.orientation + deg) % 360
                    (360 - r) % 360
                } else {
                    (info.orientation - deg + 360) % 360
                }
                cam.setDisplayOrientation(result)
            }
            cam.setPreviewCallback(this)
            cam.startPreview()
        } catch (e: Exception) {
            // 不再静默退出：说清楚打不开相机，比"点了没反应"强
            failWith("相机打不开：" + (e.message ?: "被系统占用了"))
        }
    }

    private fun failWith(msg: String) {
        try {
            val tv = TextView(this)
            tv.text = msg
            tv.setTextColor(Color.WHITE)
            tv.textSize = 15f
            tv.gravity = Gravity.CENTER
            tv.setPadding(60, 0, 60, 0)
            (window.decorView as? FrameLayout)?.addView(tv, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        } catch (_: Exception) {
        }
    }

    private fun releaseCamera() {
        val cam = camera ?: return
        camera = null
        try {
            cam.setPreviewCallback(null)
            cam.stopPreview()
        } catch (_: Exception) {
        }
        try { cam.release() } catch (_: Exception) {}
    }

    override fun onPreviewFrame(data: ByteArray?, cam: Camera?) {
        if (data == null || cam == null || finished) return
        // 只允许一帧在处理，否则解码跟不上回调速度会把 CPU 打满
        if (!working.compareAndSet(false, true)) return

        val w = cam.parameters.previewSize.width
        val h = cam.parameters.previewSize.height
        try {
            val source = PlanarYUVLuminanceSource(data, w, h, 0, 0, w, h, false)
            val bitmap = BinaryBitmap(HybridBinarizer(source))
            val hints = mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true
            )
            reader.setHints(hints)
            val result = try {
                reader.decodeWithState(bitmap)
            } catch (e: Exception) {
                null
            } finally {
                reader.reset()
            }
            if (result != null && !finished) {
                finished = true
                runOnUiThread {
                    setResult(RESULT_OK, Intent().putExtra("code", result.text))
                    finish()
                }
            }
        } finally {
            working.set(false)
        }
    }

    override fun onPause() {
        super.onPause()
        releaseCamera()
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseCamera()
    }

    companion object {
        private const val REQ_CAM = 0x5A11
    }
}
