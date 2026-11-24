package com.aevis.android.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.aevis.android.MainActivity
import com.aevis.android.R
import com.aevis.android.data.Api
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.random.Random

/**
 * 后台陪伴服务（2026-11-15）。
 *
 * 用户：「开后台的那个保存比较好的，就那个电量的那个」——
 * 要的是「App 退到后台也别被杀，能不定时收到它发来的消息」。
 *
 * **为什么用前台服务**：安卓上唯一比较稳的保活手段。
 * 普通后台进程会被系统随时回收（国产 ROM 更激进），
 * 只有前台服务 + 常驻通知能长期活着。代价是状态栏有一条常驻通知。
 *
 * 配合三件事一起用才有效（都在设置页引导）：
 *   ① 忽略电池优化（`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`）
 *   ② 允许自启动（华为/小米/OPPO 各自的设置页）
 *   ③ 通知权限
 *
 * **不定时**：40–90 分钟随机间隔，不用固定周期。固定周期会有「准点报时」的机械感，
 * 随机才像真人想起来找你说话。
 */
class ProactiveService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val handler = Handler(Looper.getMainLooper())
    private var running = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!running) {
            running = true
            // Android 14+ 必须声明前台服务类型，否则 startForeground 直接抛异常
            startForeground(NOTI_ID_SERVICE, buildServiceNotification())
            scheduleNext()
        }
        // START_STICKY：被系统杀了以后尽量拉回来
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    // ---------------- 调度 ----------------

    /** 排下一次。间隔 40–90 分钟随机。*/
    private fun scheduleNext() {
        val minutes = Random.nextInt(40, 91)
        handler.postDelayed({
            if (running) {
                tick()
                scheduleNext()
            }
        }, minutes * 60_000L)
    }

    /** 到点了：挑一个聊过的人，让它主动说一句话，弹通知。*/
    private fun tick() {
        scope.launch {
            runCatching {
                // 只是提醒，不打扰：用户锁屏/省电模式下也照发（我们自己判断不了，交给系统）
                val persons = Api.personas()
                if (persons.isEmpty()) return@runCatching

                // 挑「最近聊过」的那个 —— 有记录的优先，都没记录就随机
                val withConv = persons.filter { Api.loadConv(it.id).isNotEmpty() }
                val target = (withConv.ifEmpty { persons }).random()
                val history = Api.loadConv(target.id)

                val prompt = buildString {
                    append("你叫${target.name}。")
                    if (history.isNotEmpty()) {
                        append("你们刚才聊过：")
                        append(history.takeLast(6).joinToString("；") { it.content.take(40) })
                        append("。")
                    }
                    append("现在你想主动找对方说一句话，一句话就行，20 字以内，")
                    append("自然、口语、不要问「在吗」，不要解释为什么找他。只输出这句话。")
                }

                val line = Api.chat(
                    model = "deepseek-flash",
                    history = listOf(Api.Msg("user", prompt)),
                    systemPrompt = ""
                )?.trim()?.lines()?.firstOrNull()?.trim()
                    ?.removeSurrounding("\"")?.removeSurrounding("「", "」")
                    ?.removeSurrounding("“", "”")
                    ?: return@runCatching

                if (line.isBlank() || line.length > 60) return@runCatching

                // 存进会话（打开 App 就能看到这句）
                val conv = history + Api.Msg("assistant", line)
                Api.saveConv(target.id, conv)

                notifyProactive(target.id, target.name, line)
            }
        }
    }

    // ---------------- 通知 ----------------

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            // 常驻那条：静音、不打扰
            nm.createNotificationChannel(
                NotificationChannel(
                    CH_SERVICE, "后台陪伴", NotificationManager.IMPORTANCE_MIN
                ).apply {
                    setShowBadge(false)
                    description = "让它在后台也能找你说话"
                }
            )
            // 主动消息：正常优先级，有声音
            nm.createNotificationChannel(
                NotificationChannel(
                    CH_MSG, "它来找你", NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "AI 主动发来的消息"
                }
            )
        }
    }

    private fun buildServiceNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CH_SERVICE)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Aevis")
            .setContentText("在后台陪着你")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .build()
    }

    private fun notifyProactive(pid: String, name: String, text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        val open = PendingIntent.getActivity(
            this, pid.hashCode(),
            Intent(this, MainActivity::class.java)
                .putExtra(EXTRA_PID, pid)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val n = NotificationCompat.Builder(this, CH_MSG)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(name)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(open)
            .build()
        runCatching { nm.notify(pid.hashCode(), n) }
    }

    companion object {
        const val CH_SERVICE = "aevis_bg_service"
        const val CH_MSG = "aevis_proactive"
        const val NOTI_ID_SERVICE = 9001
        const val EXTRA_PID = "open_pid"
        private const val PREF = "aevis_bg"
        private const val KEY_ON = "on"

        fun isOn(ctx: Context): Boolean =
            ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).getBoolean(KEY_ON, false)

        fun setOn(ctx: Context, on: Boolean) {
            ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_ON, on).apply()
            val i = Intent(ctx, ProactiveService::class.java)
            if (on) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
                else ctx.startService(i)
            } else {
                ctx.stopService(i)
            }
        }

        fun isIgnoringBattery(ctx: Context): Boolean = runCatching {
            (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .isIgnoringBatteryOptimizations(ctx.packageName)
        }.getOrDefault(false)
    }
}
