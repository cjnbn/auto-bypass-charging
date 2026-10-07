#!/system/bin/sh
# ============================================================================
# 停充兜底（保活第 ④ 条，v12.9）验证脚本
#
# 什么时候跑：电量 <80%、接着原装快充头（PD 给高压、充电泵全速）的时候。
# 用法（电脑侧）：
#     adb push 停充验证.sh /data/local/tmp/sc.sh
#     adb shell su -c 'sh /data/local/tmp/sc.sh'
#
# 它会做什么：
#   1) 打印基线与条件（电量/泵/PD 电压），把模式切成「手动旁路」（无视阈值，必定尝试进旁路）
#   2) 每 5 秒采样（ibat / usb_on / input_suspend / cp_ibus / cmd / en_pp），并打印模块新写的日志
#   3) 判定三件事：日志有没有出现「改为停充兜底」、status 里 STOPCHARGE 是不是 1、ibat 是不是不再为负
#   4) 收尾：把停充释放掉（bypassctl off）、模式还原 auto，并确认 input_suspend 回到 0
#
# 注意：脚本里不出现模块脚本的文件名（那是 restart 自杀陷阱的触发词）。
# ============================================================================
M=/data/adb/modules/bypass_charger
S=/data/adb/bypass_charger
B=/sys/class/power_supply/battery
CTL="$M/bypassctl.sh"

sam() {
  printf "%s %-7s cap=%-3s ibat=%-9s usb_on=%s usb_in=%-5s usb_v=%-6s cp=%-5s suspend=%s STOPCH=%s\n" \
    "$(date +%H:%M:%S)" "$1" "$(cat $B/capacity)" "$(cat $B/current_now)" \
    "$(cat /sys/class/power_supply/usb/online)" "$(cat /sys/class/power_supply/usb/input_current_now)" \
    "$(cat /sys/class/power_supply/usb/voltage_now)" "$(cat /sys/class/power_supply/cp_master/cp_ibus)" \
    "$(cat /sys/class/power_supply/usb/input_suspend)" "$([ -f $S/stopcharge ] && echo 1 || echo 0)"
}
newlog() {   # 打印日志里新增的部分（日志会被模块截到 30 行，所以用"记下末尾行内容"的办法）
  tail -n 6 "$S/run.log" 2>/dev/null | sed 's/^/        | /'
}

echo "=== 0) 前置条件 ==="
printf "  电量=%s%%  充电器 online=%s  usb_volt=%s mV  cp_ibus=%s  模式=%s\n" \
  "$(cat $B/capacity)" "$(cat /sys/class/power_supply/usb/online)" \
  "$(cat /sys/class/power_supply/usb/voltage_now)" "$(cat /sys/class/power_supply/cp_master/cp_ibus)" "$(cat $S/mode)"
if [ "$(cat /sys/class/power_supply/usb/online)" != "1" ]; then
  echo "  ⚠️ 充电器没插，测不了。插上原装快充头再跑。"; exit 1
fi
if [ "$(cat /sys/class/power_supply/usb/voltage_now)" -lt 8000 ] 2>/dev/null; then
  echo "  ⚠️ PD 只给了 $(cat /sys/class/power_supply/usb/voltage_now) mV（<8V），充电泵起不来，走不到第 ④ 条。"
  echo "     这种情况用 current_cmd 就能真旁路（不需要停充），换原装线/口重插再看。"
fi
echo ""
echo "=== 1) 基线 + 切手动旁路，然后盯 4 分钟 ==="
sam "基线"
sh "$CTL" mode on 2>&1 | tail -1

i=0
seen_log=0
while [ $i -lt 48 ]; do
  sam "观察"
  tail -n 3 "$S/run.log" 2>/dev/null | grep -q 停充兜底 && seen_log=1
  sleep 5
  i=$((i+1))
done

echo ""
echo "=== 2) 判定 ==="
printf "  日志出现「改为停充兜底」: %s\n" "$([ "$seen_log" = "1" ] && echo 是 ✔ || echo 否)"
printf "  STOPCHARGE 标记: %s\n" "$([ -f $S/stopcharge ] && echo "1 ✔（正在停充）" || echo 0)"
printf "  input_suspend=%s（1 = 正压住输入）\n" "$(cat /sys/class/power_supply/usb/input_suspend)"
printf "  ibat=%s（>0 = 电池在供电/不再被充；≈0 = 电池闲置）\n" "$(cat $B/current_now)"
echo "  最近日志："
newlog
echo ""
echo "=== 3) 收尾：释放停充 + 还原 auto ==="
sh "$CTL" off 2>&1 | tail -1
sleep 3
printf "  释放后 input_suspend=%s（应为 0）\n" "$(cat /sys/class/power_supply/usb/input_suspend)"
# 兜底：万一 off 没释放，手工写回 0，别让手机一直不充电
if [ "$(cat /sys/class/power_supply/usb/input_suspend)" = "1" ]; then
  printf '0\n' > /sys/class/power_supply/usb/input_suspend
  echo "  （手工补写 input_suspend=0）"
fi
sh "$CTL" mode auto 2>&1 | tail -1
sleep 4
sam "收尾"
