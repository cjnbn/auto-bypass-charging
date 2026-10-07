#!/system/bin/sh
# ksud 在 late_start 阶段用 NoWait 把它拉起来，进程本身就是常驻的，
# 所以不用再套一层后台化，也不用 PID 文件防重复。
MODDIR=${0%/*}
exec sh "$MODDIR/auto_bypass.sh"
