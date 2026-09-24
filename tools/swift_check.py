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

用法:
    python3 tools/swift_check.py            # 检查 Aevis/ 目录
"""

import os
import plistlib
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Aevis")
INFO_PLIST = os.path.join(ROOT, "Resources", "Info.plist")

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
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ("Resources", ".git")]
        for name in sorted(files):
            if name.endswith(".swift"):
                yield os.path.join(base, name)


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
    谁在命令行里带上参数就能改你的行为。"""
    lines = source.splitlines()
    for number, line in enumerate(lines, 1):
        if "ProcessInfo.processInfo.arguments" not in line:
            continue
        guarded = False
        for back in range(number - 1, max(-1, number - 8), -1):
            if "#if DEBUG" in lines[back - 1]:
                guarded = True
                break
            if "#endif" in lines[back - 1]:
                break
        if not guarded:
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
    """Info.plist 必须是合法 plist。

    格式错一个字符，`xcodebuild` 会直接失败，而且报错在构建日志深处。
    这里用标准库 plistlib 先解一遍，顺带确认那些**缺了就会崩**的权限键还在。
    """
    if not os.path.exists(INFO_PLIST):
        report("R15", INFO_PLIST, 0, "Info.plist 不存在")
        return
    try:
        with open(INFO_PLIST, "rb") as handle:
            data = plistlib.load(handle)
    except Exception as error:  # noqa: BLE001
        report("R15", INFO_PLIST, 0, "plist 解析失败：%s" % error)
        return

    # 用了对应框架就必须有这些键，否则一调用就崩（不是弹窗失败）
    required = {
        "NSCalendarsFullAccessUsageDescription": "EventKit",
        "NSRemindersFullAccessUsageDescription": "EventKit",
        "NSMicrophoneUsageDescription": "AVAudioEngine",
        "NSSpeechRecognitionUsageDescription": "SFSpeechRecognizer",
        "NSCameraUsageDescription": "UIImagePickerController",
        "NSLocationWhenInUseUsageDescription": "CLLocationManager",
        "NSHealthShareUsageDescription": "HKHealthStore",
    }
    sources = ""
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ("Resources", ".git")]
        for name in files:
            if name.endswith(".swift"):
                with open(os.path.join(base, name), encoding="utf-8") as handle:
                    sources += handle.read()

    for key, framework in required.items():
        if framework in sources and key not in data:
            report("R15", INFO_PLIST, 0, "用了 %s 但缺 %s（一调用就崩）" % (framework, key))


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
        check_eventkit_permissions(path, code)
        check_font_leftovers(path, code)
        check_photos_picker_tint(path, code)
        check_debug_guard(path, code)
        check_conditional_balance(path, code)
        check_string_quote_leak(path, source)

    types, shared = collect_definitions(sources)
    declared = collect_declared_names(sources)
    check_shared_references(sources, types, shared)
    check_card_usage(sources, types)
    check_member_references(sources, types, declared)

    # 会让整条 CI 挂掉的配置类文件也一起验
    check_info_plist()
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
