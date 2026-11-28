import io

base = r'F:/WorkBuddy/2026-10-17-23-43-43/aevis-ios/android/app/src/main/java/com/aevis/android/ui/'

HARD = """
                // 🔴 2026-11-16 硬性禁止（放**最末尾**：模型对 system 末尾最敏感）：
                // 云端那条模型会吐 `[物品：…]` + `状态/颜色/气味/大小` 这种字段清单，
                // 在气泡里就是一堆键值对。这里明确禁掉，要求用动作和感官描写。
                append("\\n【硬性禁止】\\n")
                append("不要在回复里输出任何方括号/书名号包裹的字段清单或卡片，包括但不限于：\\n")
                append("【物品：…】、[物品：…]、状态/颜色/气味/大小/样式 这类「键：值」罗列、\\n")
                append("以及用 ``` 包起来的结构化数据。\\n")
                append("物品、身体状态、环境，只能用**动作和感官描写**自然写进括号里，或直接写在对话里。\\n")
                append("违反这条视为格式错误。")

# ---- 单聊：拼在 sys 最后（玩梗规则段之后） ----
p = base + 'ChatScreen.kt'
s = io.open(p, encoding='utf-8').read()
anchor = """                append("禁用：user 情绪低落/真的生气、聊健康家庭工作危机等严肃话题、"
                       + "或说了不想玩梗时，一律不玩梗。")
            }"""
assert anchor in s, 'single sys anchor missing'
s = s.replace(anchor, anchor.replace("            }", HARD + "\n            }"), 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)

# ---- 群聊：每人 sys 最后 ----
p2 = base + 'GroupChatScreen.kt'
s2 = io.open(p2, encoding='utf-8').read()
anchor2 = """                    append("- 别人正在聊的话题你可以插一句，也可以只回半句，不要每句都抢。")
                }"""
assert anchor2 in s2, 'group sys anchor missing'
s2 = s2.replace(anchor2, anchor2.replace("                }", HARD + "\n                }"), 1)
io.open(p2, 'w', encoding='utf-8', newline='\n').write(s2)
print('sys hard-ban added to both')
