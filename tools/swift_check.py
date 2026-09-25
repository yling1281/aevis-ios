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

（R10–R19 的由来写在各自函数的 docstring 里，这里只列最先立起来的那批。）

用法:
    python3 tools/swift_check.py            # 检查 Aevis/ 目录
"""

import os
import plistlib
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Aevis")
INFO_PLIST = os.path.join(ROOT, "Resources", "Info.plist")
PROJECT = os.path.dirname(ROOT)

# 除了主 App，还要扫「系统录屏扩展」那个 target 的源码。
# 它虽然是个独立 target，但一样是 Swift、一样会编不过 ——
# 漏掉它等于漏一半，而它恰恰是更难在真机上调试的那一半。
SWIFT_ROOTS = [
    ROOT,
    os.path.join(PROJECT, "Broadcast"),
]

# 每个 target 的 Info.plist 都要验。
# 扩展那份写错一个键，表现是「系统录屏列表里根本没有 Aevis」——
# 编译能过、装也装得上、界面上不报任何错，属于最难查的一类。
INFO_PLISTS = {
    INFO_PLIST: "Aevis",
    os.path.join(PROJECT, "Broadcast", "Info.plist"): "AevisBroadcast",
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

    这条规则原来有个盲点：开头写着 `if source.count(".aevis(") < 3: return` ——
    于是**一处都没接字体系统的文件反而被整个跳过**（真的漏掉了 VoiceSettingsCard，
    用户换字体时那一页的字不会跟着变）。正好漏掉最该查的那些，所以去掉了这个阈值。

    但 SF Symbol 图标用系统字号是**故意**的 —— 图标不该跟着正文字体变，要放过。
    """
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
    r"""`**加粗**` 只在 `Text(LocalizedStringKey(…))` 或 `Text("字面量")` 里生效，
    直接 `Text(变量)` 会把星号原样显示。

    真踩过：截图里出现「但**快捷指令可以**」—— 那句话是 `static let` 存好的
    字符串，直接 `Text(那个变量)` 显示的，markdown 没被解析。

    两个必须放过的，不然这条规则会天天误报然后被无视：
    1. **喂给模型的工具描述**（`description:` / `instruction =`）——
       提示词里写 markdown 不影响；
    2. **只由星号组成的字符串**（`"**"`）—— 那是用来删星号的记号，不是文案。
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
                benign = header.startswith("description:") or "instruction = " in header
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
            if _looks_like_prose(literal) and not re.search(r"\bText\(\s*$", before):
                report("R17", path, number,
                       "这个字符串有 ** 加粗，但不是 Text 字面量，星号会原样显示")
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


def main():
    sources = {}
    for path in swift_files():
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        sources[path] = source
        code = strip_code(source)
        check_garbage(path, source)
        check_balance(path, source, code)
        # 下面这些都只看「代码」——注释和字符串里提到关键字不算问题
        check_scaled_to_fill(path, code)
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
    check_card_usage(sources, types)
    check_member_references(sources, types, declared)
    check_property_scope(sources)
    check_optional_suffix_use(sources)
    check_keychain_labels(sources)
    check_uiimage_resizable(sources)

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
    sys.exit(main())
