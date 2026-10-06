#!/system/bin/sh
# 旁路供电控制工具 —— 供 WebUI 与命令行调用
# 用法: bypassctl.sh status | text | on | off | mode auto|on | restart | log [n]
MODDIR=${0%/*}
STATE_DIR=${BYPASS_CHARGER_STATE_DIR:-/data/adb/bypass_charger}
CONF_FILE="$STATE_DIR/config.sh"
LOG_FILE="$STATE_DIR/run.log"
PID_FILE="$STATE_DIR/daemon.pid"
# 运行模式（v12.1）：auto = 按阈值自动；on = 手动强制旁路（无视阈值）
MODE_FILE="$STATE_DIR/mode"
ORIG_TUISOC_FILE="$STATE_DIR/sc_tuisoc.orig"
STATUS_FILE="/sys/class/power_supply/battery/capacity"
IBAT_FILE="/sys/class/power_supply/battery/current_now"
USB_IN_FILE="/sys/class/power_supply/usb/input_current_now"
USB_ONLINE_FILE="/sys/class/power_supply/usb/online"
USB_TYPE_FILE="/sys/class/power_supply/usb/real_type"
CP_IBUS_FILE="/sys/class/power_supply/cp_master/cp_ibus"
BATT_VOLT_FILE="/sys/class/power_supply/battery/voltage_now"
USB_VOLT_FILE="/sys/class/power_supply/usb/voltage_now"

STATE_NODE=""; STATE_STOP=""; STATE_START=""
BYPASS_ON_ACTIONS=""; BYPASS_OFF_ACTIONS=""; RESTORE_LIST=""; LOCK_NODES=""
[ -f "$MODDIR/nodes.conf" ] && . "$MODDIR/nodes.conf"

# ---- 同样把自己移出可能被冻结的 cgroup ----
# 从 WebUI 调用本脚本时（例如点「立即进入旁路」），进程会继承管理器 App 的 cgroup；
# 如果用户中途切走，动作序列可能被冻结在半路（只写了前两个节点就停了）。
# 详见 auto_bypass.sh 里的完整说明。
CGROUP_BEFORE=$(sed -n 's/^0:://p' /proc/$$/cgroup 2>/dev/null)
if [ "$CGROUP_BEFORE" != "/" ] && [ -w /sys/fs/cgroup/cgroup.procs ]; then
  echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
fi

# ---- 免 fork 的读值工具 ----
# 实测这台机器上每 fork+exec 一个 toybox 小程序约 10~20ms。WebUI 每 3 秒拉一次
# status，原来一次 status 要起 30 多个进程（约 350ms）；换成 shell 内建后约 10 个。
# 两个坑（与 auto_bypass.sh 里相同）：
#   1) read 失败时【不会清空变量】，必须先置空；
#   2) read 不折叠内部连续空白，所以状态节点要单独归一化。
READ_VAL=""
CR=$(printf '\r')   # 配置文件可能被人用 Windows 编辑器改过，需要容忍 CRLF

read_val() {
  READ_VAL=""
  read -r READ_VAL 2>/dev/null < "$1"
  [ -n "$READ_VAL" ]
}

# 读状态节点并归一化 -> READ_VAL（标准形态下不 fork）
read_state_node() {
  READ_VAL=""
  read -r READ_VAL 2>/dev/null < "$STATE_NODE"
  case "$READ_VAL" in
    "$STATE_STOP"|"$STATE_START") return 0 ;;
  esac
  [ -n "$READ_VAL" ] || return 0
  READ_VAL=$(cat "$STATE_NODE" 2>/dev/null | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//')
  return 0
}

# 读运行模式 -> READ_VAL（auto / on；文件缺失或内容不认识都按 auto）
read_mode_val() {
  READ_VAL=""
  read -r READ_VAL 2>/dev/null < "$MODE_FILE"
  case "$READ_VAL" in
    auto|on) ;;
    *) READ_VAL="auto" ;;
  esac
}

# 只读解析配置键 -> READ_VAL，缺失时回退 $2（取第一条匹配，等价于原来的 sed|head）
conf_val() {
  READ_VAL=""
  if [ -f "$CONF_FILE" ]; then
    while IFS="=$CR" read -r k val; do
      case "$k" in "$1") READ_VAL="$val"; break ;; esac
    done < "$CONF_FILE"
  fi
  [ -n "$READ_VAL" ] || READ_VAL="$2"
}

# 读模块版本号 -> READ_VAL
module_version() {
  READ_VAL=""
  [ -f "$MODDIR/module.prop" ] || return 0
  while IFS='=' read -r k val; do
    case "$k" in version) READ_VAL="$val"; break ;; esac
  done < "$MODDIR/module.prop"
}

# 读原 sc_tuisoc -> READ_VAL（默认 80）
# 当前策略不写 sc_tuisoc，所以这个文件通常不存在 —— 保留它只是为了让
# nodes.conf 末尾用到 @SC_ORIG 的备用方案还能用。
sc_orig_val() {
  READ_VAL=""
  read -r READ_VAL 2>/dev/null < "$ORIG_TUISOC_FILE"
  case "$READ_VAL" in ''|*[!0-9]*) READ_VAL="" ;; esac
  [ -n "$READ_VAL" ] || READ_VAL=80
}

# 写一个节点，并按【读回值】判断成败（与 auto_bypass.sh 里的同名函数同理）。
# power_supply 类节点（battery/input_suspend 等，即备用方案 C1~C3）写入会返回
# "Invalid argument"，但值和动作其实已经生效 —— 只看返回值会把成功报成失败。
# 详见 实测记录.md 第十四节。
write_node() {
  # $1=节点 $2=期望值
  # 锁定节点在写之前必须先解锁（详见 auto_bypass.sh 里的同名函数：
  # 440 连 root 都写不进去，必须先 chmod 644）。
  is_lock_node "$1" && chmod 644 "$1" 2>/dev/null
  printf '%s\n' "$2" > "$1" 2>/dev/null
  wr_rc=$?
  read_val "$1"
  if [ "$READ_VAL" = "$2" ]; then
    apply_lock "$1" "$2"
    return 0
  fi
  wr_try=0
  while [ "$wr_try" -lt 2 ]; do
    sleep 1
    read_val "$1"
    if [ "$READ_VAL" = "$2" ]; then
      apply_lock "$1" "$2"
      return 0
    fi
    wr_try=$((wr_try + 1))
  done
  echo "  FAILED: '$2' -> $1   (写 rc=$wr_rc 读回='$READ_VAL')"
  return 1
}

# 需要"上锁"的节点（LOCK_NODES 是空格分隔的路径列表）
is_lock_node() {
  [ -n "$LOCK_NODES" ] || return 1
  case " $LOCK_NODES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# 写入成功后按值上锁 / 解锁：写 1 → chmod 440，写 0 → chmod 644。
# 原因见 auto_bypass.sh 里的同名函数（night_charging 属主是 system，
# 而 MIUI 充电服务以 system 身份跑，能把它改回去）。
apply_lock() {
  is_lock_node "$1" || return 0
  case "$2" in
    1) chmod 440 "$1" 2>/dev/null ;;
    0) chmod 644 "$1" 2>/dev/null ;;
  esac
  return 0
}

run_actions() {
  list="$1"; thr="$2"; orig="$3"
  rc=0
  while IFS='|' read -r node val desc; do
    [ -n "$node" ] || continue
    if [ ! -w "$node" ]; then echo "  SKIP(不可写) $node"; rc=1; continue; fi
    val=$(printf '%s' "$val" | sed "s/@THRESHOLD/$thr/g; s/@SC_ORIG/$orig/g")
    if write_node "$node" "$val"; then
      echo "  ok: '$val' -> $node   ($desc)"
      sleep 1
    else
      rc=1
    fi
  done <<EOF
$list
EOF
  return $rc
}

DAEMON_PID=""
daemon_pid() {
  DAEMON_PID=""
  p=""
  [ -f "$PID_FILE" ] && read -r p 2>/dev/null < "$PID_FILE"
  case "$p" in ''|*[!0-9]*) p="" ;; esac
  if [ -n "$p" ] && [ -d "/proc/$p" ]; then DAEMON_PID="$p"; return 0; fi
  for q in /proc/[0-9]*; do
    case "$(cat "$q/cmdline" 2>/dev/null | tr '\0' ' ')" in
      *auto_bypass*) DAEMON_PID="${q#/proc/}"; return 0 ;;
    esac
  done
  return 0
}

case "$1" in
  status)
    read_val "$IBAT_FILE";   ibat="$READ_VAL"
    read_val "$USB_IN_FILE"; usb="$READ_VAL"
    daemon_pid; p="$DAEMON_PID"
    read_state_node; v="$READ_VAL"

    # 旁路是否已下达：只看状态节点的实际值，与「谁写的」无关
    # （WebUI 手动开启时守护进程可能没在跑，但旁路确实是开着的）。
    # 不能用「电池电流==0」判断 —— 供电不足的适配器（如电脑 USB 口）下，
    # 即使旁路已开启，电池仍会放电补差额。
    bypass=off
    if [ -n "$v" ] && [ "$v" = "$STATE_STOP" ]; then bypass=on; fi

    ibat_idle=0
    case "$ibat" in 0) ibat_idle=1 ;; esac

    # 其余读数全部走内建，避免每次 status 都 fork 十几个 cat
    read_val "$STATUS_FILE";       cap_v="$READ_VAL"
    read_val "$BATT_VOLT_FILE";    batt_v="$READ_VAL"
    read_val "$USB_VOLT_FILE";     usb_v="$READ_VAL"
    read_val "$USB_ONLINE_FILE";   usb_on="$READ_VAL"
    read_val "$USB_TYPE_FILE";     usb_type="$READ_VAL"
    read_val "$CP_IBUS_FILE";      cp_ibus="$READ_VAL"
    module_version;                mod_ver="$READ_VAL"
    conf_val ENABLE_THRESHOLD 95;  thr_on="$READ_VAL"
    conf_val DISABLE_THRESHOLD 80; thr_off="$READ_VAL"
    conf_val CHECK_INTERVAL 60;    interval="$READ_VAL"
    conf_val DEBUG 0;              dbg="$READ_VAL"
    read_mode_val;                 mode_v="$READ_VAL"

    # 「旁路已下达」和「旁路真的生效」是两件事，必须分开报：
    # 状态节点写进去了，但 PD 快充时电流走充电泵、绕开主充电器，
    # 而 current_cmd 只管主充电器 —— 实测这时 ibat 仍在 -2~-3A。只报
    # BYPASS=on 会让用户以为电池闲置了。
    byp_eff=1
    if [ "$bypass" = "on" ] && [ "$usb_on" = "1" ]; then
      case "$ibat" in
        ''|*[!0-9-]*) ;;
        *) [ "$ibat" -lt -150000 ] && byp_eff=0 ;;
      esac
    fi

    echo "MODULE_VERSION=$mod_ver"
    if [ -n "$p" ]; then echo "DAEMON=1"; else echo "DAEMON=0"; fi
    echo "PID=$p"
    echo "MODE=$mode_v"
    echo "BYPASS=$bypass"
    echo "BYPASS_EFFECTIVE=$byp_eff"
    echo "IBAT_IDLE=$ibat_idle"
    echo "CAPACITY=$cap_v"
    echo "IBAT=$ibat"
    echo "USB_IN=$usb"
    # 电压单位注意：battery 是 uV，usb 是 mV
    echo "BATT_VOLT=$batt_v"
    echo "USB_VOLT=$usb_v"
    echo "USB_ONLINE=$usb_on"
    echo "USB_REAL_TYPE=$usb_type"
    echo "CP_IBUS=$cp_ibus"
    echo "STATE_VALUE=$v"
    echo "ENABLE_THRESHOLD=$thr_on"
    echo "DISABLE_THRESHOLD=$thr_off"
    echo "CHECK_INTERVAL=$interval"
    echo "DEBUG=$dbg"
    echo "STATE_DIR=$STATE_DIR"
    ;;
  text)
    read_val "$IBAT_FILE"; ibat="$READ_VAL"
    daemon_pid; p="$DAEMON_PID"
    read_state_node; v="$READ_VAL"
    module_version; mod_ver="$READ_VAL"
    read_val "$STATUS_FILE";     cap_v="$READ_VAL"
    read_val "$USB_ONLINE_FILE"; usb_on="$READ_VAL"
    read_val "$USB_TYPE_FILE";   usb_type="$READ_VAL"
    read_val "$CP_IBUS_FILE";    cp_ibus="$READ_VAL"
    echo "=== 自动旁路供电 $mod_ver ==="
    echo
    if [ -f "$CONF_FILE" ]; then
      echo "配置 ($CONF_FILE):"; sed 's/^/  /' "$CONF_FILE"
    else
      echo "配置尚未生成（守护进程还没跑过）"
    fi
    echo
    echo "电量: ${cap_v}%"
    echo "电池电流: $ibat uA   (0 = 电池闲置 / 真旁路)"
    echo "适配器: online=$usb_on type=$usb_type 充电泵ibus=$cp_ibus"
    echo "状态节点: $STATE_NODE = [$v]   (旁路='$STATE_STOP' 正常='$STATE_START')"
    if [ -n "$p" ]; then echo "守护进程: 运行中 (pid=$p)"; else echo "守护进程: 未运行"; fi
    echo
    echo "--- 最近日志 ---"
    tail -n 20 "$LOG_FILE" 2>/dev/null || echo "(无日志)"
    ;;
  on)
    echo "进入旁路:"
    conf_val ENABLE_THRESHOLD 95; thr="$READ_VAL"
    sc_orig_val; orig="$READ_VAL"
    run_actions "$BYPASS_ON_ACTIONS" "$thr" "$orig"
    ;;
  off)
    echo "退出旁路:"
    conf_val ENABLE_THRESHOLD 95; thr="$READ_VAL"
    sc_orig_val; orig="$READ_VAL"
    run_actions "$BYPASS_OFF_ACTIONS" "$thr" "$orig"
    ;;
  mode)
    # 切换运行模式（v12.1）：mode auto | mode on
    #   auto = 按阈值自动（默认）    on = 手动强制旁路，无视阈值
    # 写完模式文件后给守护进程发 USR1，让它立刻醒来重新判定，不用等满一轮。
    want="$2"
    case "$want" in
      auto|on) ;;
      *) echo "用法: $0 mode auto|on"; exit 1 ;;
    esac
    if [ "$want" = "on" ]; then desc="手动旁路（无视阈值）"; else desc="自动（按阈值）"; fi
    printf '%s\n' "$want" > "$MODE_FILE" 2>/dev/null
    chmod 600 "$MODE_FILE" 2>/dev/null
    echo "模式已切换为：$desc   (写入 $MODE_FILE)"
    daemon_pid; p="$DAEMON_PID"
    if [ -n "$p" ]; then
      if kill -USR1 "$p" 2>/dev/null; then
        echo "已通知守护进程（pid=$p）立即重新判定"
      else
        echo "通知守护进程失败（pid=$p）—— 下一轮（最多 ${CHECK_INTERVAL:-60} 秒）也会生效"
      fi
    else
      echo "守护进程未运行 —— 它下次启动时会按新模式执行"
    fi
    ;;
  restart)
    daemon_pid; p="$DAEMON_PID"
    [ -n "$p" ] && kill "$p" 2>/dev/null
    sleep 2
    for q in /proc/[0-9]*; do
      case "$(cat "$q/cmdline" 2>/dev/null | tr '\0' ' ')" in
        *auto_bypass*) kill -9 "${q#/proc/}" 2>/dev/null ;;
      esac
    done
    rm -f "$PID_FILE" 2>/dev/null
    if command -v setsid >/dev/null 2>&1; then
      setsid sh "$MODDIR/auto_bypass.sh" >/dev/null 2>&1 &
    else
      nohup sh "$MODDIR/auto_bypass.sh" >/dev/null 2>&1 &
    fi
    sleep 3
    daemon_pid; np="$DAEMON_PID"
    if [ -n "$np" ]; then echo "OK 守护进程已重启 (pid=$np)"; else echo "ERROR 重启失败，请查看日志"; exit 1; fi
    ;;
  log)
    n=${2:-40}
    tail -n "$n" "$LOG_FILE" 2>/dev/null || echo "(无日志)"
    ;;
  *)
    echo "用法: $0 status|text|on|off|mode auto|on|restart|log [n]"
    exit 1
    ;;
esac
