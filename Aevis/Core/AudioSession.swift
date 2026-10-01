import AVFoundation

/// 全进程**只有一个** `AVAudioSession`，而这个项目里有五处会去动它。
/// 规矩是「谁最后 `setCategory` 谁说了算」，先动的人**收不到任何通知**。
///
/// ## 它为什么会把「锁屏 / 灵动岛的播放控件」弄丢
///
/// 用户原话（2026-09-30）：「播放可以了，但是我去后台的时候系统的灵动岛上面
/// 和播放音乐圈没有」。歌明明在放，一进后台锁屏上那一圈播放控件却是空的。
///
/// 原因不在界面，在**系统认不认"这台 App 就是当前在放声音的那个"**。
/// 而认不认只看两件事（苹果没写在显眼处，社区反复验证过）：
///
/// 1. **类别里有没有 `.mixWithOthers` / `.duckOthers`。**
///    这两个选项都意味着「我不独占音频通道」，系统于是**不可能**把锁屏那套
///    让给你 —— `MPNowPlayingInfoCenter` 全系统只有一个，混音状态下它不知道
///    该显示谁的。所以音乐这一类**必须**是 `.playback` + `options: []`。
///    ⚠️ 我们原来三处（音乐、TTS、静音保活）全带着 `.mixWithOthers`。
/// 2. **会话有没有真的 `setActive(true)`。** 没激活，控件同样不出来。
///
/// ## 那说话 / 录音怎么办
/// 它们**必须**换类别：念东西要 `.spokenAudio`、开麦克风要 `.playAndRecord`。
/// 一换，系统就不认音乐了。所以这里的规矩是：
/// **谁借走，谁还回来** —— 念完 / 听完，只要音乐还在放，就把类别原样还成
/// `.playback`（不带任何选项）。
///
/// 这也是 `MusicPlayer` 每次起停都要来报一声的原因：
/// 有了 `musicPlaying` 这个标志，"借走的那位要不要还"就不用去
/// `@MainActor` 上问播放器 —— 那些借用方大多不在主线程上。
enum AudioSession {

    // MARK: - 音乐：这条通道的主人

    /// 音乐现在是不是在放。**只有 `MusicPlayer` 该动它。**
    static private(set) var musicPlaying = false

    static func setMusicPlaying(_ playing: Bool) {
        musicPlaying = playing
        if playing { activateForPlayback() }
    }

    /// 把会话摆成「音乐播放」该有的样子。幂等，随时可以调。
    ///
    /// ⚠️ `options: []` 是**故意的，不是漏写** —— 见文件开头第 1 条。
    ///    改成 `.mixWithOthers` 就等于把锁屏控件关掉（这是这个文件存在的理由）。
    static func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    /// 回到前台时补一次。
    ///
    /// 系统的音频会话会被一堆东西改掉（来电、Siri、插拔耳机、我们自己的 TTS），
    /// 回到前台不补，那圈控件就会一直缺着 —— 而用户看到的是"刚才还有呢"。
    static func reassertIfPlaying() {
        guard musicPlaying else { return }
        activateForPlayback()
    }

    // MARK: - 借用（说话 / 录音）

    /// 谁正在借用会话。两个都空下来，才把类别还给音乐。
    ///
    /// 用明确的两个布尔而不是一个计数器：计数器漏减一次就**永远还不回去**
    /// （表现是"说过一次话之后锁屏控件再也不出现"），布尔漏掉最多是多还一次。
    static private(set) var speechActive = false
    static private(set) var recordActive = false

