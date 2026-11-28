import io

p = r'F:/WorkBuddy/2026-10-17-23-43-43/aevis-ios/android/app/src/main/java/com/aevis/android/ui/Screens.kt'
s = io.open(p, encoding='utf-8').read()

# ---------- A) MeTab：导出 / 导入 两行 ----------
anchor = '        SectionTitle("账号")'
rows = '''        // ---------- 聊天记录（2026-11-16）----------
        // 导出所有人都能用；导入**限会员**（不是会员时右侧挂「会员」标，点了也给一句人话，
        // 不是灰着不给反馈）。
        SectionTitle("聊天记录")
        CardGroup {
            RowItem(
                R.drawable.ic_row_diary, "导出聊天记录",
                "打包成 JSON 文件，可以发给自己存着", V2.accent,
                onClick = { exportChats(ctx, scope) }
            )
            RowDivider()
            RowItem(
                R.drawable.ic_row_layers, "导入聊天记录",
                if (isMember) "会覆盖这台设备上的聊天记录" else "开通会员后可用",
                V2.accent,
                trailing = if (isMember) "" else "会员",
                onClick = {
                    if (isMember) {
                        runCatching {
                            importLauncher.launch(arrayOf("application/json", "text/plain", "*/*"))
                        }
                    } else {
                        android.widget.Toast.makeText(
                            ctx, "开通会员后可用", android.widget.Toast.LENGTH_SHORT
                        ).show()
                    }
                }
            )
        }

''' + anchor
assert anchor in s, 'account section anchor missing'
s = s.replace(anchor, rows, 1)

# ---------- B) MeTab：状态 + 导出/导入实现 + 二次确认 ----------
old_state = '''    var balance by remember { mutableStateOf<Int?>(null) }'''
new_state = '''    var balance by remember { mutableStateOf<Int?>(null) }
    // 会员状态（导入功能限会员）
    var isMember by remember { mutableStateOf(false) }
    // 导入前读到的文本，等用户二次确认
    var pendingImport by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    // 导入：选文件 → 读文本 → 二次确认 → 覆盖写 + 推云备份
    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val txt = runCatching {
            ctx.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
        }.getOrNull()
        if (txt.isNullOrBlank()) {
            android.widget.Toast.makeText(
                ctx, "不是 Aevis 的聊天记录文件", android.widget.Toast.LENGTH_SHORT
            ).show()
            return@rememberLauncherForActivityResult
        }
        pendingImport = txt
    }'''
assert old_state in s, 'balance state anchor missing'
s = s.replace(old_state, new_state, 1)

# 会员状态：在 MeTab 的 LaunchedEffect 里顺带取
old_load = '''    LaunchedEffect(Unit) {
        balance = withContext(Dispatchers.IO) { Api.balance() }'''
new_load = '''    LaunchedEffect(Unit) {
        // 会员状态：导入功能限会员，这里一次取好
        withContext(Dispatchers.IO) {
            runCatching { Api.wallet() }.getOrNull()?.let { w ->
                isMember = w.member?.active == true
            }
        }
        balance = withContext(Dispatchers.IO) { Api.balance() }'''
assert old_load in s, 'metab load anchor missing'
s = s.replace(old_load, new_load, 1)

# 二次确认弹窗（加在 MeTab 的 Column 之后、函数结束前）
old_end = '''            RowItem(R.drawable.ic_row_font, "字体", "日记用哪个字体"'''
assert old_end in s, 'font row anchor missing'

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('MeTab rows + launcher done (part 1)')
