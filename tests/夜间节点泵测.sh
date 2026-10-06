#!/system/bin/sh
# 泵全速条件下测 battery/night_charging（用户打算保留的那个节点）
# 注意：这个循环不能内联进 su -c —— 内联时 shell 自己的 cmdline 含 auto_bypass.sh，会自杀
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
M=/proc/mtk_battery_cmd
P=/sys/class/power_supply/cp_master/cp_ibus
LOG=/data/local/tmp/nightpump.log
DONE=/data/local/tmp/nightpump.done
: > "$LOG"; rm -f "$DONE"

say() { echo "$1" >> "$LOG"; echo "$1"; }
sam() {
  line="$(date +%H:%M:%S) $1 cap=$(cat $B/capacity) ibat=$(cat $B/current_now) usb_on=$(cat $U/online) usb_in=$(cat $U/input_current_now) cp=$(cat $P) night=$(cat $B/night_charging)"
  echo "$line" >> "$LOG"; echo "$line"
}

finish() {
  say "===== 收尾 ====="
  printf '%s\n' 0     > $B/night_charging 2>/dev/null
  printf '%s\n' 0     > $B/input_suspend  2>/dev/null
  printf '%s\n' 0     > $U/input_suspend  2>/dev/null
  printf '%s\n' 1     > $M/en_power_path  2>/dev/null
  printf '%s\n' "0 1" > $M/current_cmd    2>/dev/null
  say "  读回: night=$(cat $B/night_charging) batt_suspend=$(cat $B/input_suspend) usb_suspend=$(cat $U/input_suspend) en_power_path=$(cat $M/en_power_path) current_cmd=[$(cat $M/current_cmd)]"
  sh /data/adb/modules/bypass_charger/bypassctl.sh restart >> "$LOG" 2>&1
  say "DONE $(date '+%F %T')"
  echo DONE > "$DONE"
}
trap finish EXIT INT TERM HUP

say "===== 泵全速下测 night_charging ====="
PID=$(cat /data/adb/bypass_charger/daemon.pid 2>/dev/null)
say "停守护进程 pid=$PID"
[ -n "$PID" ] && kill "$PID" 2>/dev/null
sleep 2
for p in /proc/[0-9]*; do
  case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in
    *auto_bypass.sh*) kill -9 "${p#/proc/}" 2>/dev/null ;;
  esac
done
sleep 1

say "--- 先进入正常充电 ---"
printf '%s\n' "0 0" > $M/current_cmd 2>/dev/null
sleep 8
sam "准备"

say "--- 叫泵：usb/input_suspend 1->0 触发 PD 重新协商 ---"
printf '%s\n' 1 > $U/input_suspend 2>/dev/null
sleep 6
printf '%s\n' 0 > $U/input_suspend 2>/dev/null
i=0
while [ $i -lt 8 ]; do
  sleep 3
  cpv=$(cat $P)
  case "$cpv" in ''|*[!0-9]*) cpv=0 ;; esac
  [ "$cpv" -gt 300 ] && break
  i=$(( i + 1 ))
done
sam "泵基线"

say "--- 泵全速下写 night_charging=1 ---"
printf '%s\n' 1 > $B/night_charging 2>/dev/null
say "  写 rc=$? 读回=[$(cat $B/night_charging)]"
i=0
while [ $i -lt 7 ]; do sam "泵+night1"; sleep 5; i=$(( i + 1 )); done

say "--- 还原 night_charging=0 ---"
printf '%s\n' 0 > $B/night_charging 2>/dev/null
i=0
while [ $i -lt 4 ]; do sam "还原后"; sleep 5; i=$(( i + 1 )); done

exit 0