    static func beginSpeech() {
        speechActive = true

        // ⚠️ 通话中念话**不能**走 `.playback`：
        //    ① `.playback` 的输出**一定**是外放 —— 通话选了听筒也会被她一句
        //       话甩回喇叭上；
        //    ② 它会顺手把刚开着的麦克风收走，而通话里我们正靠它收着你的话。
        //    所以通话里改用 `.playAndRecord`（就是录音那一套），
        //    路由交给下面的 `applyCallOutputPort()` 决定。
        if inCall {
            applyCallCategory()
            return
        }

        let session = AVAudioSession.sharedInstance()
        // ⚠️ 音乐在放的时候**不加 `.duckOthers`**：它同样会让系统不认我们的
        //    「当前播放」身份（锁屏控件当场消失）。而且它压的是**别的 App**，
        //    对我们自己的歌一点用都没有 —— 加了纯粹是白丢控件。
        let options: AVAudioSession.CategoryOptions = musicPlaying ? [] : [.duckOthers]
        try? session.setCategory(.playback, mode: .spokenAudio, options: options)
        try? session.setActive(true)
    }

    static func endSpeech() {
        speechActive = false
        restoreIfIdle()
    }

    static func beginRecord() {
        recordActive = true
    }

    static func endRecord() {
        recordActive = false
        restoreIfIdle()
    }

    /// 两个借用方都放手了，就把会话还给**现在这条通道的主人**。
    private static func restoreIfIdle() {
        guard !speechActive, !recordActive else { return }
        if musicPlaying {
            activateForPlayback()
        } else if inCall {
            // 通话里不能"还回音乐" —— 现在的主人就是通话。
            // 类别摆回录音那一套（免提/听筒的选择一起带上）：
            // 退回 `.playback` 那一下会把声音甩到外放上，听筒模式会"跳"一声。
            applyCallCategory()
        } else {
            // 没有音乐在放 —— 也要把 `mode` 抹回 `.default`。
            // ⚠️ `mode` 是**粘的**：`.spokenAudio` 留在那儿，下次放歌系统会按
            //    "有声书"那套来画界面，锁屏上出现的可能是快退 15 秒。
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [])
        }
    }

    // MARK: - 通话（免提 / 听筒）
    //
    // 用户 2026-10-01：「第三个的话呢，可以加点功能」—— 通话页上要能切免提。
    //
    // 路由这件事**只有这个文件说了算**（会话是全进程唯一的），
    // 所以通话页只改这里的两个标志，别的地方一律不碰 `AVAudioSession`。

    /// 通话是不是正在进行。**只有 `CallService` 该动它。**
    static var inCall = false

    /// 通话走外放（免提）。关掉就走听筒。
    static var callSpeakerOn = true

    /// 通话录音那一套要用的选项。
    ///
    /// ⚠️ `.defaultToSpeaker` 只在**通话中且选了外放**时才带上 ——
    ///    一起听、语音消息这些场景永远该走外放，被"听筒"带到耳朵边上就莫名其妙了。
    static var callRecordOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.duckOthers, .allowBluetoothHFP]
        if !inCall || callSpeakerOn { options.insert(.defaultToSpeaker) }
        return options
    }

    /// 把输出口按当前选择摆一遍。切免提时立刻生效，**不用重开会话**。
    ///
    /// ⚠️ 它比类别里的 `.defaultToSpeaker` **优先级更高** ——
    ///    所以"听筒"这一档必须靠它，光去掉选项是不够的。
    static func applyCallOutputPort() {
        let session = AVAudioSession.sharedInstance()
        guard inCall else {
            // 通话结束：把上一次的"强制外放"撤掉，交还给系统按耳机/蓝牙自己挑。
            try? session.overrideOutputAudioPort(.none)
            return
        }
        try? session.overrideOutputAudioPort(callSpeakerOn ? .speaker : .none)
    }

    /// 把会话摆成"通话中"该有的样子（录音 + 按选择决定外放还是听筒）。
    static func applyCallCategory() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: callRecordOptions)
        try? session.setActive(true)
        applyCallOutputPort()
    }

    // MARK: - 静音保活

    /// QQ 保活的静音播放，现在能不能动类别。
    ///
    /// 音乐在放的时候**不能** —— 保活要的是 `.mixWithOthers`（一组静音而已，
    /// 不该抢别人的音频），而那正好会把音乐的锁屏控件弄丢。
    /// 静音本身不需要额外配置：会话已经是 `.playback` 而且活着，
    /// 它的 `AVAudioPlayer` 照放不误。
    static var silenceNeedsOwnCategory: Bool { !musicPlaying }
}
