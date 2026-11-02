package com.aevis.app.ui.v2

import androidx.compose.ui.window.ComposeUIViewController
import platform.UIKit.UIViewController

// iOS 侧的入口：Swift 通过 PaperRootControllerKt.PaperRootController() 拿到它，
// 塞进 UIViewControllerRepresentable 就是整个 Paper UI。
fun PaperRootController(): UIViewController = ComposeUIViewController { PaperRoot() }
