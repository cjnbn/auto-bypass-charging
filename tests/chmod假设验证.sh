#!/system/bin/sh
# 验证假设：MIUI 充电服务以 system 身份跑，拥有 night_charging（属主 system:system, 644）的写权限，
# 所以能把我们写的 1 悄悄改回 0；而 chmod 440 去掉 owner 写位后它就写不动了。
#   A) 只写 1（权限 644）→ 观察是否被改回 0
#   B) 写 1 + chmod 440     → 观察是否还能保持
# 结束无条件还原：chmod 660 + 写 0 + chmod 644
N=/sys/class/power_supply/battery/night_charging
LOG=/data/local/tmp/chmodtest.log
DONE=/data/local/tmp/chmodtest.done
: > "$LOG"; rm -f "$DONE"

say() { echo "$1" >> "$LOG"; echo "$1"; }
probe() { # $1=标签  $2=轮数  $3=间隔
  i=0
  while [ "$i" -lt "$2" ]; do
    v=$(cat $N 2>/dev/null)
    line="$(date +%H:%M:%S) $1 night=$v mode=$(ls -l $N | cut -c1-10) owner=$(ls -l $N | awk '{print $3":"$4}') ibat=$(cat /sys/class/power_supply/battery/current_now) usb_in=$(cat /sys/class/power_supply/usb/input_current_now) cp=$(cat /sys/class/power_supply/cp_master/cp_ibus)"
    echo "$line" >> "$LOG"; echo "$line"
    if [ "$1" = "A" ] && [ "$v" != "1" ]; then say "  ★ A 阶段：值在第 $i 轮被改回去了！"; return 1; fi
    if [ "$1" = "B" ] && [ "$v" != "1" ]; then say "  ★ B 阶段：加了 chmod 440 也还是被改回去了！"; return 1; fi
    sleep "$3"
    i=$(( i + 1 ))
  done
  return 0
}

finish() {
  say ""
  say "===== 收尾 ====="
  chmod 660 $N 2>/dev/null
  printf '%s\n' 0 > $N 2>/dev/null
  chmod 644 $N 2>/dev/null
  say "  night=$(cat $N) mode=$(ls -l $N | cut -c1-10)"
  say "DONE $(date '+%F %T')"
  echo DONE > "$DONE"
}
trap finish EXIT INT TERM HUP

say "===== chmod 假设验证 $(date '+%F %T') ====="
say "初始: night=$(cat $N) mode=$(ls -l $N | cut -c1-10) owner=$(ls -l $N | awk '{print $3":"$4}')"
say "当前身份: $(id)"

say ""
say "===== A) 只写 1，权限保持 644，观察 5 分钟（每 20 秒一条）====="
chmod 644 $N 2>/dev/null
printf '%s\n' 1 > $N 2>/dev/null
say "  写入后 night=$(cat $N) mode=$(ls -l $N | cut -c1-10)"
probe A 15 20

say ""
say "===== B) 写 1 + chmod 440，观察 10 分钟（每 20 秒一条）====="
chmod 644 $N 2>/dev/null
printf '%s\n' 1 > $N 2>/dev/null
chmod 440 $N 2>/dev/null
say "  写入后 night=$(cat $N) mode=$(ls -l $N | cut -c1-10)"
probe B 30 20

exit 0
