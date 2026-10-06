#!/system/bin/sh
# 本脚本由 KernelSU/Magisk 安装器 source 执行，$MODPATH 指向模块目录。
# KernelSU 默认把模块内文件设为 0644，这里把需要执行的脚本显式设为 0755。
for f in service.sh auto_bypass.sh uninstall.sh bypassctl.sh; do
  [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f"
done
