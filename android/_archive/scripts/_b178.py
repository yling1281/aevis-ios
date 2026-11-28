import io

p = 'app/src/main/java/com/aevis/android/ui/ChatSettingsSheet.kt'
s = io.open(p, encoding='utf-8').read()

old_row = ('            Row(\n'
           '                Modifier.fillMaxWidth()\n'
           '                    .horizontalScroll(rememberScrollState()),\n'
           '                horizontalArrangement = Arrangement.spacedBy(8.dp)\n'
           '            ) {')
new_row = ('            Row(\n'
           '                Modifier.fillMaxWidth()\n'
           '                    .height(40.dp)                      // 178：固定行高，防点芯片时整屏跳位\n'
           '                    .horizontalScroll(rememberScrollState()),\n'
           '                verticalAlignment = Alignment.CenterVertically,   // 178：固定高度后垂直居中\n'
           '                horizontalArrangement = Arrangement.spacedBy(8.dp)\n'
           '            ) {')
n = s.count(old_row)
assert n == 2, 'expect 2 chip rows, got %d' % n
s = s.replace(old_row, new_row)

# Chip 选中态不再改字重（只改颜色/底色），避免点击瞬间行宽/行高抖动
old_chip = '        label, fontSize = 12.sp, fontWeight = if (on) FontWeight.Medium else FontWeight.Normal,'
new_chip = ('        label, fontSize = 12.sp,\n'
            '        // 178：字重**固定**，选中态只改颜色和底色 —— 原来 on 时切 Medium 会引起重排/跳位\n'
            '        fontWeight = FontWeight.Medium,')
assert old_chip in s, 'chip weight anchor missing'
s = s.replace(old_chip, new_chip, 1)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched: 2 rows + chip weight')
