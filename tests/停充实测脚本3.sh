#!/system/bin/sh
# 第三轮：专攻「泵全速」窗口 + 补测被污染的两项
# 关键修正：
#   1) 错误文件放 /data/local/tmp（Android 没有可写的 /tmp，重定向失败会让命令根本不执行）
#   2) 每项测试前确认「正在充电」，测试后确认「已恢复充电」
#   3) 用 usb/input_suspend 1->0 触发 PD 重新协商，把充电泵叫回来（已复现 3 次）

B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
C=/sys/devices/platform/charger
M=/proc/mtk_battery_cmd
P=/sys/class/power_supply/cp_master/cp_ibus
E=/data/local/tmp/bz_werr
LOG=/data/local/tmp/stopchg3.log
DONE=/data/local/tmp/stopchg3.done

: > "$LOG"; rm -f "$DONE"

say() { echo "$1" >> "$LOG"; echo "$1"; }

w() {
  if printf '%s\n' "$2" > "$1" 2>"$E"; then
    say "     > 写 [$2] -> $1  rc=0  读回=[$(cat "$1" 2>/dev/null)]"
  else
    say "     > 写 [$2] -> $1  rc!=0 读回=[$(cat "$1" 2>/dev/null)] 错误=[$(cat "$E" 2>/dev/null)]"
  fi
}

sam() {
  line="$(date +%H:%M:%S) $1 cap=$(cat $B/capacity) ibat=$(cat $B/current_now) usb_on=$(cat $U/online) usb_in=$(cat $U/input_current_now) cp=$(cat $P)"
  echo "$line" >> "$LOG"; echo "$line"
}

phase() { i=0; n=$(( $2 / $3 )); while [ "$i" -le "$n" ]; do sam "$1"; [ "$i" -lt "$n" ] && sleep "$3"; i=$(( i + 1 )); done; }

charging() { case "$(cat $B/current_now)" in -*) return 0 ;; *) return 1 ;; esac; }

need_charging() {
  if charging; then say "     [检查] 充电中 ibat=$(cat $B/current_now)  ($1)"; else say "     [检查] !! 非充电态 ibat=$(cat $B/current_now) ($1)"; fi
}

# 把充电泵叫回来：短暂挂起 USB 输入再恢复，触发 PD 重新协商
engage_pump() {
  i=0
  while [ "$i" -lt 3 ]; do
    cpv=$(cat $P)
    case "$cpv" in ''|*[!0-9]*) cpv=0 ;; esac
    [ "$cpv" -gt 300 ] && say "     泵已在跑 cp=$cpv" && return 0
    say "     触发 PD 重新协商（当前 cp=$cpv）"
    printf '%s\n' 1 > $U/input_suspend 2>"$E"
    sleep 6
    printf '%s\n' 0 > $U/input_suspend 2>"$E"
    j=0
    while [ "$j" -lt 8 ]; do
      sleep 3
      cpv=$(cat $P)
      case "$cpv" in ''|*[!0-9]*) cpv=0 ;; esac
      [ "$cpv" -gt 300 ] && say "     泵已介入 cp=$cpv" && return 0
      j=$(( j + 1 ))
    done
    i=$(( i + 1 ))
  done
  say "     泵未能介入"
  return 1
}

restore_all() {
  say ""
  say "===== 最终还原（全部回到正常充电）====="
  printf '%s\n' 0     > $B/input_suspend  2>/dev/null
  printf '%s\n' 0     > $U/input_suspend  2>/dev/null
  printf '%s\n' 0     > $B/night_charging 2>/dev/null
  printf '%s\n' -1    > $C/input_current  2>/dev/null
  printf '%s\n' 1     > $M/en_power_path  2>/dev/null
  printf '%s\n' "0 1" > $M/current_cmd    2>/dev/null
  say "  读回: batt_suspend=$(cat $B/input_suspend) usb_suspend=$(cat $U/input_suspend) night=$(cat $B/night_charging) input_current=$(cat $C/input_current) en_power_path=$(cat $M/en_power_path) current_cmd=[$(cat $M/current_cmd)]"
  say "  重启守护进程..."
  sh /data/adb/modules/bypass_charger/bypassctl.sh restart >> "$LOG" 2>&1
  say "DONE $(date '+%F %T')"
  echo DONE > "$DONE"
}
trap restore_all EXIT INT TERM HUP

say "===== 第三轮 环境 ====="
say "cap=$(cat $B/capacity) ibat=$(cat $B/current_now) cp=$(cat $P) current_cmd=[$(cat $M/current_cmd)] input_current=$(cat $C/input_current) en_power_path=$(cat $M/en_power_path)"

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

# ================= A) 泵全速条件下写 battery/input_suspend =================
say ""
say "===== A) 泵全速条件下：battery/input_suspend 1->0 ====="
w $M/current_cmd "0 0"
sleep 8
need_charging "A 准备"
if engage_pump; then
  sam "泵基线"
  sleep 3
  sam "泵基线"
  w $B/input_suspend 1
  phase "泵+写1" 35 5
  w $B/input_suspend 0
  phase "泵+还原" 20 5
else
  say "  跳过 A（拿不到泵全速窗口）"
fi

# ================= B) 泵全速条件下写 usb/input_suspend =================
say ""
say "===== B) 泵全速条件下：usb/input_suspend 1->0 ====="
w $B/input_suspend 0
sleep 5
if engage_pump; then
  sam "泵基线"
  sleep 3
  sam "泵基线"
  w $U/input_suspend 1
  phase "泵+写1" 35 5
  w $U/input_suspend 0
  phase "泵+还原" 20 5
else
  say "  跳过 B（拿不到泵全速窗口）"
fi

# ================= C) 干净基线下重测 charger/input_current =================
say ""
say "===== C) 干净基线下重测 charger/input_current 100 -> -1 ====="
w $U/input_suspend 0
w $B/input_suspend 0
printf '%s\n' 0 > $M/current_cmd 2>/dev/null
sleep 10
need_charging "C 基线"
w $C/input_current 100
phase "写100" 45 5
w $C/input_current -1
phase "还原-1" 30 5
need_charging "C 还原后"

# ================= D) 干净基线下重测 battery/night_charging =================
say ""
say "===== D) 干净基线下重测 battery/night_charging 1 -> 0 ====="
need_charging "D 基线"
w $B/night_charging 1
phase "写1" 45 5
w $B/night_charging 0
phase "还原0" 30 5
need_charging "D 还原后"

exit 0
