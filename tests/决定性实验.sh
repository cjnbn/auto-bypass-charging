#!/system/bin/sh
# 决定性实验：在 80~88% 的"泵全速"窗口里，能不能拿到真旁路？
#   A) 先写 current_cmd=[0 1]（预期无效）
#   B) 再写 en_power_path=1  -> 看泵会不会死、电池会不会闲置（若成 = 找到绕开泵的办法）
#   C) 再写 night_charging=1 + chmod 440，观察 3 分钟看框架会不会把值重置回去
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
M=/proc/mtk_battery_cmd
P=/sys/class/power_supply/cp_master/cp_ibus
N=$B/night_charging
LOG=/data/local/tmp/pptest.log
DONE=/data/local/tmp/pptest.done
: > "$LOG"; rm -f "$DONE"

say() { echo "$1" >> "$LOG"; echo "$1"; }
sam() {
  line="$(date +%H:%M:%S) $1 cap=$(cat $B/capacity) ibat=$(cat $B/current_now) usb_on=$(cat $U/online) usb_in=$(cat $U/input_current_now) cp=$(cat $P) en_pp=$(cat $M/en_power_path) cmd=[$(cat $M/current_cmd)] night=$(cat $N)"
  echo "$line" >> "$LOG"; echo "$line"
}
phase() { i=0; n=$(( $2 / $3 )); while [ "$i" -le "$n" ]; do sam "$1"; [ "$i" -lt "$n" ] && sleep "$3"; i=$(( i + 1 )); done; }

finish() {
  say ""
  say "===== 收尾还原 ====="
  chmod 660 $N 2>/dev/null
  printf '%s\n' 0 > $N 2>/dev/null
  chmod 644 $N 2>/dev/null
  printf '%s\n' 0 > $B/input_suspend 2>/dev/null
  printf '%s\n' 0 > $U/input_suspend 2>/dev/null
  printf '%s\n' "0 0" > $M/current_cmd 2>/dev/null
  say "  读回: night=$(cat $N) mode=$(ls -l $N | cut -c1-10) batt_suspend=$(cat $B/input_suspend) usb_suspend=$(cat $U/input_suspend) current_cmd=[$(cat $M/current_cmd)] en_pp=$(cat $M/en_power_path)"
  say "  重启守护进程..."
  sh /data/adb/modules/bypass_charger/bypassctl.sh restart >> "$LOG" 2>&1
  say "DONE $(date '+%F %T')"
  echo DONE > "$DONE"
}
trap finish EXIT INT TERM HUP

say "===== 决定性实验开始 $(date '+%F %T') ====="
say "环境: cap=$(cat $B/capacity) ibat=$(cat $B/current_now) cp=$(cat $P) en_pp=$(cat $M/en_power_path) cmd=[$(cat $M/current_cmd)] night=$(cat $N)"

PID=$(cat /data/adb/bypass_charger/daemon.pid 2>/dev/null)
say "停守护进程 pid=$PID"
[ -n "$PID" ] && kill "$PID" 2>/dev/null
sleep 3
say "  PID 文件现在: $(cat /data/adb/bypass_charger/daemon.pid 2>/dev/null || echo '(已消失)')"

say ""
say "===== A) 泵下写 current_cmd=[0 1]（预期无效）====="
printf '%s\n' "0 1" > $M/current_cmd
say "  读回=[$(cat $M/current_cmd)]"
phase "A" 20 5

say ""
say "===== B) 关键：写 en_power_path=1，看泵会不会死、电池会不会闲置 ====="
printf '%s\n' 1 > $M/en_power_path
say "  写 rc=$? 读回=$(cat $M/en_power_path)"
phase "B" 60 5

say ""
say "===== C) night_charging=1 + chmod 440，观察 3 分钟看框架会不会重置它 ====="
printf '%s\n' 1 > $N 2>/dev/null
say "  写 rc=$? 读回=$(cat $N)"
chmod 440 $N 2>/dev/null
say "  权限=$(ls -l $N | cut -c1-10)"
phase "C" 180 15

exit 0
