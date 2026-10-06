#!/system/bin/sh
# 卸载时先停掉常驻进程，再把所有可能的控制节点还原成「正常充电」，
# 否则脚本会继续改写充电状态，甚至让手机停在「电池闲置」不上电。
MODDIR=${0%/*}
STATE_DIR="/data/adb/bypass_charger"
PID_FILE="$STATE_DIR/daemon.pid"

# 控制策略（含 RESTORE_LIST）的唯一来源
RESTORE_LIST=""; LOCK_NODES=""
[ -f "$MODDIR/nodes.conf" ] && . "$MODDIR/nodes.conf"
[ -n "$RESTORE_LIST" ] || RESTORE_LIST="/proc/mtk_battery_cmd/current_cmd|0 0"

# 先按 PID 文件杀；PID 文件可能缺失或已过期，再按命令行扫 /proc 兜底。
pid=""
[ -f "$PID_FILE" ] && pid=$(tr -cd '0-9' < "$PID_FILE" 2>/dev/null)
[ -n "$pid" ] && kill "$pid" 2>/dev/null

# 本脚本自身 cmdline 是 "sh .../uninstall.sh"，不含 auto_bypass，不会误杀自己
kill_by_cmdline() {
  for p in /proc/[0-9]*; do
    case "$(cat "$p/cmdline" 2>/dev/null | tr '\0' ' ')" in
      *auto_bypass*) kill "$1" "${p#/proc/}" 2>/dev/null ;;
    esac
  done
}

kill_by_cmdline -TERM
sleep 1
kill_by_cmdline -KILL

# ---- 先解锁，再还原（顺序绝对不能反）----
# night_charging 可能被 chmod 440 锁着，而 440 连 root 都写不进去
# （ksu 的 root 有 CAP_FOWNER 能 chmod，但没有 CAP_DAC_OVERRIDE）——
# 那时 `echo 0 > 节点` 会 **静默失败**（2>/dev/null 把 Permission denied 吃掉），
# 节点留在 1，卸载后 MIUI 的充电就被永久卡在 80%。这就是 v11.16 之前 uninstall.sh 的 bug。
[ -n "$LOCK_NODES" ] || LOCK_NODES="/sys/class/power_supply/battery/night_charging"
for n in $LOCK_NODES; do
  chmod 644 "$n" 2>/dev/null
done

# 还原所有被动过的节点。这里的值都是「正常充电」的安全值。
# 用 printf 而不是 echo（值里可能有 "-1"）；不用 [ -w ] 判断可写性 —— 实测它不可靠，
# 真正的判据只能是写完读回。每次结果都写进 run.log，方便日后核对卸载是否干净。
ulog() { echo "$(date '+%Y-%m-%d %H:%M:%S') uninstall: $*" >> "$STATE_DIR/run.log" 2>/dev/null; }
while IFS='|' read -r node val; do
  [ -n "$node" ] || continue
  if [ ! -e "$node" ]; then
    ulog "SKIP 节点不存在 $node"
  elif printf '%s\n' "$val" > "$node" 2>/dev/null; then
    ulog "还原 $node = $val  (读回=$(cat "$node" 2>/dev/null))"
  else
    ulog "FAILED 还原 $node = $val"
  fi
done <<EOF
$RESTORE_LIST
EOF

# 权限兜底：还原完再确认一次是 644，别把 MIUI 自己的夜间充电挡在外面
for n in $LOCK_NODES; do
  chmod 644 "$n" 2>/dev/null
done
ulog "完成，锁节点权限已还原 644"

# 说明：当前策略写 current_cmd + night_charging + en_power_path 三个节点。
# night_charging 是 v11.14 起才开始写的，**必须在 RESTORE_LIST 里还原成 0**，
# 否则卸载后框架会把充电永久卡在 80%（en_power_path 由驱动自管，不用管）。
# 不碰 enable_sc / sc_tuisoc，所以不需要还原 sc_tuisoc（早期版本做过，见实测记录第十一节）。
# RESTORE_LIST 里后面几项是给「用户手动试过二类备用节点」留的兜底。

rm -f "$PID_FILE" 2>/dev/null

# 保留 config.sh 与 run.log 便于排查问题；需要清干净就手动 rm -rf $STATE_DIR
exit 0
