import SwiftUI

#if canImport(ReplayKit)
import ReplayKit
#endif

/// 系统的「开始录屏」控件。
///
/// 为什么非得用它：**iOS 不允许 App 自己开录屏** —— 必须用户自己点，
/// 状态栏会亮一个红点（这是系统给用户的安全提示，绕不过去）。
/// `RPSystemBroadcastPickerView` 是系统给的唯一入口，点一下会弹出
/// 「用哪个扩展来录」，选 Aevis 录屏就开始了。所有录屏直播类 App 都这么做。
///
/// 系统控件自带的样子（一个录屏图标）跟我们的玻璃按钮不搭，所以把它的图藏掉、
/// 只留一块可点区域，上面盖我们自己的样式。
struct BroadcastPicker: UIViewRepresentable {

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 220, height: 44)
        )
        // 告诉系统「默认用我们这个扩展」，省得用户在一堆扩展里找
        view.preferredExtension = ScreenShareStore.extensionBundleID
        // 不要麦克风按钮 —— 我们只认屏幕上的字，录声音会跟通话/听歌抢音频
        view.showsMicrophoneButton = false

        for subview in view.subviews {
            guard let button = subview as? UIButton else { continue }
            button.setImage(nil, for: .normal)
            button.imageView?.alpha = 0
            button.setTitle(nil, for: .normal)
        }
        return view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// 摆成我们自己的样子。
///
/// ⚠️ 那个 `.opacity(0.02)` **不能改成 0** —— 透明度低于 0.01 时
/// UIKit 会认为这个视图不该接收点击，按钮就点不动了。
struct BroadcastStartButton: View {
    var width: CGFloat = 220

    var body: some View {
        ZStack {
            BroadcastPicker()
                .frame(width: width, height: 44)
                .opacity(0.02)

            HStack(spacing: 7) {
                Image(systemName: "record.circle")
                    .font(.aevis(15, weight: .medium))
                Text("开始录屏")
                    .font(.aevis(14.5, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(width: width, height: 44)
            .aevisGlass(cornerRadius: 14)
            // 让点击穿透到底下那个系统控件
            .allowsHitTesting(false)
        }
        .frame(width: width, height: 44)
    }
}
