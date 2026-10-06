#!/system/bin/sh
# 泵窗口测试：64% 插原装头 → 抓"泵全速"基线 → 对照组 → 按酷安帖子完整复现 night_charging
# 重点：看它在 80% 那个坎停不停、是不是真旁路（ibat=0 且适配器继续供电）
# 长跑（最多约 70 分钟），trap 保证结束时无条件还原并重启守护进程

B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
C=/sys/devices/platform/charger
M=/proc/mtk_battery_cmd
P=/sys/class/power_supply/cp_master/cp_ibus
N=$B/night_charging
LOG=/data/local/tmp/pumpwin.log
DONE=/data/local/tmp/pumpwin.done
: > "$LOG"; rm -f "$DONE"

say() { echo "$1" >> "$LOG"; echo "$1"; }
sam() {
  line="$(date +%H:%M:%S) $1 cap=$(cat $B/capacity) ibat=$(cat $B/current_now) usb_on=$(cat $U/online) usb_in=$(cat $U/input_current_now) cp=$(cat $P) night=$(cat $N) mode=$(ls -l $N 2>/dev/null | cut -c1-10)"
  echo "$line" >> "$LOG"; echo "$line"
}
phase() { i=0; n=$(( $2 / $3 )); while [ "$i" -le "$n" ]; do sam "$1"; [ "$i" -lt "$n" ] && sleep "$3"; i=$(( i + 1 )); done; }

finish() {
  say ""
  say "===== 收尾还原 ====="
  chmod 660 $N 2>/dev/null
  printf '%s\n' 0   > $N 2>/dev/null
  chmod 644 $N 2>/dev/null
  printf '%s\n' 0   > $B/input_suspend 2>/dev/null
  printf '%s\n' 0   > $U/input_suspend 2>/dev/null
  printf '%s\n' -1  > $C/input_current 2>/dev/null
  printf '%s\n' 1   > $M/en_power_path 2>/dev/null
  printf '%s\n' "0 0" > $M/current_cmd 2>/dev/null
  say "  读回: night=$(cat $N 2>/dev/null) mode=$(ls -l $N 2>/dev/null | cut -c1-10) batt_suspend=$(cat $B/input_suspend) usb_suspend=$(cat $U/input_suspend) input_current=$(cat $C/input_current) en_power_path=$(cat $M/en_power_path) current_cmd=[$(cat $M/current_cmd)]"
  say "  重启守护进程..."
  sh /data/adb/modules/bypass_charger/bypassctl.sh restart >> "$LOG" 2>&1
  say "DONE $(date '+%F %T')"
  echo DONE > "$DONE"
}
trap finish EXIT INT TERM HUP

say "===== 泵窗口测试开始 $(date '+%F %T') ====="
say "环境: cap=$(cat $B/capacity) ibat=$(cat $B/current_now) usb_on=$(cat $U/online) type=$(cat $U/real_type) cp=$(cat $P)"
say "night_charging 原值=$(cat $N) 原权限=$(ls -l $N | cut -c1-10)"

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

# ---------- A) 对照组：泵下写 current_cmd="0 1" ----------
say ""
say "===== A) 泵下写 current_cmd=[0 1]（预期无效）====="
printf '%s\n' "0 0" > $M/current_cmd
phase "A基线" 20 10
printf '%s\n' "0 1" > $M/current_cmd
say "  写入 current_cmd=[$(cat $M/current_cmd)]"
phase "A写0 1" 40 5
printf '%s\n' "0 0" > $M/current_cmd
sleep 5

# ---------- B) 复核两个 input_suspend（这是第二个电量点）----------
say ""
say "===== B) 泵下复核 battery/input_suspend ====="
printf '%s\n' 1 > $B/input_suspend 2>/dev/null
phase "B写1" 30 5
printf '%s\n' 0 > $B/input_suspend 2>/dev/null
phase "B还原" 20 5
say "--- usb/input_suspend ---"
printf '%s\n' 1 > $U/input_suspend 2>/dev/null
phase "B2写1" 30 5
printf '%s\n' 0 > $U/input_suspend 2>/dev/null
phase "B2还原" 20 5

# ---------- C) 主测：按帖子完整复现 night_charging ----------
say ""
say "===== C) 按酷安帖子复现：echo 1 + chmod 440 ====="
printf '%s\n' "0 0" > $M/current_cmd
sleep 10
sam "C基线"
printf '%s\n' 1 > $N 2>/dev/null
say "  写 1 的 rc=$? 读回=[$(cat $N)]"
chmod 440 $N 2>/dev/null
say "  chmod 440 后权限=$(ls -l $N | cut -c1-10) 读回=[$(cat $N)]"
say "--- 观察 2 分钟：64% 这种低电量下会不会立刻停？---"
phase "C写1后" 120 15

say "--- 进入爬坡观察：每 30 秒一次，直到 cap>=84 或超时（最多 60 分钟）---"
nc=0; STOPPED=""
i=0
while [ "$i" -lt 120 ]; do
  cap=$(cat $B/capacity)
  ib=$(cat $B/current_now)
  uo=$(cat $U/online)
  sam "爬坡"
  case "$ib" in
    ''|*[!0-9-]*) : ;;
    0) nc=$(( nc + 1 )) ;;
    -*) nc=0 ;;
    *) nc=$(( nc + 1 )) ;;
  esac
  if [ "$nc" -ge 2 ] && [ -z "$STOPPED" ]; then
    STOPPED=1
    say "  ★★★ 停住了：连续两次采样 ibat>=$ib、usb_on=$uo、cap=$cap、cp=$(cat $P)、usb_in=$(cat $U/input_current_now)"
  fi
  case "$cap" in ''|*[!0-9]*) ;; *) [ "$cap" -ge 84 ] && { say "  已到 cap=$cap，结束观察"; break; } ;; esac
  sleep 30
  i=$(( i + 1 ))
done
[ -n "$STOPPED" ] || say "  （观察期内没有判定到停住）"

exit 0
