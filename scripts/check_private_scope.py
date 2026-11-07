# -*- coding: utf-8 -*-
"""检查顶层函数/类外部代码是否误用了类内私有成员。

本轮 CI 真实报错就是这一类：_isDue 写在 BackupScheduler 类里，
却被顶层函数 runScheduledBackup 调用 → Method not found。
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


def class_bodies(clean):
    """返回 [(class 名, body 起, body 止)]。"""
    res = []
    for m in re.finditer(r'^(?:class|mixin|extension)\s+(\w+)', clean, re.M):
        i = clean.find('{', m.end())
        if i < 0:
            continue
        d, j = 0, i
        while j < len(clean):
            if clean[j] == '{':
                d += 1
            elif clean[j] == '}':
                d -= 1
                if d == 0:
                    break
            j += 1
        res.append((m.group(1), i, j))
    return res


DEFAULT_FILES = [
    'lib/services/backup/backup_scheduler.dart',
    'lib/services/backup/backup_local_store.dart',
    'lib/pages/settings/backup_page.dart',
    'lib/providers/settings_provider_backup.dart',
]


def main(argv):
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    files = argv[1:] if len(argv) > 1 else DEFAULT_FILES
    bad = 0
    for p in files:
        raw = io.open(p, encoding='utf-8').read()
        clean = strip_noise(raw)
        cls = class_bodies(clean)
        # 类内私有方法/字段名集合
        members = set()
        for name, lo, hi in cls:
            body = clean[lo:hi]
            for mm in re.finditer(r'\b_(?!_)(\w+)\b', body):
                members.add(mm.group(0))
        # 顶层区域 = 所有 class body 之外的字符
        mask = [True] * len(clean)
        for name, lo, hi in cls:
            for k in range(lo, hi + 1):
                mask[k] = False
        top = ''.join(clean[k] if mask[k] else ' ' for k in range(len(clean)))
        # 顶层里出现成员名且后跟 '(' → 疑似调用类内方法
        issues = []
        for mm in re.finditer(r'\b(_[a-zA-Z]\w*)\s*\(', top):
            nm = mm.group(1)
            # 顶层自己定义的函数不算
            if re.search(r'^\w[\w<>?, ]*\s+' + re.escape(nm) + r'\s*\(', top, re.M):
                continue
            line = top.count('\n', 0, mm.start()) + 1
            issues.append((line, nm))
        if issues:
            bad += len(issues)
            print('FAIL %s' % p)
            for ln, nm in issues:
                print('     line %-5d %s' % (ln, nm))
        else:
            print('OK   %s (%d classes)' % (p, len(cls)))
    print()
    print('RESULT:', 'ALL OK' if bad == 0 else '%d FAIL' % bad)
    return 0 if bad == 0 else 1


raise SystemExit(main(sys.argv))
