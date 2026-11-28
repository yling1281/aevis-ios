import pathlib

p = pathlib.Path("ChatScreen.kt")
s = p.read_text(encoding="utf-8")

old = '''            // 「＋」（2026-11-16）：照片 / 表情包。原来那个表情按钮收进这个菜单，
            // 跟微信一样 —— 一个入口管"发东西"，别在输入条上摆两三个圆按钮。
            Box(Modifier.size(40.dp)) {
                Box(
                    Modifier.fillMaxSize().clip(CircleShape)
                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                        .tapable { plusOpen = true },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        painterResource(R.drawable.ic_tab_plus), null,
                        tint = ink.copy(alpha = 0.6f), modifier = Modifier.size(18.dp)
                    )
                }
                DropdownMenu(expanded = plusOpen, onDismissRequest = { plusOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(tr("照片")) },
                        onClick = {
                            plusOpen = false
                            pickImage.launch(
                                PickVisualMediaRequest(
                                    ActivityResultContracts.PickVisualMedia.ImageOnly
                                )
                            )
                        }
                    )
                    DropdownMenuItem(
                        text = { Text(tr("表情包")) },
                        onClick = { plusOpen = false; emojiSheet = true }
                    )
                }
            }'''

new = '''            // 「＋」（2026-11-16，128）：改成微信式附件面板 —— 点它收起键盘、面板从下面升起。
            Box(
                Modifier.size(40.dp).clip(CircleShape)
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                    .tapable {
                        if (!plusOpen) {
                            runCatching { kb?.hide() }
                            plusOpen = true
                        } else plusOpen = false
                    },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    painterResource(R.drawable.ic_tab_plus), null,
                    tint = ink.copy(alpha = 0.6f),
                    // 展开时＋转成×，一眼知道再点会收起
                    modifier = Modifier.size(18.dp).rotate(if (plusOpen) 45f else 0f)
                )
            }'''

assert old in s, "plus button block not found"
s = s.replace(old, new)

old2 = '''            }
        }   // 输入条容器（不透明底 + 顶部 0.5dp 分割线）'''
new2 = '''            }
            // 128：附件面板（高 260dp，四列网格 + 最近图片横滑）
            androidx.compose.animation.AnimatedVisibility(
                visible = plusOpen,
                enter = androidx.compose.animation.expandVertically(
                    animationSpec = androidx.compose.animation.core.tween(200)
                ) + fadeIn(androidx.compose.animation.core.tween(160)),
                exit = androidx.compose.animation.shrinkVertically(
                    animationSpec = androidx.compose.animation.core.tween(170)
                ) + fadeOut(androidx.compose.animation.core.tween(120))
            ) {
                AttachmentPanel(
                    recent = recentShots,
                    onAlbum = {
                        plusOpen = false
                        pickPhotos.launch(
                            PickVisualMediaRequest(
                                ActivityResultContracts.PickVisualMedia.ImageOnly
                            )
                        )
                    },
                    onCamera = {
                        plusOpen = false
                        val u = runCatching {
                            val f = java.io.File(ctx.cacheDir, "cam_" + System.currentTimeMillis() + ".jpg")
                            f.createNewFile()
                            androidx.core.content.FileProvider.getUriForFile(
                                ctx, ctx.packageName + ".fileprovider", f
                            )
                        }.getOrNull()
                        if (u == null) {
                            Toast.makeText(ctx, "打不开相机", Toast.LENGTH_SHORT).show()
                        } else {
                            camUri = u
                            runCatching { takePicture.launch(u) }
                                .onFailure {
                                    Toast.makeText(ctx, "没有可用的相机", Toast.LENGTH_SHORT).show()
                                }
                        }
                    },
                    onFile = {
                        plusOpen = false
                        runCatching { pickDoc.launch(arrayOf("image/*")) }
                    },
                    onLocation = {
                        plusOpen = false
                        Toast.makeText(ctx, tr("暂不支持"), Toast.LENGTH_SHORT).show()
                    },
                    onEmoji = { plusOpen = false; emojiSheet = true },
                    onPickRecent = { u -> plusOpen = false; sendPhoto(u) }
                )
            }
        }   // 输入条容器（不透明底 + 顶部 0.5dp 分割线）'''
assert old2 in s, "input column end not found"
s = s.replace(old2, new2)

old3 = '''    var plusOpen by remember { mutableStateOf(false) }
    var recentShots'''
new3 = '''    var plusOpen by remember { mutableStateOf(false) }
    // 128：点＋要先把键盘收起来，面板才不会被顶上去
    val kb = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    var recentShots'''
assert old3 in s
s = s.replace(old3, new3)

old4 = '''                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                        onSend = { if (input.isNotBlank() && !sending) send() }
                    ),'''
new4 = '''                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                        onSend = { if (input.isNotBlank() && !sending) send() }
                    ),
                    // 128：点输入框就收起附件面板
                    modifier = Modifier.fillMaxWidth()
                        .onFocusChanged { st -> if (st.isFocused) plusOpen = false },'''
assert old4 in s
s = s.replace(old4, new4)

p.write_text(s, encoding="utf-8")
print("ok")
