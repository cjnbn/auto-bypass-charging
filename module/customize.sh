#!/system/bin/sh
# 安装器会 source 这个脚本，$MODPATH 就是模块目录。
# KernelSU 默认给模块内文件 0644，这里把要执行的脚本显式改成 0755。
for f in service.sh auto_bypass.sh uninstall.sh bypassctl.sh; do
  [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f"
done
