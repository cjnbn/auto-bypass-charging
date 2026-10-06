#!/system/bin/sh
# late_start service 阶段由 ksud 以 NoWait 方式拉起，本身就是常驻进程，
# 因此不需要再嵌套一层后台化，也不需要用 PID 文件做防重复。
MODDIR=${0%/*}
exec sh "$MODDIR/auto_bypass.sh"
