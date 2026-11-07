# -*- coding: utf-8 -*-
"""检查「方法体顶层」的 await 是否都有 async。

关键：Dart 里闭包可以自己带 async（onTap: () async {...}），
所以不能看到 await 就判错，必须识别嵌套的 async 作用域。
"""
import io
import os
import re
import sys


def strip_noise(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j; continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(''.join('\n' if ch == '\n' else ' ' for ch in src[i:j])); i = j; continue
        if src.startswith("'''", i) or src.startswith('"""', i):
            q = src[i:i + 3]
            j = src.find(q, i + 3)
            j = n if j < 0 else j + 3
            out.append(''.join('\n' if ch == '\n' else ' ' for ch in src[i:j])); i = j; continue
        if c in ('"', "'"):
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2; continue
                if src[j] == c:
                    j += 1; break
                if src[j] == '\n':
                    break
                j += 1
            out.append(''.join('\n' if ch == '\n' else ' ' for ch in src[i:j])); i = j; continue
        out.append(c); i += 1
    return ''.join(out)


SIG = re.compile(
    r'^(?P<indent>[ \t]*)(?:static\s+)?'
    r'(?P<ret>Future<[^>]*>|Stream<[^>]*>|void|bool|int|double|num|String|Widget|Color|'
    r'IconData|List<[^>]*>|Map<[^>]*>|Set<[^>]*>|DateTime\??|[A-Z]\w*\??)'
    r'\s+(?P<name>_?[a-zA-Z]\w*)\s*[(<]',
    re.M)


def brace_marks(clean, lo, hi):
    """返回 {位置: 是否是 async 作用域} （只看 lo..hi）。"""
    marks = {}
    for m in re.finditer(r'\{', clean[lo:hi]):
        pos = lo + m.start()
        # 往前跳过空白，看是否是 'async' 或 '=>'
        k = pos - 1
        while k >= lo and clean[k] in ' \t\n\r':
            k -= 1
        tail = clean[max(lo, k - 5):k + 1]
        marks[pos] = ('async' in tail) or tail.strip().endswith('=>')
    return marks


def check(path):
    raw = io.open(path, encoding='utf-8').read()
    clean = strip_noise(raw)
    fails, checked = [], 0
    for m in SIG.finditer(clean):
        line = clean.count('\n', 0, m.start()) + 1
        name = m.group('name')
        i, dp, body_open = m.end() - 1, 0, None
        while i < len(clean):
            ch = clean[i]
            if ch in '(<':
                dp += 1
            elif ch in ')>':
                dp -= 1
            elif ch == ';' and dp <= 0:
                break
            elif ch == '{' and dp <= 0:
                body_open = i; break
            i += 1
        if body_open is None:
            continue
        depth, j = 0, body_open
        while j < len(clean):
            if clean[j] == '{':
                depth += 1
            elif clean[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if depth != 0:
            fails.append((line, name, 'unbalanced')); continue
        checked += 1
        sig = clean[m.start():body_open]
        marks = brace_marks(clean, body_open, j)
        method_async = 'async' in sig
        if method_async:
            continue
        # 逐个 await，看它的 enclosing 花括号链里有没有 async 作用域
        bad = 0
        for am in re.finditer(r'\bawait\b', clean[body_open:j]):
            apos = body_open + am.start()
            stack = [p for p in marks if p < apos]
            stack.sort()
            # 只保留真正包围它的（用配对信息判断：简单起见用数量法）
            enclosing = []
            d = 0
            for k in range(body_open, apos):
                if clean[k] == '{':
                    d += 1
                    enclosing.append((d, k))
                elif clean[k] == '}':
                    d -= 1
                    if enclosing and enclosing[-1][0] > d:
                        enclosing = [e for e in enclosing if e[0] <= d]
            if not any(marks.get(p, False) for _, p in enclosing):
                bad += 1
        if bad:
            fails.append((line, name, '%d await without async scope' % bad))
    return checked, fails


DEFAULT_FILES = [
    'lib/models/backup/backup_item.dart',
    'lib/services/backup/backup_collectors.dart',
    'lib/services/backup/backup_local_store.dart',
    'lib/services/backup/backup_scheduler.dart',
    'lib/models/settings/backup_settings.dart',
    'lib/core/app/app_paths.dart',
    'lib/providers/settings_provider_backup.dart',
    'lib/pages/settings/backup_page.dart',
]


def main(argv):
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    files = argv[1:] if len(argv) > 1 else DEFAULT_FILES
    bad = 0
    for p in files:
        checked, fails = check(p)
        if fails:
            bad += len(fails)
            print('FAIL %s' % p)
            for ln, nm, why in fails:
                print('     line %-5d %-24s %s' % (ln, nm, why))
        else:
            print('OK   %-52s %3d methods' % (p, checked))
    print()
    print('RESULT:', 'ALL OK' if bad == 0 else '%d FAIL' % bad)
    return 0 if bad == 0 else 1


raise SystemExit(main(sys.argv))
