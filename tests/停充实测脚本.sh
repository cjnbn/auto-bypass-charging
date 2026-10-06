#!/system/bin/sh
# 停充方案（二类节点）逐个实测
# 前提：守护进程必须先停 —— 它在背后写 current_cmd，不隔离无法判定因果（实测记录 §12.2）
# 每个节点：基线 → 写停充值 → 观察 60s → 还原 → 观察 45s
# 结束时无条件还原全部节点并重启守护进程（trap）

B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
C=/sys/devices/platform/charger
M=/proc/mtk_battery_cmd
P=/sys/class/power_supply/cp_master/cp_ibus
LOG=/data/local/tmp/stopchg.log
DONE=/data/local/tmp/stopchg.done

: > "$LOG"
rm -f "$DONE"

say() {
  echo "$1" >> "$LOG"
  echo "$1"
}

w() {   # $1=节点 $2=值
  if printf '%s\n' "$2" > "$1" 2>/dev/null; then
    say "     > 写 [$2] 到 $1   读回=[$(cat "$1" 2>/dev/null)]"
  else
    say "     > 写入失败 [$2] -> $1"
  fi
}

sam() { # $1=标签
  local line
  line="$(date +%H:%M:%S) $1 cap=$(cat $B/capacity) ibat=$(cat $B/current_now) usb_on=$(cat $U/online) usb_in=$(cat $U/input_current_now) cp=$(cat $P)"
  echo "$line" >> "$LOG"
  echo "$line"
}

phase() { # $1=标签 $2=总秒数 $3=间隔
  i=0
  n=$(( $2 / $3 ))
  while [ "$i" -le "$n" ]; do
    sam "$1"
    [ "$i" -lt "$n" ] && sleep "$3"
    i=$(( i + 1 ))
  done
}

restore_all() {
  say ""
  say "===== 还原 ====="
  printf '%s\n' 0 > $B/input_suspend   2>/dev/null
  printf '%s\n' 0 > $U/input_suspend   2>/dev/null
  printf '%s\n' 0 > $B/night_charging  2>/dev/null
  printf '%s\n' -1 > $C/input_current  2>/dev/null
  printf '%s\n' 1 > $M/en_power_path   2>/dev/null
  printf '%s\n' "0 1" > $M/current_cmd 2>/dev/null
  say "  读回: batt_suspend=$(cat $B/input_suspend) usb_suspend=$(cat $U/input_suspend) night=$(cat $B/night_charging) input_current=$(cat $C/input_current) en_power_path=$(cat $M/en_power_path) current_cmd=[$(cat $M/current_cmd)]"
  say "  重启守护进程..."
  sh /data/adb/modules/bypass_charger/bypassctl.sh restart >> "$LOG" 2>&1
  say "DONE $(date '+%F %T')"
  echo "DONE" > "$DONE"
}
trap restore_all EXIT INT TERM HUP

say "===== 环境 ====="
say "real_type=$(cat $U/real_type) cp_ibus=$(cat $P) cap=$(cat $B/capacity) ibat=$(cat $B/current_now) current_cmd=[$(cat $M/current_cmd)]"
say "节点原值: batt_suspend=$(cat $B/input_suspend) usb_suspend=$(cat $U/input_suspend) night=$(cat $B/night_charging) input_current=$(cat $C/input_current) en_power_path=$(cat $M/en_power_path)"

# ---- 停守护进程 ----
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
say "剩余 auto_bypass 进程数: $(ps -A -o pid,args 2>/dev/null | grep -c auto_bypass.sh)"
say ""

# ---- 基线：current_cmd 回「正常充电」，避免测试中泵停了以后还留在旁路态干扰判定 ----
say "===== 基线准备：写 current_cmd=[0 0] ====="
w $M/current_cmd "0 0"
phase "baseline" 15 5
say ""

# ---- 1) battery/input_suspend ----
say "===== 1) battery/input_suspend  (1 = 挂起电池输入) ====="
w $B/input_suspend 1
phase "写1后" 60 5
w $B/input_suspend 0
phase "还原0后" 45 5
say ""

# ---- 2) usb/input_suspend ----
say "===== 2) usb/input_suspend  (1 = 挂起 USB 输入) ====="
w $U/input_suspend 1
phase "写1后" 60 5
w $U/input_suspend 0
phase "还原0后" 45 5
say ""

# ---- 3) en_power_path：文档说 0=切断，但实测前它本来就是 0 却在正常充电，两个值都试 ----
say "===== 3) en_power_path  (文档: 0=切断输入 / 1=恢复；实测前值本来就是 0) ====="
w $M/en_power_path 1
phase "写1后" 45 5
w $M/en_power_path 0
phase "写0后" 45 5
say "  (结束值 = 实测前值 0，无需另行还原)"
say ""

# ---- 4) charger/input_current：还原有已知问题（读回 0），放最后 ----
say "===== 4) charger/input_current  (100 = 限流到 100mA / -1 = 不限) ====="
w $C/input_current 100
phase "写100后" 60 5
w $C/input_current -1
phase "还原-1后" 45 5
say ""

# ---- 5) battery/night_charging：用户要保留的那个，作为对照 ----
say "===== 5) battery/night_charging 对照  (1 = 米系夜间充电/停充) ====="
w $B/night_charging 1
phase "写1后" 60 5
w $B/night_charging 0
phase "还原0后" 45 5

exit 0
