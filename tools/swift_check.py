#!/usr/bin/env python3
"""本地检查 Swift 源码 —— 把「我已经犯过的那几类错」自动挑出来。

在 Windows 上跑不了 iOS 代码，所以用静态检查兜住最容易出事的几类问题。
每条规则都对应一个**真实发生过的 bug**，不是凭空想的：

  R1  非 ASCII 乱码（U+FFFD）           → 曾经把「还差一步」写成乱码推上去过
  R2  括号不配平                         → 编译才会发现，本地先拦
  R3  scaledToFill 没有 Color.clear 兜底 → 撑大整棵布局，把底部输入栏挤出屏幕
  R4  同一 HStack 里两个以上 Spacer      → 剩余空白被平分，气泡飘到屏幕中间
  R5  NSExpression(format:               → 畸形表达式会抛 ObjC 异常直接崩
  R6  用了 EventKit 但 Info.plist 缺权限 → 一调用就崩（不是弹窗失败）
  R7  文件用了 .aevis( 却还残留 .font(.system(size:  → 用户换字体时那一处不跟着变
  R8  X.shared 引用的类型没定义          → 编译错误，本地先发现
  R9  调用自定义类型/方法但项目里没有定义
  R20 一行里的双引号是奇数个              → 字符串被拦腰截断，后半截变成代码
  R24 对**可选**属性直接接 `.isEmpty` 之类  → 编译错误（build-44 就挂在它上）
  R25 `Keychain.set(x, forKey:)` 标签写错     → 编译错误（build-50）
  R26 UIKit 的 `UIImage` 直接 `.resizable()`  → 编译错误（build-53 挂在两句上）
  R27 三元里 `? .secondary : .orange`        → 编译错误（build-54 挂在它上）
  R29 ObservableObject 的 async 方法里改 @Published 却没 @MainActor
                                              → 后台线程改 @Published，**iOS 26 硬崩**
                                                （真机诊断 AE-155A-91FC；MusicPlayer 那次也是它）
  R33 `.overlay` 里放了填充形状/颜色却没加 .allowsHitTesting(false)
                                              → 这层盖在内容**上面**、又参与命中测试，
                                                把整张卡片的点击/长按/滚动全吃掉
                                                （0.0.110 整机所有按钮点不动、协议划不动）

（R10–R19 的由来写在各自函数的 docstring 里，这里只列最先立起来的那批。）

用法:
    python3 tools/swift_check.py            # 检查 Aevis/ 目录
    python3 tools/swift_check.py --selftest # 只跑各条规则自带的自测（含 R33）
"""

import os
import plistlib
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Aevis")
INFO_PLIST = os.path.join(ROOT, "Resources", "Info.plist")
PROJECT = os.path.dirname(ROOT)

# 除了主 App，还要扫别的 target 的源码。
# 它们虽然各自是独立 target，但一样是 Swift、一样会编不过 ——
# 漏掉等于漏一半，而且往往是更难在真机上调试的那一半。
#
# ⚠️ 2026-09-26 扩到全部：原来只有主 App + 录屏扩展，
#    管理端（AevisAdmin）和 VPN 探针（AevisVPNProbe）**一个文件都没被扫到** ——
#    它们恰恰是"改完没被检查过就推上去"的那种代码。
SWIFT_ROOTS = [
    ROOT,
    os.path.join(PROJECT, "Broadcast"),
    os.path.join(PROJECT, "AevisAdmin"),
    os.path.join(PROJECT, "AevisVPNProbe", "App"),
    os.path.join(PROJECT, "AevisVPNProbe", "Tunnel"),
    # 通话探针（2026-10-01）。**必须加进来** —— 它也是一份独立源码，
    # 不进这里就等于"没人检查"，而它要验的又是最要紧的通话权限。
    os.path.join(PROJECT, "AevisCallProbe", "App"),
    # 实时活动扩件（2026-10-01）。同样是独立源码、一样要过 CI 编译 ——
    # 它画的是灵动岛上那张卡，错了用户直接看不见，本地先扫一遍。
    os.path.join(PROJECT, "AevisLive"),
    # 两个**新的独立 App**（2026-10-07）：手机状态上报（AevisStatus）/
    # 仿苹果真来电界面（AevisCall）。它们各自是独立 target、一样过 CI 编译，
    # 不进这里就等于"没人检查" —— 而这两个包偏偏是老板真机上要跑的。
    os.path.join(PROJECT, "AevisStatus", "App"),
    os.path.join(PROJECT, "AevisCall", "App"),
]

# 每个 target 的 Info.plist 都要验。
# 扩展那份写错一个键，表现是「系统录屏列表里根本没有 Aevis」——
# 编译能过、装也装得上、界面上不报任何错，属于最难查的一类。
INFO_PLISTS = {
    INFO_PLIST: "Aevis",
    os.path.join(PROJECT, "Broadcast", "Info.plist"): "AevisBroadcast",
    # 实时活动扩件那份。注册点写错同样是**静默失效**（编译能过、装得上，
    # 但灵动岛上永远不出现），所以一并解一遍，确保它是合法 plist。
    os.path.join(PROJECT, "AevisLive", "Info.plist"): "AevisLive",
    # 两个新独立 App 的 Info.plist（2026-10-07）。格式错一个字符，
    # `xcodebuild` 就会在构建日志深处失败，本地先用 plistlib 解一遍。
    os.path.join(PROJECT, "AevisStatus", "App", "Info.plist"): "AevisStatus",
    os.path.join(PROJECT, "AevisCall", "App", "Info.plist"): "AevisCall",
}

# 主 App 与扩展的权限声明文件。两份必须声明**同一个**应用组。
ENTITLEMENTS = {
    "app": os.path.join(ROOT, "Aevis.entitlements"),
    "extension": os.path.join(PROJECT, "Broadcast", "AevisBroadcast.entitlements"),
}

# 用了对应框架就必须在 Info.plist 里有的键 —— 缺了一调用就崩（不是弹窗失败）
REQUIRED_PERMISSIONS = {
    "NSCalendarsFullAccessUsageDescription": "EventKit",
    "NSRemindersFullAccessUsageDescription": "EventKit",
    "NSMicrophoneUsageDescription": "AVAudioEngine",
    "NSSpeechRecognitionUsageDescription": "SFSpeechRecognizer",
    "NSCameraUsageDescription": "UIImagePickerController",
    "NSLocationWhenInUseUsageDescription": "CLLocationManager",
    "NSHealthShareUsageDescription": "HKHealthStore",
}

# 系统录屏扩展的注册点。写错它，扩展就永远不会出现在系统列表里。
BROADCAST_EXTENSION_POINT = "com.apple.broadcast-services-upload"

STORE_PATH = os.path.join(ROOT, "Core", "ScreenShareStore.swift")

# 苹果系统类型：它们的 .shared 不是我们定义的，检查时要放过，
# 否则一堆误报会让人把检查器整个无视掉，那就等于没有。
SYSTEM_TYPES = {
    "UIApplication", "URLSession", "FileManager", "NotificationCenter",
    "UserDefaults", "UNUserNotificationCenter", "UIPasteboard", "UIDevice",
    "UIScreen", "AVAudioSession", "AVSpeechSynthesizer", "AVAudioPlayer",
    "EKEventStore", "NSFileManager", "WKWebView", "CLLocationManager",
    "HKHealthStore", "Locale", "TimeZone", "Calendar",
    "MPRemoteCommandCenter", "MPNowPlayingInfoCenter", "MPMediaLibrary",
    "AVAudioEngine", "AVAudioRecorder", "PHPhotoLibrary", "CNContactStore",
    "RPScreenRecorder", "SFSpeechRecognizer", "AVAudioApplication",
}

problems = []
notes = []


def report(rule, path, line, message):
    rel = os.path.relpath(path, os.path.dirname(ROOT))
    problems.append((rule, rel, line, message))


def strip_code(source):
    """把字符串和注释替换成空格，避免误判括号与关键字。"""
    out = []
    i = 0
    n = len(source)
    while i < n:
        ch = source[i]
        if ch == "#" and i + 1 < n and source[i + 1] in ('"', "#"):
            # Swift 的原始字符串 #"..."# / ##"..."##。
            # 正则里括号很多，不认这种写法就会把它们当成代码，误报括号不配平。
            hashes = 0
            while i + hashes < n and source[i + hashes] == "#":
                hashes += 1
            if i + hashes < n and source[i + hashes] == '"':
                delimiter = "#" * hashes
                out.append(delimiter)
                out.append('"')
                i += hashes + 1
                terminator = '"' + delimiter
                while i < n and not source.startswith(terminator, i):
                    out.append("\n" if source[i] == "\n" else " ")
                    i += 1
                out.append(terminator)
                i += len(terminator)
            else:
                out.append(ch)
                i += 1
        elif ch == "/" and i + 1 < n and source[i + 1] == "/":
            while i < n and source[i] != "\n":
                out.append(" ")
                i += 1
        elif ch == "/" and i + 1 < n and source[i + 1] == "*":
            while i < n and not (source[i] == "*" and i + 1 < n and source[i + 1] == "/"):
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            out.append("  ")
            i += 2
        elif ch == '"':
            out.append('"')
            i += 1
            while i < n and source[i] != '"':
                if source[i] == "\\":
                    out.append("  ")
                    i += 2
                    continue
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            out.append('"')
            i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def swift_files():
    for root in SWIFT_ROOTS:
        if not os.path.isdir(root):
            continue
        for base, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in ("Resources", ".git")]
            for name in sorted(files):
                if name.endswith(".swift"):
                    yield os.path.join(base, name)


def read_swift_sources():
    """把所有要扫的 Swift 源码拼成一大段（给「用了某框架吗」这类判断用）。"""
    out = ""
    for root in SWIFT_ROOTS:
        if not os.path.isdir(root):
            continue
        for base, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in ("Resources", ".git")]
            for name in sorted(files):
                if name.endswith(".swift"):
                    with open(os.path.join(base, name), encoding="utf-8") as handle:
                        out += handle.read()
    return out


def check_balance(path, source, code):
    for open_ch, close_ch, label in [("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")]:
        depth = code.count(open_ch) - code.count(close_ch)
        if depth != 0:
            report("R2", path, 0, "%s不配平（差 %d）" % (label, depth))


def check_garbage(path, source):
    for number, line in enumerate(source.splitlines(), 1):
        if "\ufffd" in line:
            report("R1", path, number, "出现乱码字符 U+FFFD：%s" % line.strip()[:40])


def check_scaled_to_fill(path, code):
    """填充式图片没有尺寸兜底 → 会把整棵布局撑大，把底部输入栏挤出屏幕。
    这是真发生过的 bug：背景图用 scaledToFill 直接放进 ZStack。

    但**下面两种是安全的，必须放过**，否则规则会天天误报、被无视：
    1. 同一段里紧跟 `.frame(width:/height:)` 或 `.clipShape(` —— 尺寸被定住了
    2. `scaledToFit`（等比缩放到装得下，本来就不会超出）

    注意：传进来的必须是**去掉注释与字符串**的 code ——
    否则「注释里提到 scaledToFill」也会被当成真代码报出来（真踩过）。
    """
    if "scaledToFill" not in code:
        return
    lines = code.splitlines()
    for number, line in enumerate(lines, 1):
        if "scaledToFill" not in line:
            continue
        window = "\n".join(lines[number - 1:number + 6])
        if ".frame(" in window or ".clipShape(" in window or ".clipped(" in window:
            continue
        report("R3", path, number, "填充式图片没有尺寸兜底，可能把布局撑大")


def hstack_blocks(code):
    """找出所有 HStack 的 { ... } 区间，用于精确判断「一个 HStack 里有几个 Spacer」。"""
    blocks = []
    for match in re.finditer(r"\bHStack\b[^{]*\{", code):
        start = match.end() - 1
        depth = 0
        index = start
        while index < len(code):
            if code[index] == "{":
                depth += 1
            elif code[index] == "}":
                depth -= 1
                if depth == 0:
                    blocks.append((match.start(), index))
                    break
            index += 1
    return blocks


def check_double_spacer(path, source, code):
    """只报「同一个 HStack 内部」的多个 Spacer。
    一行里放两个 Spacer 会被平分剩余空白，气泡就飘到中间去了 —— 真发生过。
    注意要按嵌套深度过滤，否则子 HStack 的 Spacer 会被算到父级头上。"""
    for start, end in hstack_blocks(code):
        depth = 0
        count = 0
        index = code.index("{", start)
        while index < end:
            if code[index] == "{":
                depth += 1
            elif code[index] == "}":
                depth -= 1
            elif depth == 1 and code.startswith("Spacer", index):
                count += 1
            index += 1
        if count >= 2:
            line = code[:start].count("\n") + 1
            report("R4", path, line, "同一个 HStack 里有 %d 个 Spacer，会被平分空白" % count)


