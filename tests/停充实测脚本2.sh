#!/system/bin/sh
# 停充方案实测 —— 第二轮（修正版）
# 第一轮的教训：en_power_path 留在 0 会一直切断输入，导致后续测试的基线是「已停充」→ 判定无效
# 本版保证：每项测试结束后【验证充电已恢复】再进入下一项；结束时全部还原成正常充电状态

B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
C=/sys/devices/platform/charger
M=/proc/mtk_battery_cmd
P=/sys/class/power_supply/cp_master/cp_ibus
LOG=/data/local/tmp/stopchg2.log
DONE=/data/local/tmp/stopchg2.done

: > "$LOG"
rm -f "$DONE"

say() { echo "$1" >> "$LOG"; echo "$1"; }

w() {   # $1=节点 $2=值   —— 保留 stderr，方便看清「写入报错但生效」到底报的是什么
  if printf '%s\n' "$2" > "$1" 2>/tmp/bz_werr; then
    say "     > 写 [$2] -> $1   rc=0  读回=[$(cat "$1" 2>/dev/null)]"
  else
    say "     > 写 [$2] -> $1   rc!=0 读回=[$(cat "$1" 2>/dev/null)] 错误=[$(cat /tmp/bz_werr 2>/dev/null)]"
  fi
}

sam() {
  line="$(date +%H:%M:%S) $1 cap=$(cat $B/capacity) ibat=$(cat $B/current_now) usb_on=$(cat $U/online) usb_in=$(cat $U/input_current_now) cp=$(cat $P)"
  echo "$line" >> "$LOG"
  echo "$line"
}

phase() { i=0; n=$(( $2 / $3 )); while [ "$i" -le "$n" ]; do sam "$1"; [ "$i" -lt "$n" ] && sleep "$3"; i=$(( i + 1 )); done; }

# 确认「正在充电」，并把结论写进日志。$1=阶段名
need_charging() {
  ib=$(cat $B/current_now)
  case "$ib" in
    -*) say "     [检查] 基线充电中 ibat=$ib  ($1)"; return 0 ;;
    *)  say "     [检查] !! 基线不是充电态 ibat=$ib ($1) —— 本项结果可能无效" ; return 1 ;;
  esac
}

restore_all() {
  say ""
  say "===== 最终还原（全部回到正常充电）====="
  printf '%s\n' 0    > $B/input_suspend   2>/dev/null
  printf '%s\n' 0    > $U/input_suspend   2>/dev/null
  printf '%s\n' 0    > $B/night_charging  2>/dev/null
  printf '%s\n' -1   > $C/input_current   2>/dev/null
  printf '%s\n' 1    > $M/en_power_path   2>/dev/null
  printf '%s\n' "0 1" > $M/current_cmd    2>/dev/null
  say "  读回: batt_suspend=$(cat $B/input_suspend) usb_suspend=$(cat $U/input_suspend) night=$(cat $B/night_charging) input_current=$(cat $C/input_current) en_power_path=$(cat $M/en_power_path) current_cmd=[$(cat $M/current_cmd)]"
  say "  重启守护进程..."
  sh /data/adb/modules/bypass_charger/bypassctl.sh restart >> "$LOG" 2>&1
  say "DONE $(date '+%F %T')"
  echo DONE > "$DONE"
}
trap restore_all EXIT INT TERM HUP

say "===== 第二轮 环境 ====="
say "real_type=$(cat $U/real_type) cap=$(cat $B/capacity) ibat=$(cat $B/current_now) cp=$(cat $P) current_cmd=[$(cat $M/current_cmd)]"
say "节点原值: batt_suspend=$(cat $B/input_suspend) usb_suspend=$(cat $U/input_suspend) night=$(cat $B/night_charging) input_current=$(cat $C/input_current) en_power_path=$(cat $M/en_power_path)"

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
say ""

# ---- 0) 诊断：为什么 power_supply 节点「报错但生效」----
say "===== 0) 诊断：power_supply 节点的写入返回值 ====="
say "  先确保充电态"
w $M/current_cmd "0 0"
sleep 8
need_charging "诊断前"
say "  试 printf '1\\n'："
{ printf '%s\n' 1 > $B/input_suspend ; } 2>/tmp/e1
say "     rc=$?  stderr=[$(cat /tmp/e1 2>/dev/null)]  读回=[$(cat $B/input_suspend)]"
sleep 5
sam "诊断中"
say "  试 echo 1："
{ echo 1 > $B/input_suspend ; } 2>/tmp/e2
say "     rc=$?  stderr=[$(cat /tmp/e2 2>/dev/null)]  读回=[$(cat $B/input_suspend)]"
say "  试 printf '0\\n' 还原："
{ printf '%s\n' 0 > $B/input_suspend ; } 2>/tmp/e3
say "     rc=$?  stderr=[$(cat /tmp/e3 2>/dev/null)]  读回=[$(cat $B/input_suspend)]"
sleep 8
need_charging "诊断后"
say ""

# ---- A) charger/input_current ----
say "===== A) charger/input_current  (100=限流 / -1=不限) ====="
need_charging "A 基线"
w $C/input_current 100
phase "写100后" 50 5
w $C/input_current -1
phase "还原-1后" 30 5
say "  还原读回=[$(cat $C/input_current)]"
need_charging "A 还原后"
say ""

# ---- B) battery/night_charging (用户要保留的那个) ----
say "===== B) battery/night_charging  (1=米系停充) ====="
need_charging "B 基线"
w $B/night_charging 1
phase "写1后" 50 5
w $B/night_charging 0
phase "还原0后" 30 5
need_charging "B 还原后"
say ""

# ---- C) en_power_path ----
say "===== C) en_power_path  (0=切断主电源路径 / 1=正常) ====="
need_charging "C 基线"
w $M/en_power_path 0
phase "写0后" 50 5
w $M/en_power_path 1
phase "还原1后" 30 5
need_charging "C 还原后"
say ""

# ---- D) 泵全速条件下的对照 ----
say "===== D) 泵全速条件下的对照（第一轮没测到的那个窗口）====="
need_charging "D 基线"
say "  用 usb/input_suspend 1->0 触发 PD 重新协商，期望充电泵重新介入"
w $U/input_suspend 1
sleep 6
w $U/input_suspend 0
PUMP=0
i=0
while [ "$i" -lt 8 ]; do
  sam "PD协商"
  cpv=$(cat $P)
  case "$cpv" in ''|*[!0-9]*) ;; *) [ "$cpv" -gt 300 ] && PUMP=1 && break ;; esac
  sleep 5
  i=$(( i + 1 ))
done
if [ "$PUMP" = "1" ]; then
  say "  泵已介入 cp=$cpv —— 开始对照"
  say "  D1: 泵下写 current_cmd=[0 1]（预期：无效）"
  w $M/current_cmd "0 1"
  phase "泵+cmd0 1" 30 5
  say "  D2: 泵下写 battery/input_suspend=1（预期：有效性未知，就是要看这个）"
  w $B/input_suspend 1
  phase "泵+batt暂停" 30 5
  w $B/input_suspend 0
  sleep 5
else
  say "  泵没有介入（cp=$cpv），跳过泵条件对照"
fi

exit 0
