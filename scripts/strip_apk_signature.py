#!/usr/bin/env python3
"""彻底移除 APK 中的签名痕迹（v1 签名文件 + v2/v3 APK Signing Block）。

背景
----
AGP 在 buildType 未配置 signingConfig 时会产出"未签名"APK，但打包流程仍可能残留：

  1. ``META-INF/*.SF``、``*.RSA``、``*.DSA``、``*.EC`` —— v1（JAR）签名文件；
  2. ``APK Signing Block``（魔数 ``APK Sig Block 42``）—— v2/v3 签名块，
     未签名时可能是一个**空占位块**。

第三方工具（MT 管理器、部分加固/校验脚本）只要看到这两类结构，就会显示"有 v2
签名"；而 ``apksigner verify`` 是权威判定，它会返回 ``DOES NOT VERIFY``。两者
结论互相矛盾，用户便会误以为"未签名包其实被签了名"。

原理
----
用标准库 ``zipfile`` 重写整个 ZIP 归档。``zipfile`` 只输出
「本地文件头 + 数据 + 中央目录 + EOCD」，**天然不会写回 APK Signing Block**，
所以重打包后 v2/v3 块一定消失；同时显式跳过 v1 签名文件。

压缩方式逐条目保留（STORED 保持 STORED，DEFLATED 保持 DEFLATED），
这样 ``.so`` 仍是未压缩存储，随后可用 ``zipalign -p -f 4`` 重新做页对齐。

注意
----
重打包会破坏 4 字节对齐，**调用方必须再跑一次 zipalign**，否则 APK 装不上或
运行时无法直接 mmap。

用法
----
    python3 scripts/strip_apk_signature.py path/to/app.apk

退出码
------
    0  剥离完成（或本来就没有签名痕迹）
    1  参数错误 / 文件不是合法 ZIP
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import zipfile

# v1（JAR）签名文件的扩展名
SIG_SUFFIXES = (".SF", ".RSA", ".DSA", ".EC")
# v2/v3 签名块尾部魔数
SIGNING_BLOCK_MAGIC = b"APK Sig Block 42"


def is_signature_entry(name: str) -> bool:
    """判断 zip 条目是否为 v1 签名文件。"""
    upper = name.upper()
    return upper.startswith("META-INF/") and upper.endswith(SIG_SUFFIXES)


def has_signing_block(path: str) -> bool:
    """流式检查文件里是否存在 APK Signing Block 魔数。"""
    magic = SIGNING_BLOCK_MAGIC
    overlap = len(magic) - 1
    tail = b""
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                return False
            buf = tail + chunk
            if magic in buf:
                return True
            tail = buf[-overlap:]


def strip(apk: str) -> int:
    removed: list[str] = []
    had_block = has_signing_block(apk)

    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".apk", dir=os.path.dirname(apk))
    os.close(tmp_fd)

    try:
        with zipfile.ZipFile(apk, "r") as src, \
                zipfile.ZipFile(tmp_path, "w", allowZip64=True) as dst:
            for info in src.infolist():
                if is_signature_entry(info.filename):
                    removed.append(info.filename)
                    continue
                # 逐条目复制，保留时间戳 / 权限位 / 压缩方式
                new_info = zipfile.ZipInfo(info.filename, date_time=info.date_time)
                new_info.compress_type = info.compress_type
                new_info.external_attr = info.external_attr
                new_info.internal_attr = info.internal_attr
                new_info.create_system = info.create_system
                with src.open(info, "r") as fin, \
                        dst.open(new_info, "w", force_zip64=True) as fout:
                    shutil.copyfileobj(fin, fout, 1024 * 1024)
        os.replace(tmp_path, apk)
    except zipfile.BadZipFile:
        print(f"错误: 不是合法 ZIP/APK: {apk}", file=sys.stderr)
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        return 1

    print(f"已重打包: {apk}")
    print(f"  移除 v1 签名文件 {len(removed)} 个"
          + (f": {', '.join(removed)}" if removed else ""))
    print(f"  APK Signing Block: {'存在 → 已清除' if had_block else '不存在'}")

    if has_signing_block(apk):
        print("错误: 重打包后仍检测到 APK Signing Block", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("用法: strip_apk_signature.py <apk>", file=sys.stderr)
        return 1

    apk = os.path.abspath(argv[1])
    if not os.path.isfile(apk):
        print(f"错误: 找不到文件: {apk}", file=sys.stderr)
        return 1

    with open(apk, "rb") as fh:
        head = fh.read(4)
    if head != b"PK\x03\x04":
        print(f"错误: 不是 ZIP/APK 文件: {apk}", file=sys.stderr)
        return 1

    return strip(apk)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
