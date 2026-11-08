#!/usr/bin/env bash
# 本地静态自检：在没有 Flutter/Dart SDK 的环境里先扫一遍常见编译错误。
#
# 存在的理由：CI 一次构建要几分钟，而这两类错误（await 缺 async、
# 顶层函数误用类内私有成员）在纯文本层面就能查出来。先本地跑一遍，
# 能省掉一轮「推上去 → 等构建 → 读日志 → 改 → 再推」的往返。
#
# 用法：
#   bash scripts/check_dart_static.sh            # 检查默认文件清单
#   bash scripts/check_dart_static.sh a.dart b.dart   # 检查指定文件
set -u

cd "$(dirname "$0")/.." || exit 1

fail=0

echo "=== 1/2 await 必须处在 async 作用域内 ==="
python3 scripts/check_await_async.py "$@" || fail=1

echo
echo "=== 2/2 顶层函数不得调用类内私有成员 ==="
python3 scripts/check_private_scope.py "$@" || fail=1

echo
if [ "$fail" -eq 0 ]; then
  echo "RESULT: ALL OK"
else
  echo "RESULT: FAIL"
fi
exit "$fail"