def check_nsexpression(path, source):
    for number, line in enumerate(source.splitlines(), 1):
        if "NSExpression(format:" in line:
            report("R5", path, number, "NSExpression(format:) 遇到畸形表达式会崩，换成自己解析")


def check_eventkit_permissions(path, source):
    if "EventKit" not in source:
        return
    plist = ""
    if os.path.exists(INFO_PLIST):
        with open(INFO_PLIST, encoding="utf-8") as handle:
            plist = handle.read()
    if "requestFullAccessToEvents" in source and "NSCalendarsFullAccessUsageDescription" not in plist:
        report("R6", path, 0, "用了日历但 Info.plist 缺 NSCalendarsFullAccessUsageDescription（会崩）")
    if "requestFullAccessToReminders" in source and "NSRemindersFullAccessUsageDescription" not in plist:
        report("R6", path, 0, "用了提醒但 Info.plist 缺 NSRemindersFullAccessUsageDescription（会崩）")


def check_font_leftovers(path, code):
    """不该再有给「文字」用的 .font(.system(size:)。
    —— **这条只对买家那个 App 成立。**

    理由：它是产品要求 —— 用户在设置里换了自己导入的字体，界面必须跟着变。
    但**管理端（AevisAdmin）和 VPN 探针（AevisVPNProbe）是内部工具**，
    它们压根没有"换字体"这件事，用系统字号是**对的**。
    （2026-09-26 把 SWIFT_ROOTS 扩到全仓库后，这条规则一次报了 54 处，
      全在管理端和探针 —— 全是误报。**检查器一旦有误报就等于没有**，
      所以在这里按目标范围把它收住，而不是去改那些本来就没问题的文件。）

    这条规则原来还有个别盲点：开头写着 `if source.count(".aevis(") < 3: return` ——
    于是**一处都没接字体系统的文件反而被整个跳过**（真的漏掉了 VoiceSettingsCard，
    用户换字体时那一页的字不会跟着变）。正好漏掉最该查的那些，所以去掉了这个阈值。

    但 SF Symbol 图标用系统字号是**故意**的 —— 图标不该跟着正文字体变，要放过。
    """
    if not os.path.abspath(path).startswith(os.path.abspath(ROOT) + os.sep):
        return

    lines = code.splitlines()
    for number, line in enumerate(lines, 1):
        if ".font(.system(size:" not in line:
            continue
        # 往上找这条链的起点，看是不是图标
        is_icon = False
        for back in range(number - 1, max(-1, number - 8), -1):
            previous = lines[back - 1]
            if "Image(systemName:" in previous:
                is_icon = True
                break
            if any(token in previous for token in
                   ("Text(", "TextField(", "SecureField(", "Label(", "Button(")):
                break
        if not is_icon:
            report("R7", path, number, "这里还在用 .font(.system(size:)，换字体时不会跟着变")


def check_photos_picker_tint(path, source):
    """PhotosPicker / Menu 这类控件会把强调色刷到文字上，
    光写 .foregroundStyle(.primary) 不够，文字会变蓝 —— 截图自检时发现的。
    要求同一段里出现 .tint( 压回来。"""
    lines = source.splitlines()
    for number, line in enumerate(lines, 1):
        if "PhotosPicker(" not in line:
            continue
        window = "\n".join(lines[number - 1:number + 12])
        # 只有里面带文字标签的才需要压颜色；纯图标的不受影响
        if "Text(" not in window:
            continue
        if ".tint(" not in window:
            report("R10", path, number, "PhotosPicker 没写 .tint(，文字会被系统刷成蓝色")


def check_debug_guard(path, source):
    """读启动参数的代码必须包在 #if DEBUG 里 ——
    否则截图自检用的那些开关（-aevisDemo、-aevisOpenSettings…）会被编进正式版，
    谁在命令行里带上参数就能改你的行为。

    ⚠️ 这里按**整个文件的条件编译状态**判断，不是「往上数几行」。
    固定回看窗口有过一次真实误报：一个 `#if DEBUG` 块里塞了四个开关，
    从第四个开关往上数就够不到那一行了 —— 修过一次的东西不该再犯。
    """
    debug_stack = []
    for number, line in enumerate(source.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#if"):
            # `#if !DEBUG` 是「不是调试」，别当成调试
            in_debug = "DEBUG" in stripped and "!DEBUG" not in stripped
            debug_stack.append(in_debug)
            continue
        if stripped.startswith("#endif"):
            if debug_stack:
                debug_stack.pop()
            continue
        if "ProcessInfo.processInfo.arguments" not in line:
            continue
        if not any(debug_stack):
            report("R11", path, number, "读启动参数但没包在 #if DEBUG 里，会被编进正式版")


def check_conditional_balance(path, code):
    """`#if` 和 `#endif` 必须配对。

    少一个 #endif 是**编译硬错误**，而且 Xcode 的报错位置经常指到别的文件、
    只说「unexpected end of file」—— 六十个文件里找起来很痛苦。
    本地先拦掉，一行代价。
    """
    depth = 0
    for number, line in enumerate(code.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#if"):
            depth += 1
        elif stripped.startswith("#endif"):
            depth -= 1
            if depth < 0:
                report("R12", path, number, "#endif 多于 #if，多的这个要去掉")
                return
    if depth != 0:
        report("R12", path, 0, "#if 比 #endif 多 %d 个 —— 少了 #endif" % depth)


def _is_cjk(char):
    if not char:
        return False
    code = ord(char)
    return (
        0x4E00 <= code <= 0x9FFF      # 汉字
        or 0x3000 <= code <= 0x303F   # 中文标点
        or 0xFF00 <= code <= 0xFFEF   # 全角
    )


def strip_comments(source):
    """只去掉注释，**保留字符串里的内容**。

    为什么需要这个：乱码、漏转义的引号这类问题就藏在字符串里，
    用 `strip_code`（连字符串一起去掉）就什么都查不到了；
    但不去注释又会把「注释里写的中文引号」当成漏转义（真误报过一整屏）。
    """
    out = []
    i = 0
    n = len(source)
    in_string = False
    while i < n:
        ch = source[i]

        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue

        # 原始字符串 #"..."#：整段当字符串
        if ch == "#" and i + 1 < n and source[i + 1] == '"':
            hashes = 0
            while i + hashes < n and source[i + hashes] == "#":
                hashes += 1
            terminator = '"' + "#" * hashes
            end = source.find(terminator, i + hashes + 1)
            if end < 0:
                out.append(source[i:])
                break
            out.append(source[i:end + len(terminator)])
            i = end + len(terminator)
            continue

        if ch == "/" and i + 1 < n and source[i + 1] == "/":
            while i < n and source[i] != "\n":
                out.append(" ")
                i += 1
            continue

        if ch == "/" and i + 1 < n and source[i + 1] == "*":
            while i < n and not (source[i] == "*" and i + 1 < n and source[i + 1] == "/"):
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            out.append("  ")
            i += 2
            continue

        if ch == '"':
            in_string = True

        out.append(ch)
        i += 1
    return "".join(out)


def check_string_quote_leak(path, source):
    r"""字符串里的引号没转义，会把后面的中文漏到代码里。

    真踩过：写 `"她"看"你的屏幕"` —— 中间那两个引号把字符串截断了，
    编译器只会说「expected expression」，不会告诉你"你漏了转义"。

    判据：**ASCII 双引号的两边都紧贴中文字符**。
    加了「两边都要」这个条件之后，两种情况都不会再误报：
    - 注释里的中文引号（先去掉注释）
    - 字符串插值里的引号（`"\(x ? "甲" : "乙")"` —— 那边总有一侧是空格或括号）
    而真正的漏转义几乎一定是「中文"中文"」这个形状。
    """
    cleaned = strip_comments(source)
    lines = cleaned.splitlines()
    in_multiline = False
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith('"""') or stripped.endswith('"""'):
            in_multiline = not in_multiline
            continue
        if in_multiline:
            continue

        index = 0
        length = len(line)
        while index < length:
            if line[index] != '"':
                index += 1
                continue

            before = line[index - 1] if index > 0 else ""
            after = line[index + 1] if index + 1 < length else ""
            if _is_cjk(before) and _is_cjk(after):
                report(
                    "R13", path, number,
                    "引号两边都是中文，可能漏了转义：%s" % line.strip()[:44]
                )
                break
            index += 1


RAW_LITERAL = re.compile(r'#+"(?:.|\n)*?"#+')


def mask_raw_literals(source):
    """把 Swift 的 raw string（`#"..."#`）整段换成等量空白。

    为什么要掩掉：raw string 里**允许直接写引号**（这正是它存在的意义），
    所以 `#"<a href="([^"]+)">"#` 这种行的引号个数天然是奇数。
    不掩掉就会误报 —— 而误报会让整份检查器失去信任，那还不如没有。

    换成**等量空白**而不是占位符，是为了保住行号（行内字符数不变）。
    """
    def blank(match):
        return "".join("\n" if char == "\n" else " " for char in match.group(0))

    return RAW_LITERAL.sub(blank, source)


def check_quote_parity(path, source):
    r"""一整行里的 ASCII 双引号必须是**偶数**个（raw string 先掩掉）。

    真踩过（就在写网易云客户端的时候）：想拼一句带插值的提示，
    中间手滑多打了一对引号，那行就在插值中间多出了「三个连续引号」——
    字符串被从中间截断，后半截直接变成了代码。这类错误的特征非常好认：
    **这一行的引号个数变成了奇数**。而编译器只会在很远的地方报
    「expected expression」，根本指不到出事的那一行。

    多行字符串的定界符要跳过 —— 它的定界符行本来就可能是奇数个引号。
    但判定必须**看行首/行尾**：上面那个坏行里恰好也含连续三个引号，
    用「行内是否含三引号」去判会把它当成多行字符串的起点而放过（试过，真会漏）。
    """
    cleaned = mask_raw_literals(strip_comments(source))
    in_multiline = False
    for number, line in enumerate(cleaned.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('"""') or stripped.endswith('"""'):
            in_multiline = not in_multiline
            continue
        if in_multiline:
            continue

        count = 0
        index = 0
        length = len(line)
        while index < length:
            char = line[index]
            if char == "\\":
                # 跳过转义对：\" 只算半个，不该计入
                index += 2
                continue
            if char == '"':
                count += 1
            index += 1

        if count % 2 == 1:
            report(
                "R20", path, number,
                "这一行有 %d 个双引号（奇数），多半有一个没转义或被吃掉了：%s"
                % (count, stripped[:44])
            )


# CaseIterable / Identifiable 这些协议会自动提供成员，不算"没声明"。
SYNTHESIZED_MEMBERS = {
    "allCases", "rawValue", "id", "hashValue", "hash", "description",
    "debugDescription", "self", "init", "Type", "shared", "main",
    "localizedDescription", "errorDescription", "failureReason",
    "recoverySuggestion", "helpAnchor", "suberror", "isEmpty",
}


def collect_declared_names(sources):
    """项目里出现过的所有名字（属性、方法、枚举 case、类型、参数标签）。

    回答一个问题：**我调用的那个成员，项目里到底有没有**。
    手写六十个文件、一次都没编译过时，写错一个属性名
    （`momentMaxReplies` 写成 `momentMaxReplay`）太容易了，
    而编译器会报这种错、我看不到 —— 本地先搜一遍。
    """
    names = set()
    for source in sources.values():
        code = strip_code(source)
        names.update(re.findall(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)", code))
        names.update(re.findall(r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)", code))
        # 枚举 case，一行可能好几个：`case female, male, other`。
        # **这里只能用 [ \t]，不能用 \s** —— \s 会把下一行的 `case` 也吞进来，
        # 结果真正的名字反而没被收进去（踩过：badResponse / rejected 报成"没声明"）。
        for hit in re.findall(r"\bcase\s+([A-Za-z_][A-Za-z0-9_, \t]*)", code):
            for piece in hit.split(","):
                piece = piece.strip().split("(")[0].split("=")[0].strip()
                if piece:
                    names.add(piece)
        names.update(re.findall(
            r"\b(?:struct|class|enum|actor|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)",
            code,
        ))
        # 参数标签 / 结构体初始化器参数 —— 一并收进来，压低误报
        names.update(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", code))
    names |= SYNTHESIZED_MEMBERS
    return names


def check_member_references(sources, types, declared):
    """`Xxx.shared.成员` 与 `Xxx.成员` 里的成员名，项目里得出现过。

    只查**项目内定义的类型**（系统类型走 allowlist），范围小、误报低。
    """
    for path, source in sources.items():
        code = strip_code(source)
        for number, line in enumerate(code.splitlines(), 1):
            for match in re.finditer(
                r"\b([A-Z][A-Za-z0-9_]*)\.(?:shared\.)?([a-z][A-Za-z0-9_]*)\b", line
            ):
                owner, member = match.group(1), match.group(2)
                if owner in SYSTEM_TYPES or owner not in types:
                    continue
                if member in SYNTHESIZED_MEMBERS:
                    continue
                if member not in declared:
                    report(
                        "R14", path, number,
                        "%s 上用了 .%s，但项目里找不到这个名字的声明" % (owner, member)
                    )


def check_info_plist():
    """每个 target 的 Info.plist 都必须是合法 plist。

    格式错一个字符，`xcodebuild` 会直接失败，而且报错在构建日志深处。
    这里用标准库 plistlib 先解一遍，顺带确认那些**缺了就会崩**的权限键还在，
    以及录屏扩展的注册信息没写错。
    """
    parsed = {}
    for path in INFO_PLISTS:
        if not os.path.exists(path):
            continue
        try:
            with open(path, "rb") as handle:
                parsed[path] = plistlib.load(handle)
        except Exception as error:  # noqa: BLE001
            report("R15", path, 0, "plist 解析失败：%s" % error)

    if INFO_PLIST not in parsed and os.path.exists(INFO_PLIST):
        return  # 主 App 的解析已经报过了

    app_plist = parsed.get(INFO_PLIST)
    if app_plist is not None:
        sources = read_swift_sources()
        for key, framework in REQUIRED_PERMISSIONS.items():
            if framework in sources and key not in app_plist:
                report("R15", INFO_PLIST, 0, "用了 %s 但缺 %s（一调用就崩）" % (framework, key))

    check_extension_plist(parsed)


def check_extension_plist(parsed):
    """录屏扩展的注册信息。

    这一块出错的表现非常隐蔽：编译能过、装也装得上，
    但系统录屏列表里**根本没有 Aevis**，界面上也不会报任何错。
    所以把关键几点在这里钉死。
    """
    path = os.path.join(PROJECT, "Broadcast", "Info.plist")
    data = parsed.get(path)
    if data is None:
        return

    extension = data.get("NSExtension")
    if not isinstance(extension, dict):
        report("R15", path, 0, "缺 NSExtension —— 这个扩展永远不会出现在系统录屏列表里")
        return

    point = extension.get("NSExtensionPointIdentifier")
    if point != BROADCAST_EXTENSION_POINT:
        report("R15", path, 0,
               "NSExtensionPointIdentifier 必须是 %s，现在是 %r"
               % (BROADCAST_EXTENSION_POINT, point))

    principal = extension.get("NSExtensionPrincipalClass") or ""
    if not principal.endswith(".SampleHandler"):
        report("R15", path, 0,
               "NSExtensionPrincipalClass 要以 .SampleHandler 结尾，现在是 %r" % principal)

    if not data.get("CFBundleDisplayName"):
        report("R15", path, 0, "缺 CFBundleDisplayName —— 系统录屏列表里会显示成空名字")


def check_app_group_wiring():
    """主 App 与扩展的「管子」接对了没有。

    三件事，任何一件错了都是**静默失效**（不崩、不报错，只是永远没内容），
    所以值得单独钉：

    1. 两份 entitlements 声明的应用组必须**完全一样**。
       不一样的话，两个进程拿到的容器不是同一个。
    2. Swift 里写死的 `appGroupID` 必须就在那份清单里。
       改了一边忘另一边，容器直接是 nil。
    3. Swift 里写死的 `extensionBundleID` 必须等于 project.yml 里
       给扩展设的 bundle id。不一样的话，系统录屏控件不会预选我们那个扩展，
       用户得自己在一堆扩展里翻 —— 表现像「点了没反应」。
    """
    app_groups = read_entitlement_groups(ENTITLEMENTS["app"])
    ext_groups = read_entitlement_groups(ENTITLEMENTS["extension"])
    if app_groups is None or ext_groups is None:
        return

    if not app_groups or not ext_groups:
        report("R15", ENTITLEMENTS["extension"], 0,
               "两个 target 都必须声明应用组，否则主 App 和扩展没法共享容器")
        return

    if set(app_groups) != set(ext_groups):
        report("R15", ENTITLEMENTS["extension"], 0,
               "两份权限声明的应用组不一致：%s 对 %s" % (app_groups, ext_groups))
        return

    if not os.path.exists(STORE_PATH):
        report("R15", STORE_PATH, 0, "找不到共享容器的声明文件")
        return

    with open(STORE_PATH, encoding="utf-8") as handle:
        store = handle.read()

    group = first_match(store, r'static let preferredAppGroup\s*=\s*"([^"]+)"')
    if group is None:
        report("R15", STORE_PATH, 0,
               "读不到 preferredAppGroup —— 扩展和主 App 没法约定同一个容器")
    elif group not in app_groups:
        report("R15", STORE_PATH, 0,
               "代码里首选的应用组 %s 不在权限清单 %s 里。"
               "运行时会退而求其次去权限里挑一个能用的，但首选对不上说明"
               "两份声明和代码没对齐 —— 值得查一下" % (group, app_groups))

    bundle = first_match(store, r'static let extensionBundleID\s*=\s*"([^"]+)"')
    if bundle is None:
        report("R15", STORE_PATH, 0, "读不到 extensionBundleID —— 系统录屏控件没法预选我们的扩展")
    else:
        spec_path = os.path.join(PROJECT, "project.yml")
        if os.path.exists(spec_path):
            with open(spec_path, encoding="utf-8") as handle:
                spec = handle.read()
            # 工程被 strip_extension.py 摘掉扩展时，这里不该再报 ——
            # 那是**故意**没有扩展的，不是接线错了。
            if "AevisBroadcast" in spec and ("PRODUCT_BUNDLE_IDENTIFIER: " + bundle) not in spec:
                report("R15", spec_path, 0,
                       "project.yml 里没有 PRODUCT_BUNDLE_IDENTIFIER: %s —— "
                       "和代码里的 extensionBundleID 对不上，录屏控件无法预选" % bundle)


def read_entitlement_groups(path):
    """读一份 entitlements 里声明的应用组。文件不存在返回 None。"""
    if not os.path.exists(path):
        return None
    try:
        with open(path, "rb") as handle:
            data = plistlib.load(handle)
    except Exception:  # noqa: BLE001
        return None
    value = data.get("com.apple.security.application-groups")
    if not isinstance(value, list):
        return []
    return value


def first_match(text, pattern):
    hit = re.search(pattern, text)
    return hit.group(1) if hit else None


def check_yaml_files():
    """workflow 与 project.yml 必须是合法 YAML，而且不能有 tab 缩进。

    YAML 语法错 → **整条 CI 一行都不跑**，而且只在 GitHub 上才暴露。
    tab 缩进是 YAML 明令禁止的，肉眼又看不出来。
    需要 pyyaml；没装就跳过（并说明跳过了），不让它变成噪音。
    """
    targets = [
        os.path.join(os.path.dirname(ROOT), ".github", "workflows", "build-ipa.yml"),
        os.path.join(os.path.dirname(ROOT), "project.yml"),
    ]
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        notes.append("（没装 pyyaml，跳过了 workflow / project.yml 的语法检查）")
        return

    for path in targets:
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
        try:
            yaml.safe_load(raw)
        except Exception as error:  # noqa: BLE001
            report("R16", path, 0, "YAML 语法错误：%s" % str(error).split("\n")[0])
        for number, line in enumerate(raw.splitlines(), 1):
            if line.startswith("\t") or " \t" in line:
                report("R16", path, number, "YAML 里不能有 tab 缩进")


def collect_localized_names(sources):
    """把「显示时已经包了 LocalizedStringKey(...)」的名字收进来。

    `Text(LocalizedStringKey(某变量))` 是会渲染 markdown 的，
    所以那种字符串不该被 R17 报 —— 否则修完了还在叫，规则就没人信了。
    """
    names = set()
    for source in sources.values():
        code = strip_code(source)
        for hit in re.findall(r"LocalizedStringKey\(\s*([A-Za-z_][A-Za-z0-9_.]*)", code):
            names.add(hit)
            # LocalizedStringKey(ShortcutBridge.lockScreenNote) 里真正要白名单的是
            # 最后一个点号后面的名字，不然对不上声明
            names.add(hit.split(".")[-1])
    return names


def check_markdown_in_strings(path, source, localized):
    r"""String literal 里的 `**加粗**` 到底会不会被解析？**位置决定一切。**

    SwiftUI 只在两种拿法下解析 markdown：
      · `Text(LocalizedStringKey("…**…**…"))`   → 解析（这是最保险的写法）
      · `Text("…**…**…")`                        → **不解析**，星号原样显示

    ⚠️ 2026-10-01 修正：这条规则以前把 `Text("字面量")` 当成"安全"放过去了，
    依据是"字面量会被当成 LocalizedStringKey"。**那个依据是错的** ——
    `Text` 有一堆重载，**单行字符串字面量走的是 `Text(String)`，不做 markdown 解析**。
    真踩了两次：
      · 2026-09-29 钱包底部「这是**本机上的假钱包** …」（拼接，当次修了）
      · 2026-10-01 用户截图投诉「app 登录界面串了」——
        LoginView 里两条单行字面量「只发给**已经注册过**的邮箱」，星号明晃晃露着，
        而这条规则当时正把它放过去了（"结果检查器说没问题，用户却看得见星号"）。
    ⇒ 现在判据收紧成 `wrapped_key` 一种。历史上放过去过的 5 处已一并改成
      `Text(LocalizedStringKey(…))`。

    必须放过的（不然天天误报、规则就没人信了）：
    1. **喂给模型的工具描述**（`description:` / `instruction =`）—— 提示词里 markdown 不影响；
    2. **只由星号组成的字符串**（`"**"`）—— 那是用来删星号的记号，不是文案；
    3. **`verbatim:` 和 `LocalizedStringKey(…)`** —— 前者本来就不解析、后者就是要解析的。
    """
    lines = source.splitlines()
    in_multiline = False
    start = 0
    header = ""
    buffer = []

    for number, line in enumerate(lines, 1):
        stripped = line.strip()

        if stripped.count('"""') == 1:
            if not in_multiline:
                in_multiline = True
                start = number
                header = stripped
                buffer = [stripped]
            else:
                buffer.append(stripped)
                in_multiline = False
                body = "\n".join(buffer)
                benign = (re.search(r'\bdescription\s*:\s*"""$', header) is not None
                          or re.search(r'"(?:description|title)"\s*:', header) is not None
                          or "instruction = " in header)
                if _looks_like_prose(body) and not benign:
                    found = re.search(r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)", header)
                    name = found.group(1) if found else ""
                    if name not in localized:
                        report("R17", path, start,
                               "%s 这段有 ** 加粗，但显示时没包 LocalizedStringKey，星号会原样显示"
                               % (name or "这段文字"))
            continue

        if in_multiline:
            buffer.append(stripped)
            continue

        if stripped.startswith("//"):
            continue

        index = 0
        length = len(line)
        while index < length:
            if line[index] != '"':
                index += 1
                continue
            scan = index + 1
            while scan < length:
                if line[scan] == "\\":
                    scan += 2
                    continue
                if line[scan] == '"':
                    break
                scan += 1
            if scan >= length:
                break
            literal = line[index + 1:scan]
            before = line[:index].rstrip()
            after = line[scan + 1:].strip()
            if not after and number < len(lines):
                after = lines[number].strip()
            # 只有 `Text(LocalizedStringKey("…"))` 真的解析 markdown。
            # ⚠️ `verbatim:` 是**明确要求不解析**的，放过它（报了也没法"修"）。
            wrapped_key = bool(re.search(r"\bText\(\s*LocalizedStringKey\(\s*$", before))
            verbatim = bool(re.search(r"\bverbatim\s*:\s*$", before))

            # 工具参数的 JSON schema：`"description": "…"` 以及它的续行（`+ "…"`）。
            #
            # ⚠️ 这一处是 2026-10-02 补的：本规则自己的说明文档里早就写着
            #    "喂给模型的工具描述要放过"，但实现只认**顶层**那种
            #    （`description: """…"""`），不认 schema 里的 `"description": "…"`
            #    —— 于是新加一个带 `**` 的参数说明就误报，而它根本不会经过 `Text`。
            #    误报攒多了这条规则就没人看了，那正是最危险的状态。
            benign_schema = bool(re.search(r'"(?:description|title)"\s*:', before))
            if not benign_schema and before.rstrip().endswith("+"):
                # 续行：往回找这一句的**开头**。只允许跨过同样是续行的行。
                for back in range(number - 2, max(number - 5, -1), -1):
                    prev = lines[back]
                    if '"description":' in prev or '"title":' in prev:
                        benign_schema = True
                        break
                    if prev.strip() and not prev.strip().rstrip().endswith("+"):
                        break

            # 拼接（`+ "…"`）会让它变成 String 表达式 —— 星号同样原样显示。
            # `+` 常写在下一行，所以 next-line 也要看。
            if (_looks_like_prose(literal)
                    and not wrapped_key and not verbatim and not benign_schema):
                hint = ("拼接出来的要用 `Text(LocalizedStringKey(…))`，"
                        if after.startswith("+") else
                        "`Text(\"字面量\")` 走的是 `Text(String)`，不做 markdown 解析 —— "
                        "包一层 `Text(LocalizedStringKey(…))`（或者干脆去掉星号，"
                        "这两行本来就不值得加粗）")
                report("R17", path, number,
                       "这个字符串有 ** 加粗，但不是 `Text(LocalizedStringKey(…))`，"
                       "星号会原样显示。" + hint)
                break
            index = scan + 1


def _looks_like_prose(text):
    """有 ** 之外还得有正文 —— 只由星号组成的是"记号"，不是文案。"""
    if "**" not in text:
        return False
    return text.replace("*", "").strip() != ""


# 顶格写的类型声明（有缩进的是嵌套类型，不算独立作用域）
TOP_LEVEL_TYPE = re.compile(
    r"^(?:public |internal |private |fileprivate |final |open )*"
    r"(?:struct|class|enum|extension|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

# 带属性包装器的属性 —— 这些是「某个 View 自己的状态」。
# 故意只认这一族：它们几乎不可能和别处的局部变量重名，误报就压得住。
WRAPPED_PROPERTY = re.compile(
    r"@(?:State|StateObject|ObservedObject|EnvironmentObject|Environment|"
    r"Binding|FocusState|AppStorage|SceneStorage|Published|Namespace|Query)\b"
    r"(?:\s*\([^)]*\))?"
    r"(?:\s+(?:private|public|internal|fileprivate|weak|lazy|static|final))*"
    r"\s+var\s+([A-Za-z_][A-Za-z0-9_]*)"
)


def check_optional_suffix_use(sources):
    """对**可选类型**的属性直接接 `.isEmpty` / `.count` 之类 —— 编译不过。

    真踩过（build-44 整轮失败）：

        @Published var lastError: String?
        if !account.lastError.isEmpty { ... }
        // error: value of optional type 'String?' must be unwrapped

    这类错**本地一条都报不出来**，只能等 CI（十几分钟一轮）。

    做法：先把**全项目**声明成可选的属性名收一份，再看谁在名字后面
    直接接了那些成员，而且那一行没有 `if let` / `guard let` 解包。
    收全项目而不是逐个文件，是因为"声明在 A 文件、用在 B 文件"正是这次的情况。

    ⚠️ 两道收紧，都是被误报逼出来的（第一版 118 处、第二版还剩 25 处，
    真出事的那一行反而被淹掉 —— **检查器一旦不被信任就等于没有**）：

    1. **名字前面必须带一个点**（`账户.名字.isEmpty`）。带点的写法一定是某个对象的
       成员，不会是同名局部变量 —— 这一条就把 `text` / `path` 那类误报清掉了。
    2. **只盯「全项目里只以可选形式出现过」的名字**。`apiKey` 在 `AppSettings` 里是
       普通的 `String`、在 `Payload` 里是 `String?` —— 这种名字直接跳过，
       因为光看一行代码分不出用的是哪一个。真出事的 `lastError` 全项目只有可选那一种，
       照样抓得到。
    """
    declaration = re.compile(
        r"\b(?:(?:private|fileprivate|internal|public|open)\s+)?"
        r"(?:static\s+)?(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^=\{\n]+)"
    )
    members = ("isEmpty", "count", "first", "last", "uppercased", "lowercased",
               "trimmingCharacters", "split", "hasPrefix", "hasSuffix")

    optional_names = set()
    plain_names = set()
    for source in sources.values():
        for name, type_text in declaration.findall(strip_code(source)):
            if type_text.strip().endswith("?"):
                optional_names.add(name)
            else:
                plain_names.add(name)

    # 在别处是「一定有的」就不判 —— 分不出这一行用的是哪一个
    suspects = optional_names - plain_names
    if not suspects:
        return

    for path, source in sorted(sources.items()):
        for number, line in enumerate(strip_code(source).splitlines(), 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("//"):
                continue
            for name in suspects:
                # 前面那个点不是可选的 —— 这就是精度的来源
                pattern = r"\.\s*%s\s*\.\s*(?:%s)\b" % (re.escape(name), "|".join(members))
                if not re.search(pattern, line):
                    continue
                # 已经解包过的放过：`if let x` / `guard let x` / `x ??` / `x!`
                if re.search(r"\b(?:if|guard)\s+let\s+%s\b" % re.escape(name), line):
                    continue
                if re.search(r"%s\s*(\?\?|!)" % re.escape(name), line):
                    continue
                report(
                    "R24", path, number,
                    "`%s` 是可选的，不能直接接「.成员」—— 先解包（if let / guard let / ??）"
                    % name
                )


def check_keychain_labels(sources):
    """`Keychain.set(value, for: account)` —— 第二个标签是 `for:`。

    真踩过：新写的 `DeviceIdentity` 里写成了 `forKey:`，编译器报
    `incorrect argument label in call (have '_:forKey:', expected '_:for:')`，
    而本地检查器**一条都没报** → 白烧一整轮 CI（十几分钟）。

    "参数标签写错"没法用通用规则抓（会把所有自定义方法都卷进来，误报成灾），
    但对项目里那几个**签名固定、调用点多**的小工具，手工立一条完全值得 ——
    规则一旦有误报就等于没有，所以宁可窄，不可宽。
    """
    wrong = ("forKey:", "forAccount:", "forAccount ")
    for path, source in sorted(sources.items()):
        for number, line in enumerate(strip_code(source).splitlines(), 1):
            if "Keychain.set(" not in line:
                continue
            for label in wrong:
                if label in line:
                    report("R25", path, number,
                           "Keychain.set 的第二个标签是 `for:`，不是 `%s`" % label.rstrip(": "))
                    break


# R27 用到的两组名字：层级样式（HierarchicalShapeStyle）和具名颜色（Color）
TERNARY_LEVELS = ("primary", "secondary", "tertiary", "quaternary", "quinary")
TERNARY_COLORS = ("red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue",
                  "indigo", "purple", "pink", "brown", "white", "black", "gray", "grey")


def check_traditional_chinese(path, source):
    """源码里混进了繁体字。

    **真踩过（2026-09-26）**：写通话记录那段注释时手滑打出「留下一條通話记录」——
    「條」「話」是繁体、「记」又是简体，一句话里混着两种字形。
    这种错编译不报、界面上也不明显（尤其注释里），但用户一眼能看出来，
    而且这类字看着"没坏"，最容易一路漏进交付版本。

    只列**简体里根本不会出现的字**（像「置」「示」「雨」「的」两边同形，不能进列表，
    否则误报成灾）。命中的一律改成简体。
    """
    bad = {
        "條": "条", "話": "话", "記": "记", "錄": "录", "電": "电", "們": "们",
        "個": "个", "這": "这", "來": "来", "說": "说", "時": "时", "間": "间",
        "開": "开", "關": "关", "選": "选", "擇": "择", "確": "确", "認": "认",
        "顯": "显", "應": "应", "該": "该", "對": "对", "為": "为", "與": "与",
        "從": "从", "會": "会", "過": "过", "還": "还", "進": "进", "讓": "让",
        "覺": "觉", "麼": "么", "樣": "样", "種": "种", "題": "题", "語": "语",
        "讀": "读", "寫": "写", "聽": "听", "見": "见", "錯": "错", "誤": "误",
        "費": "费", "錢": "钱", "買": "买", "賣": "卖", "價": "价", "網": "网",
        "線": "线", "點": "点", "學": "学", "國": "国", "號": "号", "響": "响",
        "聲": "声", "樂": "乐", "動": "动", "務": "务", "員": "员", "車": "车",
        "馬": "马", "長": "长", "門": "门", "風": "风", "雲": "云", "產": "产",
        "業": "业", "檢": "检", "測": "测", "試": "试", "簡": "简", "單": "单",
        "頭": "头", "體": "体", "無": "无", "機": "机", "數": "数", "圖": "图",
        "視": "视", "頻": "频", "質": "质", "總": "总", "編": "编", "適": "适",
        "際": "际", "講": "讲", "氣": "气", "專": "专", "識": "识", "護": "护",
    }
    for number, line in enumerate(source.splitlines(), 1):
        for traditional, simplified in bad.items():
            if traditional in line:
                report("R28", path, number,
                       "混进了繁体字「%s」，改成「%s」" % (traditional, simplified))
                break


def check_ternary_style_types(path, code):
    """三元表达式写成 `? .secondary : .orange` —— 两个分支类型对不上，编译不过。

    真踩过（**build-54 整轮 CI 挂在它上**）：
        .foregroundStyle(gate.problem == nil ? .secondary : .orange)
    → `error: member 'orange' in 'HierarchicalShapeStyle' produces result of type
       'Color', but context expects 'HierarchicalShapeStyle'`。

    为什么只有这个顺序会炸：`.secondary` **既是** `HierarchicalShapeStyle` 的成员、
    **又是** `Color` 的成员，编译器优先挑前者；于是 `:` 那边的 `.orange`
    只能落到 `ShapeStyle` 扩展上（返回 `Color`）→ 两边类型不一致。
    - 反过来写（`.orange : .secondary`）第一个分支只有 `Color` 有 → 推断成 `Color`，两边都是 Color，没事；
    - `.primary : .secondary` 也安全（两边都是层级样式）。
    修法一律是**两边都写全**：`Color.secondary : Color.orange`。
    """
    pattern = re.compile(
        r"\?\s*\.(%s)\s*:\s*\.(%s)\b"
        % ("|".join(TERNARY_LEVELS), "|".join(TERNARY_COLORS)))
    for number, line in enumerate(code.splitlines(), 1):
        found = pattern.search(line)
        if found:
            report("R27", path, number,
                   "三元里 `.%s`（层级样式）与 `.%s`（Color）类型不同 —— 两边都写成 Color.xxx"
                   % (found.group(1), found.group(2)))


def check_uiimage_resizable(sources):
    """`UIImage` 变量后面直接接 `.resizable()` —— 编译不过。

    真踩过（**build-53 整轮 CI 就是这么炸的**）：
        if let image = UIImage(data: data) {
            Color.clear
                .frame(height: 170)
                .overlay(image.resizable().scaledToFill())   // ← 这里
    → `error: value of type 'UIImage' has no member 'resizable'`。

    SwiftUI 里能 `.resizable()` 的是 `Image`；UIKit 的 `UIImage` 必须先包一层
    `Image(uiImage:)`。之所以容易写错：这两样在代码里**都叫 image**。

    只盯**同一个文件里明确由 `UIImage(` 造出来的变量名** ——
    这样 `Image` 类型的 `image`（项目里到处都是）不会被误报。
    规则一旦有误报就等于没有，所以宁可窄，不可宽。
    """
    for path, source in sorted(sources.items()):
        code = strip_code(source)
        names = set(re.findall(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]+)?=\s*UIImage\(",
                               code))
        if not names:
            continue
        for number, line in enumerate(code.splitlines(), 1):
            for name in sorted(names):
                if name + ".resizable()" in line:
                    report("R26", path, number,
                           "`%s` 是 UIImage，没有 .resizable() —— 要先包成 Image(uiImage: %s)"
                           % (name, name))
                    break


def check_property_scope(sources):
    """某个类型里用了 `名字.`，而这个名字是**同一个文件里另一个类型**的属性。

    真踩过：给聊天页加表情时，`emoji` 声明在了 `ChatView` 上，
    真正用它的是同文件里的 `MessageBubble` —— 那个 struct 直接编不过
    （cannot find 'emoji' in scope），而本地静态检查**一条都没报**，
    白跑了一轮 CI（十几分钟，最后只能靠推理去定位）。

    两条限制把误报压到接近零：
    1. 只盯**带属性包装器的属性名**（@State / @ObservedObject / ...）;
    2. 这个名字必须**在本文件里确实有声明**，只是不在当前这个类型里。
    """
    for path, source in sorted(sources.items()):
        code = strip_code(source)
        lines = code.splitlines()
        raw = source.splitlines()

        marks = []
        for index, line in enumerate(lines):
            match = TOP_LEVEL_TYPE.match(line)
            if match:
                marks.append((index, match.group(1)))
        if len(marks) < 2:
            continue  # 只有一个类型，不存在「用错作用域」

        regions = []
        for order, (start, name) in enumerate(marks):
            end = marks[order + 1][0] - 1 if order + 1 < len(marks) else len(lines) - 1
            regions.append((name, start, end))

        # 本文件里每个属性属于哪个类型
        owners = {}
        for name, start, end in regions:
            body = "\n".join(lines[start:end + 1])
            for prop in WRAPPED_PROPERTY.findall(body):
                owners.setdefault(prop, set()).add(name)
        if not owners:
            continue

        for name, start, end in regions:
            body = "\n".join(lines[start:end + 1])
            declared_here = set(
                re.findall(r"\b(?:let|var|func|case)\s+([A-Za-z_][A-Za-z0-9_]*)", body)
            )
            for index in range(start, end + 1):
                if raw[index].strip().startswith("//"):
                    continue
                for used in re.findall(r"(?<![.\w])([a-z_][A-Za-z0-9_]*)\.", lines[index]):
                    if used not in owners or used in declared_here:
                        continue
                    elsewhere = "、".join(sorted(owners[used] - {name}))
                    report(
                        "R18", path, index + 1,
                        "用了「%s.」，但它声明在 %s 里，不在这里 —— 会编不过"
                        "（cannot find '%s' in scope）"
                        % (used, elsewhere or "另一个类型", used)
                    )


def check_cf_memory(path, code):
    """`CFRelease` / `CFRetain` 在 Swift 里是**编译错误**。

    编译器原话：「unavailable: Core Foundation objects are automatically
    memory managed」—— CF 对象由 ARC 管，不许手动释放。

    真踩过：手写 `dlsym` + `unsafeBitCast` 去调私有 API（读自己的
    entitlements）时，习惯性按 C 的写法加了 CFRelease。**本地静态检查
    放过去了、CI 编译才报出来**，白等一轮。写这条就是为了按在本地。
    """
    for number, line in enumerate(code.splitlines(), 1):
        for name in ("CFRelease", "CFRetain"):
            if name + "(" in line:
                report("R19", path, number,
                       "%s 在 Swift 里不可用（CF 对象由 ARC 自动管理），直接删掉" % name)


def collect_definitions(sources):
    """收集项目里定义的类型名，以及哪些类型有 .shared。"""
    types = set()
    shared = set()
    for path, source in sources.items():
        types.update(re.findall(r"\b(?:struct|class|enum|actor)\s+([A-Z][A-Za-z0-9_]*)", source))
        for name in re.findall(r"\b(?:struct|class|enum|actor)\s+([A-Z][A-Za-z0-9_]*)", source):
            if re.search(r"static\s+let\s+shared\b", source):
                shared.add(name)
    return types, shared


def check_shared_references(sources, types, shared):
    for path, source in sources.items():
        code = strip_code(source)
        for number, line in enumerate(code.splitlines(), 1):
            for name in re.findall(r"\b([A-Z][A-Za-z0-9_]*)\.shared\b", line):
                # 系统类型的 .shared 不是我们能定义的，跳过（否则天天误报就该被无视了）
                if name in SYSTEM_TYPES:
                    continue
                if name not in types:
                    report("R8", path, number, "%s 没有定义，但被取了 .shared" % name)
                elif name not in shared:
                    report("R8", path, number, "%s 被取了 .shared，但里面没找到 static let shared" % name)


def class_bodies(source):
    """粗提每个类型的类体：从声明后面第一个 `{` 到括号配平的那个 `}`。

    不追求精确（字符串里的花括号会干扰），因为后面只拿它取**成员名**，
    而成员名的判据本身是保守的 —— 宁可漏报也不误报。
    """
    out = []
    for match in re.finditer(r"\b(?:class|struct|enum|actor)\s+([A-Z][A-Za-z0-9_]*)", source):
        start = source.find("{", match.end())
        if start < 0:
            continue
        depth = 0
        for index in range(start, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    out.append((match.group(1), source[start:index + 1]))
                    break
    return out


def check_instance_member_on_type(sources, shared):
    r"""把**实例成员当类型成员用** —— 说白了就是漏了个 `.shared`。

    真踩过（2026-09-25，白烧一轮 CI）：
        detail: ScreenShareStore.isUsable        ← isUsable 是实例属性
    编译器到那一步才炸：
        error: instance member 'isUsable' cannot be used on type 'ScreenShareStore'
    而这一行在本地看起来一点都不扎眼 —— 所以必须自动挑出来。

    做法：只看**有 `.shared` 的那些类型**（范围一下就小了），
    把它们内部 `static` 修饰过的成员名收一份、非 static 的收一份；
    然后扫全项目 `TypeName.小写成员名` 的写法，落在"实例成员"里就报。
    首字母大写的跳过（那是嵌套类型，比如 `ScreenShareStore.Entry`）。
    """
    statics, instances = {}, {}
    for _, source in sources.items():
        for name, body in class_bodies(source):
            statics.setdefault(name, set())
            instances.setdefault(name, set())
            for line in body.splitlines():
                hit = re.search(r"\bstatic\s+(?:let|var|func)\s+([A-Za-z_][A-Za-z0-9_]*)", line)
                if hit:
                    statics[name].add(hit.group(1))
                hit = re.search(r"\b(?:let|var|func)\s+([A-Za-z_][A-Za-z0-9_]*)", line)
                if hit:
                    instances[name].add(hit.group(1))

    for path, source in sources.items():
        code = strip_code(source)
        for number, line in enumerate(code.splitlines(), 1):
            for name in shared:
                if name in SYSTEM_TYPES:
                    continue
                pattern = r"\b%s\.([a-z][A-Za-z0-9_]*)" % re.escape(name)
                for member in re.findall(pattern, line):
                    if member in statics.get(name, set()):
                        continue
                    if member in instances.get(name, set()):
                        report(
                            "R21", path, number,
                            "%s.%s 少写了 .shared —— %s 是实例成员（编译期才会报错）"
                            % (name, member, member)
                        )


# 「某个 store 的某个属性」是什么类型 —— 只列**项目自己的模型**。
# 为什么只列这么几条：这条规则的判据是"该成员在类型里有没有声明过"，
# 范围一旦放开到全项目，那些靠 protocol / 泛型 / 动态成员拿到的东西
# 就会天天误报 —— 而误报一多，这个检查就没人看了。
#
# ⚠️ **集合属性（`[ChatMessage]` 这种）一个都别往这儿放。**
#    2026-10-03 第一版就把 `ChatStore.messages` 写成了 `ChatMessage`，
#    于是 `.filter` / `.suffix` 全被判成"ChatMessage 上没有" ——
#    那是**数组**的方法，四条误报当场打脸。集合上能调的成员太多、
#    跟元素类型没关系，判它有百害无一利。
STORE_PROP_TYPES = [
    ("PersonaStore", "active", "Contact"),
    ("PersonaStore", "persona", "Persona"),
]


def extension_bodies(source):
    """粗提每个 `extension TypeName { … }` 的体（和 `class_bodies` 同一套括号配平）。"""
    out = []
    for match in re.finditer(r"\bextension\s+([A-Z][A-Za-z0-9_]*)", source):
        start = source.find("{", match.end())
        if start < 0:
            continue
        depth = 0
        for index in range(start, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    out.append((match.group(1), source[start:index + 1]))
                    break
    return out


def collect_members(sources):
    """类型名 → 它声明过的成员名。

    ⚠️ **`extension` 里的必须一起算**：这个项目很爱用 extension 补计算属性，
       只看类体的话，那些成员会被当成"不存在"⇒ 天天误报。
    """
    members = {}

    def add(name, body):
        slot = members.setdefault(name, set())
        for line in body.splitlines():
            for hit in re.finditer(
                    r"\b(?:let|var|func|case)\s+([A-Za-z_][A-Za-z0-9_]*)", line):
                slot.add(hit.group(1))

    for _, source in sources.items():
        for name, body in class_bodies(source):
            add(name, body)
        for name, body in extension_bodies(source):
            add(name, body)
    return members


def _store_prop_type(text):
    """这一行右边的表达式是不是「store.某属性」本尊？是就返回它的类型。

    ⚠️ 必须**恰好是它自己**：`PersonaStore.shared.active?.id` 的类型是 `UUID?`，
       不是 `Contact` —— 那种写法后面接的东西要按 UUID 判，不能按 Contact 判。
       所以末尾用负向先行断言排掉 `?` / `.`。
    """
    for store, prop, type_name in STORE_PROP_TYPES:
        if re.match(r"\s*%s\.shared\.%s\s*(?![\w?.])"
                    % (re.escape(store), re.escape(prop)), text):
            return type_name
    return None


def check_member_on_model(sources, members):
    r"""**项目模型上不存在的成员** —— 最典型的就是把 `Contact` 当成有 `.name`。

    真踩过（2026-10-03，白烧一轮 CI）：
        "name": active?.name ?? "TA"          ← Contact 上根本没有 name
    编译器原话（`build.log` 里唯一一条 error）：
        PairChatBridge.swift:132:29: error: value of type 'Contact' has no member 'name'
    名字其实在 `contact.persona.name`（或 `contact.displayName`）。

    🔴 为什么这条**必须**自动挑出来：本机**没有 Xcode**，Swift 一行都编不了 ——
       这类"成员名写错"的错**只有 CI 编到那一步才会炸**，人眼扫一遍是扫不出来的。

    判据（保守，宁可漏报不误报）：
      ① 只认 `STORE_PROP_TYPES` 里那几种写法（`PersonaStore.shared.active` 之类）；
      ② 同一个文件里 `let NAME = <上面那种表达式>` 的绑定也认（只用 `let`；
         `NAME` 在别处被 `var` / `for in` / 当参数用过，整条丢掉）；
      ③ `NAME` 后面接 `?.` / `.` 再取**小写**成员名，而该成员在
         类体 **和** extension 里都没声明过 ⇒ 报 R22。
    """
    for path, source in sources.items():
        code = strip_code(source)
        lines = code.splitlines()

        # 名字被重新声明 / 当参数 / 当循环变量 ⇒ 这个文件里它不可信，整条丢
        poisoned = set()
        for line in lines:
            for name in re.findall(r"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)", line):
                poisoned.add(name)
            for name in re.findall(r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b", line):
                poisoned.add(name)
            if re.search(r"\bfunc\s+[A-Za-z_]", line) or "init(" in line:
                for name in re.findall(r"(?:\(|,)\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", line):
                    poisoned.add(name)

        binds = {}
        for number, line in enumerate(lines, 1):
            hit = re.search(
                r"(?<![\w.])let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^,]+)", line)
            if hit:
                name, rhs = hit.group(1), hit.group(2)
                type_name = _store_prop_type(rhs)
                if type_name:
                    if name in binds and binds[name] != type_name:
                        binds.pop(name, None)
                        poisoned.add(name)             # 同一名字绑过两种类型，别信
                    else:
                        binds[name] = type_name
                else:
                    binds.pop(name, None)              # 绑到别的东西上了，推断作废
                    poisoned.add(name)

            pairs = []
            for name, type_name in binds.items():
                if name in poisoned:
                    continue
                # ⚠️ 前面加 `(?<![\w.])`：不然后面 `screen.active?.x` 里的
                #    `active` 也会被当成我们那个局部变量 —— 那是误报。
                for member in re.findall(
                        r"(?<![\w.])%s\??\.([a-z][A-Za-z0-9_]*)" % re.escape(name), line):
                    pairs.append((name, type_name, member))
            for store, prop, type_name in STORE_PROP_TYPES:
                for member in re.findall(
                        r"\b%s\.shared\.%s\??\.([a-z][A-Za-z0-9_]*)" % (store, prop), line):
                    pairs.append(("%s.shared.%s" % (store, prop), type_name, member))

            for where, type_name, member in pairs:
                known = members.get(type_name)
                if known is None:                      # 类型没扫到就闭嘴，别瞎报
                    continue
                if member in known:
                    continue
                report("R22", path, number,
                       "%s 是 %s，而 %s 上没有 %s（编译器会报 no member）"
                       % (where, type_name, type_name, member))


def check_unicode_charset_in_url(path, code):
    r"""拼 URL 参数时用了 `CharacterSet.alphanumerics`。

    **它是 Unicode 的，中文也算「字母数字」** —— 于是中文一个字符都不会被
    percent-encode，拼出来的 URL 直接非法。

    真踩过（2026-09-25）：网易云搜索带中文关键词，网易回一句「格式错误」。
    这个坑特别阴，因为本机探针是 Python 写的（`urllib.parse.quote` 会老实编码中文），
    **本地怎么测都是通的**，坏只坏在 App 里 —— 白烧一轮编译才定位到。

    正确写法是**手写 ASCII 白名单**：
        CharacterSet(charactersIn: "ABC...xyz0123456789-._~")
    （项目里 `AppSettings.SearchSource.url(for:)` 一直是这么写的，
    所以这条规则不会误报它。）
    """
    lines = code.splitlines()
    for index, line in enumerate(lines):
        if "alphanumerics" not in line:
            continue
        # 允许分几行写，所以看上下两行的窗口
        window = "\n".join(lines[max(0, index - 2): index + 3])
        if "addingPercentEncoding" in window or "withAllowedCharacters" in window:
            report(
                "R22", path, index + 1,
                "拼 URL 用了 CharacterSet.alphanumerics —— 它是 Unicode 的，中文不会被编码：%s"
                % line.strip()[:40]
            )


def check_card_usage(sources, types):
    """设置页里列出来的 XxxCard() 必须真的定义过。"""
    for path, source in sources.items():
        if not path.endswith("SettingsView.swift"):
            continue
        for number, line in enumerate(source.splitlines(), 1):
            for name in re.findall(r"\b([A-Z][A-Za-z0-9_]*Card)\(\)", line):
                if name not in types:
                    report("R9", path, number, "%s() 在项目里找不到定义" % name)


# ——— R29 用的三个正则 + 括号配对 ———

OBSERVABLE_CLASS = re.compile(
    r"(?m)^((?:@[A-Za-z]+\s+)*)(?:final\s+|public\s+|internal\s+)*class\s+"
    r"([A-Za-z_]\w*)\s*:[^\n{]*ObservableObject"
)
PUBLISHED_PROP = re.compile(r"@Published[^\n]*?(?:var|let)\s+([A-Za-z_]\w*)")
ASYNC_FUNC = re.compile(
    r"(?m)^([ \t]*(?:(?:@[A-Za-z]+\s+)|(?:private\s+|internal\s+|public\s+|fileprivate\s+))*)"
    r"func\s+([A-Za-z_]\w*)\s*\([^)]*\)[^\n{]*\basync"
)


def balanced_end(text, open_index, limit=400000):
    """从 `{` 处往后找配对的 `}`，返回**闭合括号之后**的下标；找不到返回 -1。

    只用来圈出类体 / 函数体，所以直接数括号就够 —— 传进来的文本已经过了
    `strip_code()`，注释和字符串都被换成空格了，括号不会被字符串里的花括号带偏。
    """
    if open_index < 0 or open_index >= len(text) or text[open_index] != "{":
        return -1
    depth = 0
    for index in range(open_index, min(len(text), open_index + limit)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return -1


def check_mainactor_state(sources):
    """`ObservableObject` 里，**async 方法体内**改了 `@Published`，但类没标 `@MainActor`。

    ⚠️ 为什么会崩：Swift 5.5 起，**非隔离的 async 函数在 `await` 之后跳回全局并发池** ——
    调用点写 `Task { await gate.refresh() }` 只管住调用点，管不住函数体。
    于是那些 `@Published` 是在后台线程改的，**iOS 26 上直接硬崩**。

    真踩过两次：
      ① `MusicPlayer` —— 后台改 `@Published`，iOS 26 硬崩（build-61 那批）
      ② `DeviceGate` —— 真机诊断 `AE-155A-91FC`（iPhone15,3 / 0.0.62）：
         BlackBox 里最后一行正好是 `revokeBecauseAccountGone()` 里那句
         「账号已不存在 → 退回未授权」，写完进程就没了。

    ⚠️ 修的时候**别整个类盲标 `@MainActor`** —— build-61 那次盲改炸出 14 个编译错误，
    因为**在非隔离上下文里读它的属性是错误、读 `.shared` 只是警告**。
    要连同调用点一起改，改完再跑这一条确认。

    只报「确实在 async 函数体里赋值/改属性」的，静态属性和注释不算 —— 误报接近零。
    """
    for path, source in sorted(sources.items()):
        code = strip_code(source)
        for match in OBSERVABLE_CLASS.finditer(code):
            annotations, name = match.group(1), match.group(2)
            if "@MainActor" in annotations:
                continue
            body_start = code.find("{", match.end())
            if body_start < 0:
                continue
            body_end = balanced_end(code, body_start)
            if body_end < 0:
                continue
            body = code[body_start:body_end]
            published = PUBLISHED_PROP.findall(body)
            if not published:
                continue

            for func in ASYNC_FUNC.finditer(body):
                prefix, func_name = func.group(1), func.group(2)
                # 方法自己带了 @MainActor 也算数（给整个类标会炸出「读属性」那类编译错误，
                # 所以很多地方是只给方法标 —— 那种情况这里必须放过）
                if "@MainActor" in prefix:
                    continue
                open_index = body.find("{", func.end())
                if open_index < 0:
                    continue
                close_index = balanced_end(body, open_index)
                func_body = body[open_index:close_index if close_index > 0 else len(body)]
                touched = [p for p in published
                           if re.search(r"(?<![\w.])%s\s*(?:=[^=]|\.\w+\s*=)" % re.escape(p), func_body)]
                if not touched:
                    continue
                line = code[:body_start + open_index].count("\n") + 1
                report(
                    "R29", path, line,
                    "%s.%s() 是 async，却在里面改 @Published（%s）—— await 之后线程是随机的，"
                    "iOS 26 上会硬崩。整个类标 @MainActor，或把这次赋值挪到 MainActor 上"
                    % (name, func_name, "、".join(touched))
                )


def check_line_endings():
    """R31：Swift 源文件必须是 **LF**，不许整份 CRLF（也不许两者混着）。

    🔴 为什么这值得单立一条（2026-10-03 真发生在这仓库里）：另一个会话用
       Windows 的习惯重写了一个文件，**整份变成 CRLF**。后果不是"编译不过"，
       而是更阴的那种：
         · 推上去的 diff 是"整个文件都改了"—— 真正改了什么**完全看不出来**
           （`git log -p` / review 是事后唯一能追的地方，等于废了）；
         · 谁再把它改回来，又是一次全文件 diff。
       判据取"整份 CRLF"：本仓库 179 个 Swift 文件里 178 个是 LF、
       那一个 CRLF 就是事故 —— 所以这不是风格之争，是"谁动过这个文件"的信号。
       （`read_swift_sources()` 是文本模式读的，换行早被吃掉了 ⇒ 这条必须**读字节**。）
    """
    for path in swift_files():
        try:
            with open(path, "rb") as handle:
                raw = handle.read()
        except OSError:
            continue
        crlf = raw.count(b"\r\n")
        if not crlf:
            continue
        lf = raw.count(b"\n")
        report("R31", path, 1,
               "整份 CRLF（%d/%d 行）—— 被 Windows 编辑器重写过。"
               "推到仓库会让 diff 变成'整个文件都改了'，真实改动被埋掉。"
               "改成 LF 再推" % (crlf, lf))


def check_pairchannel_base(sources):
    """R30：手机侧「和电脑聊天」的长连地址必须来自**配对记录**。

    🔴 这条护的是一个**不会报错、只会永远转圈**的坑（2026-10-03 立的）。
       那天电脑版改成了「局域网直连」——**电脑自己当服务器**：
       配对码里的 `h` 是路由器给的 `192.168.x.x`，session 也只存在**那台电脑**上。

       要是 `PairChannel` 还按老的 `PairClient.currentBase`（写死在包里的腾讯云）
       去开长连，那台服务器上**根本没有这个 session** ⇒ 握手 401 ⇒
       而这里的失败处理是"当网断了、等会儿重连" ⇒
       **无限重连、一个错都不报**，界面上就是个小圆点一直转。

       ⇒ 判据：`connect()` 里的地址只能来自 `Self.base(for:)`；
         `PairClient.currentBase` 不许出现在 `connect()` 里
         （它只允许出现在 `base(for:)` 的兜底分支里）。
    """
    target = None
    for path in sources:
        if path.replace("\\", "/").endswith("Aevis/Core/PairChannel.swift"):
            target = path
            break
    if target is None:
        report("R30", "Aevis/Core/PairChannel.swift", 0,
               "找不到这个文件 —— 规则本身失效了，别默默跳过")
        return

    code = strip_code(sources[target])
    if "func base(for" not in code:
        report("R30", target, 0,
               "少了 `base(for:)`：长连地址得跟着**配对时那台电脑**走，"
               "否则局域网直连配对成功了聊天也连不上")
        return

    marker = "private func connect()"
    at = code.find(marker)
    if at < 0:
        return                      # 函数改名了就别瞎猜，交给人工看
    open_index = code.find("{", at)
    close_index = balanced_end(code, open_index)
    body = code[open_index:close_index if close_index > 0 else len(code)]
    line = code[:open_index].count("\n") + 1

    if "currentBase" in body:
        report("R30", target, line,
               "connect() 里用了 `PairClient.currentBase` —— 局域网配对会变成"
               "无限重连（那台服务器上没有这个 session）。改用 `Self.base(for: session)`")
    elif "base(for:" not in body:
        report("R30", target, line,
               "connect() 没走 `base(for:)` —— 长连地址必须来自配对时记下的那台电脑")


def check_append_listener(sources):
    """R32：`ChatStore` 的"又落了一条消息"必须是**可以挂多个**的。

    🔴 2026-10-03 真踩的坑：原来它是 `var onAppended: ((ChatMessage, UUID?) -> Void)?`
       ——一个**单赋值位**。`PairChatBridge` 用 `=` 占住了它，我又要挂一个
       `AutoSync` 上去（每说一句话同步到网盘），第二个 `=` 会把第一个**悄悄顶掉**：
       不报错、不抛异常，只是"电脑端聊天从此不再推送新消息"。

    ⇒ 现在叫 `appendListeners` + `addAppendListener(_:)`。
      这条规则钉死：`onAppended` 这个名字**不许再出现在任何地方**。
      以后要加监听者，只能 `addAppendListener`。

    ⚠️ 只看**代码**（注释里为了讲这段历史要提到它，不该被算成问题）。
    """
    bad = []
    for rel, source in sources.items():
        for number, line in enumerate(strip_code(source).splitlines(), 1):
            if "onAppended" in line:
                bad.append((rel, number, line.strip()[:60]))
    for rel, number, text in bad:
        report("R32", rel, number,
               "`onAppended` 是单赋值位，挂第二个监听者会**静默顶掉**第一个；"
               "改用 `ChatStore.shared.addAppendListener { ... }` —— %s" % text)


# ——— R33 用的几个正则 ———

# 填充：任何形状的 `.fill(...)` —— 这就是那次事故的根。
_FILL_CALL = re.compile(r"\.fill\s*\(")
# 显式尺寸约束。`.fill` 外面套了 `.frame(height: 0.5)` 这种的，是个细线/小块，
# 盖不满整张卡片，放过（免责声明页那条 0.5pt 分隔线就是这么写的）。
_FRAME_CALL = re.compile(r"\.frame\s*\(")
# 描边：`.strokeBorder(...)` 或 `.stroke(...)`。两者都只是**一圈边**，
# 命中区只有那一条线，**不会吃掉整张卡片** —— 所以带描边的算安全。
_OUTLINE_CALL = re.compile(r"\.stroke(?:Border)?\s*\(")
# 裸颜色：`Color(...)` / `Color.clear` / `Color.white.opacity(...)`。
# 用负向先行断言挡掉 `.foregroundColor` 这类别的标识符尾巴。
_BARE_COLOR = re.compile(r"(?<![\w.])Color\s*[.(]")
# 材质：`.ultraThinMaterial` 之类，以及裸露的 `Material` 类型。
_MATERIAL = re.compile(
    r"\.(?:ultraThinMaterial|thinMaterial|regularMaterial|thickMaterial|"
    r"ultraThickMaterial)\b|(?<![\w.])Material\b"
)
# 形状构造：`Rectangle()` / `RoundedRectangle(...)` / `Circle()` …（不带描边时才是问题）。
_SHAPE_CTOR = re.compile(
    r"(?<![\w.])(?:Rectangle|RoundedRectangle|Circle|Capsule|Ellipse|Path|"
    r"UnevenRoundedRectangle|ContainerRelativeShape)\s*\("
)
# 「放过」标记。父层补的也算 —— 后面紧跟一行也认。
_ALLOWS_HIT_FALSE = ".allowsHitTesting(false)"


def _paired_close(text, index, opener, closer):
    """从 `text[index]`（必须是 opener）开始数括号，返回配对 closer 的下标。

    和 `balanced_end` 是同一套括号配对思路，只是这里通用一点（圆括号 / 花括号都能数）。
    传进来的文本必须先过 `strip_code()`，否则字符串/注释里的括号会把深度带偏。
    找不到闭合返回 -1。
    """
    if index < 0 or index >= len(text) or text[index] != opener:
        return -1
    depth = 0
    for cursor in range(index, len(text)):
        char = text[cursor]
        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return cursor
    return -1


def _overlay_body(code, token_end):
    """取出一次 `.overlay` 调用的**完整内容**，并把「调用结束」的位置一起给出来。

    三种写法都要认（这个仓库里都有）：
        .overlay(视图)                 → 圆括号里的内容
        .overlay { … }                 → 尾随闭包
        .overlay(alignment: .top) { … } → 圆括号 + 尾随闭包

    返回 `(内容片段列表, 结束下标)`；结构不完整（括号没配平）时返回 `(None, -1)`，
    交给上层**跳过** —— 宁可漏报也不误报。返回**片段列表**而不是拼好的字符串，
    是因为后面要判断「这段 overlay 的**根视图**是什么」，得一片一片看。
    """
    length = len(code)
    pos = token_end
    while pos < length and code[pos] in " \t":
        pos += 1

    pieces = []
    if pos < length and code[pos] == "(":
        close = _paired_close(code, pos, "(", ")")
        if close < 0:
            return None, -1
        pieces.append(code[pos + 1:close])
        pos = close + 1
        while pos < length and code[pos] in " \t":
            pos += 1
    if pos < length and code[pos] == "{":
        close = _paired_close(code, pos, "{", "}")
        if close < 0:
            return None, -1
        pieces.append(code[pos + 1:close])
        pos = close + 1

    if not pieces:
        return None, -1        # `.overlay` 后面没跟调用（就是个名字），跳过
    return pieces, pos


def _overlay_roots(pieces):
    """从各片段里挑出**根视图表达式**（用来判断 overlay 直接盖上去的是什么）。

    `.overlay(alignment: .top)` 里的 `alignment: .top` 是**参数**不是视图 ——
    形如 `名字:` 开头的片段一律跳过；剩下的（闭包体 / 位置参数）取洗白后的开头。
    """
    roots = []
    for piece in pieces:
        text = piece.strip()
        if not text:
            continue
        if re.match(r"^[A-Za-z_]\w*\s*:", text):
            continue                      # `alignment: .top` 这类参数标签
        roots.append(text)
    return roots


def _overlay_following(code, call_end):
    """取「调用结束的当前行剩余部分 + 紧跟的下一行」。

    父层补的 `.allowsHitTesting(false)` 常写成：
        .overlay { … }
        .allowsHitTesting(false)
    所以下一行必须一起看。
    """
    first_newline = code.find("\n", call_end)
    if first_newline < 0:
        return code[call_end:]
    second_newline = code.find("\n", first_newline + 1)
    end = second_newline if second_newline >= 0 else len(code)
    return code[call_end:end]


def _overlay_danger(body, pieces):
    """这段 overlay 内容会不会「吃掉点击」？返回 `(是否危险, 原因)`。

    判据（**只认 `.overlay`，`.background` 在内容下面、不吃点击，一律不看**）：

      1. 有 `.fill(`：
           · 外面套了 `.frame(` 尺寸约束的（细线/小块）→ 安全；
           · 否则 → **危险**。这是那次事故的写法，**描边也救不回来**
             （同一段里既有 `.fill(` 又有 `.strokeBorder(` 的，仍按 `.fill(` 算）。
      2. 有 `.stroke(`/`.strokeBorder(` → **安全**。描边只有那一圈线有命中区，
         老代码一直是这么写的，从没出过事；此时里面的 `Color` 是描边颜色，不算裸颜色。
      3. 裸 `Color(...)` / 材质 / 裸形状，**且它是这段 overlay 的根视图** → 危险。
         （嵌在 `.background(...)` 里、或当渐变色的 stop 的 `Color` **不算** ——
           那种 `Color` 不是盖在整张卡片上的那一层。这是零误报的关键。）
      都不满足 → 安全。
    """
    if _FILL_CALL.search(body):
        if _FRAME_CALL.search(body):
            return False, ""
        return True, "填充形状"
    if _OUTLINE_CALL.search(body):
        return False, ""
    for root in _overlay_roots(pieces):
        if _BARE_COLOR.match(root) or _MATERIAL.match(root):
            return True, "颜色/材质"
        if _SHAPE_CTOR.match(root):
            return True, "形状"
    return False, ""


def find_overlay_hit_test_issues(code):
    """纯函数：扫一段**已过 `strip_code`** 的代码，返回 `[(行号, 原因)]`。

    不碰全局状态，方便自测（`run_selftest`）直接喂字符串进来验。
    行号指向 `.overlay(` 那一行。
    """
    issues = []
    for match in re.finditer(r"\.overlay\b", code):
        pieces, call_end = _overlay_body(code, match.end())
        if pieces is None:
            continue
        body = "\n".join(pieces)
        # 放过：内容里带了 `.allowsHitTesting(false)`，或它紧跟在本调用之后。
        if (_ALLOWS_HIT_FALSE in body
                or _ALLOWS_HIT_FALSE in _overlay_following(code, call_end)):
            continue
        dangerous, reason = _overlay_danger(body, pieces)
        if dangerous:
            line = code[:match.start()].count("\n") + 1
            issues.append((line, reason))
    return issues


def check_overlay_hit_testing(sources):
    """R33：`.overlay` 里放了**填充形状/颜色**，却没加 `.allowsHitTesting(false)`。

    🔴 为什么值得单立一条（2026-10-06 事故，0.0.110 已经发到用户手上）：

        `.overlay` 是**盖在内容上面**的。而 SwiftUI 里**填充形状（以及 `Color`，
          包括 `Color.clear` / `.opacity(0)`）参与命中测试** —— 于是这一层把整张卡片的
          **点击 / 长按 / 滚动全吃掉了**。

        出事的那行（`GlassSurface.aevisGlass()` 里做顶部内高光）原来是：
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear], …))
            )
        `aevisGlass()` 是全 App 唯一的卡片入口（203 处 / 58 个文件）⇒
        症状是**整机所有按钮都点不动、列表也划不动**
        （用户原话：「我一个按钮都点不动了」「用户协议划不动」）。

        老代码那层用的是 `strokeBorder` —— 只有那 0.5pt 的**边框**有命中区，所以一直没事；
        **改成 `fill` 就出事**。CI 的模拟器截图**抓不到**这种问题（截图只反映渲染，
        命中测试坏了图还是好的），所以只能靠静态检查按在本地。

    修法：装饰层加 `.allowsHitTesting(false)`（推荐），或改用 `.strokeBorder`，
    或干脆把它移到 `.background` 里（background 在内容下面，不吃点击）。

    为了**零误报**，刻意收窄：
      · 只查 `.overlay`，**不查 `.background`**；
      · 带 `.stroke(` / `.strokeBorder(` 的算安全（边框命中区只有那一圈）；
      · 内容里（或紧跟其后一行）有 `.allowsHitTesting(false)` 的一律放过。
    """
    for path, source in sorted(sources.items()):
        code = strip_code(source)
        for line, reason in find_overlay_hit_test_issues(code):
            report(
                "R33", path, line,
                "这层 .overlay 用了%s —— 填充形状/颜色**参与命中测试**，会盖在内容上把"
                "整张卡片的点击/长按/滚动全吃掉。装饰请加 `.allowsHitTesting(false)`，"
                "或改用 `.strokeBorder`，或把它放进 `.background` 里" % reason
            )


def find_device_name_non_ascii(source):
    """在 `AevisDevice.names` 那张机型表里找出**值含非 ASCII** 的条目。

    返回 `[(行号, 值)]`。抽成纯函数是为了自带自测（`run_selftest` 直接喂字符串进来）。

    ⚠️ 取「声明行 `[` 之后的部分」必须用 **`rsplit`** —— 声明是
       `let names: [String: String] = [`，里面**先出现一个 `]`**（类型标注那个）。
       用 `split("[", 1)[1]` 会拿到 `String: String] = [`，于是
       「本行含 `]` ⇒ 表到此结束」当场成立、整个表一行都没查
       （自测一跑就红，2026-10-06 我自己栽的）。
    """
    hits = []
    inside = False
    for number, line in enumerate(source.splitlines(), 1):
        if not inside:
            if "private static let names: [String: String] = [" not in line:
                continue
            inside = True
            body = line.rsplit("[", 1)[1]
        else:
            body = line
        for match in re.finditer(r'"([^"]*)"\s*:\s*"([^"]*)"', body):
            value = match.group(2)
            if any(ord(ch) > 127 for ch in value):
                hits.append((number, value))
        if "]" in body:
            inside = False
    return hits


def check_device_name_non_ascii(path, source):
    """R34：会进 HTTP 头的设备名必须是纯 ASCII。

    **真踩过（2026-10-06）**：机型表里有一行写着 `iPhone SE（第 2 代）`
    （全角括号 + 中文）。这个值经 `DeviceIdentity.friendlyName` 塞进了请求头
    `X-Aevis-Device-Name`（见 `AccountService.request()`），而**HTTP 头只认 latin-1** ——
    值里有非 ASCII，请求就发不出去。
    表现极其难查：**只有 iPhone SE 2/3 的用户**账号功能全废，
    而代码里搜「中文」永远搜不到（因为那张表本来就叫"营销名"）。
    当时是用真请求打到服务器、撞出 `UnicodeEncodeError: latin-1` 才发现的。

    ⚠️ 反过来也成立：**HTTP 头里出现的任何字符串都必须纯 ASCII**。
       以后往请求头里加东西（UA、机型、语言…）都要照这条。
    """
    for number, value in find_device_name_non_ascii(source):
        report("R34", path, number,
               "机型名「%s」含非 ASCII 字符 —— 它要进 HTTP 头 `X-Aevis-Device-Name`，"
               "HTTP 头只认 latin-1，含中文会让该机型**所有账号请求**出错。"
               "改成纯 ASCII（例：iPhone SE (2nd gen)）" % value)


# ——— R35 用到的正则 ———
#
# `shortTitle: "上报电量"` —— App Shortcut 在系统「快捷指令」里显示的那个短名字。
# 设置页里那句用户可见的「有：…」清单，就是照着它手抄的。
_SHORT_TITLE = re.compile(r'\bshortTitle\s*:\s*"([^"]*)"')


def find_missing_short_titles(shortcuts_source, card_source):
    """把 `AppShortcuts.swift` 里声明的每个 `shortTitle` 拿去 `SystemBridgeCard.swift` 里找。

    返回**在界面清单里找不到**的那些 shortTitle（list，保序、可重复）。抽成纯函数是为了自带自测。

    ⚠️ 两个源都**不能 `strip_code()`** —— shortTitle 的值、以及界面那句清单，**都在字符串
       字面量里**，一去字符串就全变成空格了（R34 的机型表也是栽在同一个坑上）。
       只需要 `strip_comments()` 把注释去掉：某个名字只出现在注释里，不算"用户看得到"。
    """
    titles = _SHORT_TITLE.findall(strip_comments(shortcuts_source))
    card = strip_comments(card_source)
    missing = []
    for title in titles:
        if title and title not in card:
            missing.append(title)
    return missing


def check_shortcut_titles_in_card(sources):
    """R35：`Core/AppShortcuts.swift` 里每条 App Shortcut 的 `shortTitle`，都必须在
    `Features/Settings/SystemBridgeCard.swift` 的**用户可见清单**里出现。

    🔴 为什么值得单立一条（2026-10-06）：

        App Shortcut 是**代码里声明一次、随 App 安装就进系统「快捷指令」**的
        （免签名、免手搓，见 `AppShortcuts.swift` 顶部）。而设置页里那句
        「有：上报电量、上报位置、…」是**用户唯一能一眼看到"Aevis 有哪些现成动作"的地方**。

        这两处是**手抄**的 —— 加了一条动作、忘了往清单里补；或者清单在抄的时候就漏了
        （这次的真 bug：清单漏了「上报屏幕时间」）。结果是：**动作是好的、真能跑，
        但用户永远不知道它存在**（点 `ShortcutsLink` 也能翻到，但那要他主动去翻）。
        这类"漏了等于没做"的错，静态检查最该按死在本地。

    ⚠️ 判据是"shortTitle 作为**子串**出现在 SystemBridgeCard 里" —— 那句清单是中文散文
       （「有：…」），不是逐字罗列短标题，所以按子串找、**不要求整句相等**。
       文件找不到就**报出来**（规则本身失效别默默跳过，同 R30）。
    """
    shortcuts_path = card_path = None
    for path in sources:
        norm = path.replace("\\", "/")
        if norm.endswith("Aevis/Core/AppShortcuts.swift"):
            shortcuts_path = path
        elif norm.endswith("Aevis/Features/Settings/SystemBridgeCard.swift"):
            card_path = path

    if shortcuts_path is None:
        report("R35", "Aevis/Core/AppShortcuts.swift", 0,
               "找不到这个文件 —— 规则本身失效了，别默默跳过")
        return
    if card_path is None:
        report("R35", "Aevis/Features/Settings/SystemBridgeCard.swift", 0,
               "找不到这个文件 —— 规则本身失效了，别默默跳过")
        return

    for title in find_missing_short_titles(sources[shortcuts_path], sources[card_path]):
        report("R35", card_path, 0,
               "App Shortcut 的 shortTitle「%s」没在设置页的清单里出现 —— "
               "动作是好的、也真能跑，但**用户看不到它**。"
               "去 `builtInActions` 那句「有：…」里补上" % title)


# ——— R34 自带自测（同项目硬规矩）———

R34_SELFTEST_POSITIVE = [
    # 事故原样：全角括号 + 中文
    '''
    private static let names: [String: String] = [
        "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE（第 2 代）",
    ]
    ''',
    # 单个值就是中文
    '''
    private static let names: [String: String] = [
        "iPhone14,6": "第二代 SE",
    ]
    ''',
    # 中间夹杂的非 ASCII（不是全角括号也会中）
    '''
    private static let names: [String: String] = [
        "iPhone99,9": "iPhone 20 Pro·Max",
    ]
    ''',
]

R34_SELFTEST_NEGATIVE = [
    # 修好之后的写法
    '''
    private static let names: [String: String] = [
        "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone14,6": "iPhone SE (3rd gen)",
    ]
    ''',
    # 表外的中文注释 / 中文 key 说明都不能误报（只查值）
    '''
    /// 这张表里的值必须是纯 ASCII（中文注释随便写）
    private static let names: [String: String] = [
        "iPhone17,4": "iPhone 16 Plus"
    ]
    ''',
    # 根本不是这张表
    '''
    private static let labels: [String: String] = [
        "a": "中文字典"
    ]
    ''',
]


# ——— R35 自带自测（同项目硬规矩）———
#
# 正例 = 清单里漏了某条 shortTitle ⇒ **必须**报出来。
# 反例 = 清单里都有 / 或压根没有 shortTitle ⇒ **绝不许**报。
# 每个元素是 `(AppShortcuts 片段, SystemBridgeCard 片段)`，直接喂给
# `find_missing_short_titles`，不依赖真实文件，跑到哪都是同一套判据。

R35_SELFTEST_POSITIVE = [
    # 这次修的那个**真 bug 的形状**：清单漏了「上报屏幕时间」
    (
        '''
        AppShortcut(intent: ReportScreenTimeIntent(), phrases: [], shortTitle: "上报屏幕时间", systemImageName: "hourglass")
        ''',
        "有：上报电量、上报位置、上报设备信息、上报健康、打开 Aevis、告诉ta我在干嘛。",
    ),
    # 新加了一条动作，清单一个字没动
    (
        '''AppShortcut(intent: X(), phrases: [], shortTitle: "发个红包", systemImageName: "yensign")''',
        "有：上报电量、上报位置。",
    ),
    # 多条里只漏了**中间**那一条
    (
        '''shortTitle: "打开通话"\nshortTitle: "一起听"\nshortTitle: "问今天"''',
        "有：打开通话、一起听。",
    ),
]

R35_SELFTEST_NEGATIVE = [
    # 都在清单里（清单是散文，按子串命中即可）
    (
        '''shortTitle: "上报电量"\nshortTitle: "上报位置"\nshortTitle: "我在干嘛"''',
        "有：上报电量、上报位置、告诉ta我在干嘛。",
    ),
    # 清单写的是「上报设备信息」、shortTitle 是「设备信息」—— 子串命中，**不许报**
    (
        '''shortTitle: "设备信息"''',
        "有：上报设备信息。",
    ),
    # `title:`（LocalizedStringResource 的标题）**不是** shortTitle，别拿它当依据
    (
        '''static var title: LocalizedStringResource = "把电量发给 Aevis"''',
        "有：上报电量。",
    ),
]


# ——— R33 自带自测（本项目的硬规矩：防回归规则必须自带自测）———
#
# 触发：`python3 tools/swift_check.py --selftest`
#
# 正例 = 必须要报出来的写法（含 0.0.110 那次事故的原样代码）。
# 反例 = 绝不能误报的写法（描边 / 有 allowsHitTesting / 在 background 里 / 纯视图）。
# 直接喂给 `find_overlay_hit_test_issues`，不依赖真实文件，跑到哪都是同一套判据。

R33_SELFTEST_POSITIVE = [
    # 0.0.110 事故原样：填充形状 + LinearGradient
    '''
    .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.22), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            )
    )
    ''',
    # 整块纯色遮罩
    ".overlay(Color.black.opacity(0.3))",
    # 尾随闭包里的填充形状
    ".overlay { Rectangle().fill(.blue) }",
    # alignment + 尾随闭包里的裸形状
    ".overlay(alignment: .top) { Capsule() }",
    # alignment + 尾随闭包里的裸颜色（根视图就是 Color）
    ".overlay(alignment: .top) { Color.black.opacity(0.4) }",
    # fill 和 strokeBorder 同时出现 → 仍按 fill 算
    ".overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white, lineWidth: 1).fill(.red))",
    # 材质
    ".overlay(.ultraThinMaterial)",
]

R33_SELFTEST_NEGATIVE = [
    # 描边（老写法，一直没事）
    ".overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))",
    # 只有 stroke（探针 App 里就是这么写的）
    ".overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.35), lineWidth: 1))",
    # 内容里带了 allowsHitTesting(false)（修好之后的 GlassSurface）
    '''
    .overlay(
        RoundedRectangle(cornerRadius: radius)
            .fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
            .allowsHitTesting(false)
    )
    ''',
    # 父层在**下一行**补的 allowsHitTesting(false)
    '''
    .overlay(
        RoundedRectangle(cornerRadius: radius).fill(.red)
    )
    .allowsHitTesting(false)
    ''',
    # 父层在**同一行**补的
    ".overlay { Rectangle().fill(.blue) }.allowsHitTesting(false)",
    # 在 background 里 —— 内容下面，不吃点击，一律不看
    ".background(RoundedRectangle(cornerRadius: 16).fill(material))",
    ".background(Color.black.opacity(0.4))",
    # 图片 / 纯视图，本来就没问题
    ".overlay(Image(uiImage: image).resizable().scaledToFill())",
    ".overlay(scrimBackground)",
    ".overlay(alignment: .top) { island.padding(.top, 17) }",
    ".overlay(Text(\"hi\").font(.aevis(11)))",
    # 注释里提到 overlay 也不算（strip_code 会把注释变空）
    "// .overlay(RoundedRectangle(cornerRadius: 8).fill(.red))",
    # ——— 仓库里真实存在、但**不该**误报的三种写法（都被首轮打脸过，务必钉住）———
    # ① AdminStyle 顶部提示条：Color 嵌在子视图的 .background 里，根视图是 if-let
    '''
    .overlay(alignment: .top) {
        if let toast = store.toast {
            Text(toast)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.88))
                .clipShape(Capsule())
        }
    }
    ''',
    # ② MomentsView 封面渐隐：根视图是 LinearGradient，Color 只是渐变的色标
    '''
    .overlay(
        LinearGradient(
            colors: [Color.black.opacity(0.02), Color.black.opacity(0.55)],
            startPoint: .top, endPoint: .bottom
        )
    )
    ''',
    # ③ DisclaimerView 的分隔线：虽然有 .fill(，但被 .frame(height: 0.5) 限成一条细线
    '''
    .overlay(alignment: .top) {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
    }
    ''',
]


def run_selftest():
    """跑 R33 / R34 / R35 的正例 / 反例自测。返回进程退出码（0 = 全过）。"""
    failures = []
    for index, snippet in enumerate(R33_SELFTEST_POSITIVE, 1):
        if not find_overlay_hit_test_issues(strip_code(snippet)):
            failures.append("R33 正例 %d 没被报出来：%s"
                            % (index, snippet.strip().replace("\n", " ")[:70]))
    for index, snippet in enumerate(R33_SELFTEST_NEGATIVE, 1):
        hits = find_overlay_hit_test_issues(strip_code(snippet))
        if hits:
            failures.append("R33 反例 %d 被误报（行 %s）：%s"
                            % (index, [h[0] for h in hits],
                               snippet.strip().replace("\n", " ")[:70]))
    for index, snippet in enumerate(R34_SELFTEST_POSITIVE, 1):
        if not find_device_name_non_ascii(snippet):
            failures.append("R34 正例 %d 没被报出来：%s"
                            % (index, snippet.strip().replace("\n", " ")[:70]))
    for index, snippet in enumerate(R34_SELFTEST_NEGATIVE, 1):
        hits = find_device_name_non_ascii(snippet)
        if hits:
            failures.append("R34 反例 %d 被误报（行 %s）：%s"
                            % (index, [h[0] for h in hits],
                               snippet.strip().replace("\n", " ")[:70]))
    for index, (app_src, card_src) in enumerate(R35_SELFTEST_POSITIVE, 1):
        if not find_missing_short_titles(app_src, card_src):
            failures.append("R35 正例 %d 没被报出来：%s"
                            % (index, app_src.strip().replace("\n", " ")[:70]))
    for index, (app_src, card_src) in enumerate(R35_SELFTEST_NEGATIVE, 1):
        hits = find_missing_short_titles(app_src, card_src)
        if hits:
            failures.append("R35 反例 %d 被误报（%s）：%s"
                            % (index, hits, card_src.strip().replace("\n", " ")[:70]))

    print("R33 自测：正例 %d 个、反例 %d 个" % (
        len(R33_SELFTEST_POSITIVE), len(R33_SELFTEST_NEGATIVE)))
    print("R34 自测：正例 %d 个、反例 %d 个" % (
        len(R34_SELFTEST_POSITIVE), len(R34_SELFTEST_NEGATIVE)))
    print("R35 自测：正例 %d 个、反例 %d 个" % (
        len(R35_SELFTEST_POSITIVE), len(R35_SELFTEST_NEGATIVE)))
    if failures:
        for item in failures:
            print("  [FAIL] %s" % item)
        print("自测未通过（规则有误报或漏报，必须先修规则）")
        return 1
    print("自测通过")
    return 0


def main():
    sources = {}
    for path in swift_files():
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        sources[path] = source
        code = strip_code(source)
        check_garbage(path, source)
        check_traditional_chinese(path, source)
        check_device_name_non_ascii(path, source)
        check_balance(path, source, code)
        # 下面这些都只看「代码」——注释和字符串里提到关键字不算问题
        check_scaled_to_fill(path, code)
        check_ternary_style_types(path, code)
        check_double_spacer(path, source, code)
        check_nsexpression(path, code)
        check_cf_memory(path, code)
        check_eventkit_permissions(path, code)
        check_font_leftovers(path, code)
        check_photos_picker_tint(path, code)
        check_debug_guard(path, code)
        check_conditional_balance(path, code)
        check_string_quote_leak(path, source)
        check_quote_parity(path, source)
        check_unicode_charset_in_url(path, code)

    localized = collect_localized_names(sources)
    for path, source in sources.items():
        check_markdown_in_strings(path, source, localized)

    types, shared = collect_definitions(sources)
    declared = collect_declared_names(sources)
    check_shared_references(sources, types, shared)
    check_instance_member_on_type(sources, shared)
    check_member_on_model(sources, collect_members(sources))
    check_card_usage(sources, types)
    check_member_references(sources, types, declared)
    check_property_scope(sources)
    check_optional_suffix_use(sources)
    check_keychain_labels(sources)
    check_uiimage_resizable(sources)
    check_mainactor_state(sources)
    check_pairchannel_base(sources)
    check_append_listener(sources)
    check_overlay_hit_testing(sources)
    check_shortcut_titles_in_card(sources)
    check_line_endings()

    # 会让整条 CI 挂掉的配置类文件也一起验
    check_info_plist()
    check_app_group_wiring()
    check_yaml_files()

    notes.append("扫描 %d 个 Swift 文件，定义 %d 个类型" % (len(sources), len(types)))

    for note in notes:
        print(note)
    print()

    if not problems:
        print("没有发现问题。")
        return 0

    current = None
    for rule, path, line, message in sorted(problems):
        if rule != current:
            print("【%s】" % rule)
            current = rule
        where = "%s:%d" % (path, line) if line else path
        print("  %-58s %s" % (where, message))

    print("\n合计 %d 处，需要人工确认。" % len(problems))
    return 1


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(run_selftest())
    sys.exit(main())
