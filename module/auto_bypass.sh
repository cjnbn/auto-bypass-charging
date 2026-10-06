#!/system/bin/sh
###############################################################################
# 自动旁路供电 (module id: bypass_charger)
#
# 目标：让手机由充电器直接供电，电池既不充也不放（电池闲置 / 真旁路）。
#
# 控制策略（详见 nodes.conf 顶部）—— 三条一起写，覆盖全部场景：
#   1) current_cmd="0 1"     泵闲着时（<80% 的 5V 直充、≥89% 泵停了）由它干活
#   2) night_charging="1"    ★ 压在充电泵：≥80% 时 MIUI 框架立刻停充，泵没负载自己就停
#   3) en_power_path="1"     使能主电源路径，把「停充」升级成「真旁路」（ibat=0）
# 退出时【先】把 night_charging 写回 0（否则框架会把充电永久卡在 80%），再 current_cmd="0 0"。
#
# 曾经用过「enable_sc + sc_tuisoc」的两段式，实测证明是多余的（见 nodes.conf 与实测记录）。
#
# 已知限制：能直接关泵的三个节点（cp_master/online、cp_slave/online、
# pd_cp_manager/request_ibus）都是 Permission denied —— 但现在用 night_charging 绕过去了。
#
# 状态机（v11.16 起）：
#   充电器在线 且 电量 >= ENABLE_THRESHOLD   -> 进入旁路
#   充电器在线 且 电量 <= DISABLE_THRESHOLD  -> 退出旁路
#   充电器被拔掉                             -> 立刻退出旁路（nap_watch 每 5 秒盯一次）
#   没有充电器时【不会】进入旁路 —— 否则 night_charging 会挂在那里，
#   重新插上后框架把充电压在 80%，用户设的阈值（比如 90）就失效了。
#
# 配置: /data/adb/bypass_charger/config.sh
# 日志: /data/adb/bypass_charger/run.log
###############################################################################

MODDIR=${0%/*}

STATE_DIR=${BYPASS_CHARGER_STATE_DIR:-/data/adb/bypass_charger}
STATUS_FILE=${BYPASS_CHARGER_STATUS:-/sys/class/power_supply/battery/capacity}

CONF_FILE="$STATE_DIR/config.sh"
LOG_FILE="$STATE_DIR/run.log"
PID_FILE="$STATE_DIR/daemon.pid"
# 运行模式（v12.1 新增）：auto = 按阈值自动；on = 手动强制进入旁路（无视阈值）
# 内容就是 "auto" 或 "on" 两个词；文件不存在/读不懂一律按 auto 处理。
MODE_FILE="$STATE_DIR/mode"
# 本策略不再写 sc_tuisoc，所以也不会去创建这个文件；只是读一次（早期版本留下的），
# 供 nodes.conf 末尾那些用 @SC_ORIG 的备用方案引用，读不到按本机原值 80 兜底。
ORIG_TUISOC_FILE="$STATE_DIR/sc_tuisoc.orig"

IBAT_FILE="/sys/class/power_supply/battery/current_now"
USB_IN_FILE="/sys/class/power_supply/usb/input_current_now"
USB_ONLINE_FILE="/sys/class/power_supply/usb/online"
CP_IBUS_FILE="/sys/class/power_supply/cp_master/cp_ibus"
USB_TYPE_FILE="/sys/class/power_supply/usb/real_type"

# 控制策略（唯一来源 nodes.conf）
STATE_NODE=""; STATE_STOP=""; STATE_START=""
BYPASS_ON_ACTIONS=""; BYPASS_OFF_ACTIONS=""; RESTORE_LIST=""; LOCK_NODES=""
POWER_PATH_CHECK=""
[ -f "$MODDIR/nodes.conf" ] && . "$MODDIR/nodes.conf"

# 默认参数
ENABLE_THRESHOLD=95
DISABLE_THRESHOLD=80
CHECK_INTERVAL=60
MIN_INTERVAL=5
DEBUG=0
# 判定「旁路失效」的充电电流门限（uA，取绝对值）
INEFFECTIVE_IBAT=150000
# 判定「只做到停充」的电池放电电流门限（uA）：旁路真的生效时这个值应该是 0，
# 明显为正说明系统在靠电池跑（详见 stopped_not_bypassed）。
# 不设成 0 是因为收敛期（约 10 秒）和弱适配器下都会有短暂的小正值。
STOPPED_IBAT=30000
# 两次重打之间的最小间隔（秒）
REAPPLY_COOLDOWN=90

# 日志只保留最近 LOG_KEEP_LINES 条（v12.3 起）。
# 原来按 64KB 轮转成 run.log.old；改成"截尾"更适合看：正式版（DEBUG=0）日志本来就少，
# 30 条足够覆盖最近的状态机决策（模式切换/进旁路/自愈/拔插/报错），
# 而文件永远很小、WebUI 里一眼能看完，不用滚动。
# 代价：写满之后每写一条会多做一次 tail+mv（两个 fork，约 20~40ms）。
# 正式版一天也就几条，可忽略；DEBUG=1 时是每轮一条，同样可忽略。
# chmod 同理只在新建/截尾后做一次，不必每条都 fork 一个 chmod。
LOG_KEEP_LINES=30
LOG_PERM_SET=0
LOG_LINES=0
[ -f "$LOG_FILE" ] && LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null)
case "$LOG_LINES" in ''|*[!0-9]*) LOG_LINES=0 ;; esac
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null
  LOG_LINES=$((LOG_LINES + 1))
  if [ "$LOG_LINES" -gt "$LOG_KEEP_LINES" ]; then
    if tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null; then
      mv -f "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
      LOG_LINES=$LOG_KEEP_LINES
      LOG_PERM_SET=0        # mv 之后是新文件，权限要重设
    fi
  fi
  if [ "$LOG_PERM_SET" = "0" ] && [ -f "$LOG_FILE" ]; then
    chmod 600 "$LOG_FILE" 2>/dev/null && LOG_PERM_SET=1   # ksud 以 umask 0 执行，默认 0666
  fi
}

read_digits() {
  [ -r "$1" ] || return 1
  v=$(cat "$1" 2>/dev/null | tr -cd '0-9')
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# ---- 免 fork 的读值工具 ----
# 实测这台机器上每 fork+exec 一个 toybox 小程序约 10~20ms：
#     $(cat f | tr -cd '0-9')                约 32ms
#     $(cat f | tr -s ' \t' ' ' | sed ...)   约 47ms
#     read -r v < f  （shell 内建）           约  0ms
# 守护进程每轮要读好几处，这里把热路径全换成内建。
# 两个必须注意的坑（都实测过）：
#   1) read 失败时【不会清空变量】。必须先把变量置空，否则会拿上一次的旧值
#      去做阈值比较。文件不存在时 v 保持原值、read 返回 1。
#   2) read 不折叠内部的连续空白。"0  1" 读出来仍是 "0  1"，
#      不能直接和 STATE_STOP="0 1" 比较 —— 这种情况极罕见，回退老写法兜底。
READ_VAL=""
read_val() {
  READ_VAL=""
  read -r READ_VAL 2>/dev/null < "$1"
  [ -n "$READ_VAL" ]
}

# 读运行模式 -> MODE（auto / on）。文件不存在或内容不认识都按 auto 处理。
# 每轮读一次，用 read 内建，不 fork。
MODE="auto"
read_mode() {
  MODE="auto"
  read -r MODE 2>/dev/null < "$MODE_FILE"
  case "$MODE" in
    auto|on) ;;
    *) MODE="auto" ;;
  esac
}

# 读纯数字；含非数字时回退到 tr 剥离，保证与原 read_digits 行为一致
read_digits_val() {
  READ_VAL=""
  read -r READ_VAL 2>/dev/null < "$1"
  [ -n "$READ_VAL" ] || return 1
  case "$READ_VAL" in
    *[!0-9]*)
      READ_VAL=$(printf '%s' "$READ_VAL" | tr -cd '0-9')
      [ -n "$READ_VAL" ] || return 1
      ;;
  esac
  return 0
}

# 只读解析配置里的键
load_config() {
  [ -f "$CONF_FILE" ] || return 0
  while IFS='=' read -r key val; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$key" in
      ENABLE_THRESHOLD|DISABLE_THRESHOLD|CHECK_INTERVAL|DEBUG)
        val=$(printf '%s' "$val" | tr -cd '0-9')
        [ -n "$val" ] || continue
        case "$key" in
          ENABLE_THRESHOLD)  ENABLE_THRESHOLD=$val ;;
          DISABLE_THRESHOLD) DISABLE_THRESHOLD=$val ;;
          CHECK_INTERVAL)    CHECK_INTERVAL=$val ;;
          DEBUG)             DEBUG=$val ;;
        esac
        ;;
    esac
  done < "$CONF_FILE"
}

# 写一个节点，并按【读回值】判断成败。
# 为什么不能只看 write 的返回值：battery/input_suspend、usb/input_suspend、
# battery/night_charging 这些 power_supply 节点的 store 函数会【先改状态、再返回
# -EINVAL】—— write 报 "Invalid argument"，但值和动作其实都已经生效了。
# 实测：写 1 报错，读回是 1，停充也确实发生了（见 实测记录.md 第十四节）。
# 只看返回值会把这些成功的动作记成 ACTION FAILED，并让 run_actions 返回非 0。
write_node() {
  # $1=节点 $2=期望值
  # 锁定节点在写之前【必须先解锁】：chmod 440 会连我们自己也挡在外面。
  # 实测：ksu 的 root 有 CAP_FOWNER（能 chmod），但没有 CAP_DAC_OVERRIDE ——
  # 往一个 440 的文件里写会直接 `Permission denied`。
  # 酷安帖子里"关的时候先 chmod 660 再写 0"就是这个原因，别把顺序搞反。
  is_lock_node "$1" && chmod 644 "$1" 2>/dev/null
  printf '%s\n' "$2" > "$1" 2>>"$LOG_FILE"
  wr_rc=$?
  read_val "$1"
  if [ "$READ_VAL" = "$2" ]; then
    if [ "$wr_rc" != "0" ] && [ "$DEBUG" = "1" ]; then
      log "ACTION note: $1 写报错(rc=$wr_rc)但读回已是 '$2'，按成功计"
    fi
    apply_lock "$1" "$2"
    return 0
  fi
  # 读回不匹配：驱动可能要几秒才收敛，再给两次机会
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
  log "ACTION FAILED: '$2' -> $1   (写 rc=$wr_rc 读回='$READ_VAL')"
  return 1
}

# 这个节点需要"上锁"吗？（LOCK_NODES 是空格分隔的路径列表）
is_lock_node() {
  [ -n "$LOCK_NODES" ] || return 1
  case " $LOCK_NODES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# 写入成功后按值上锁 / 解锁。
# 为什么要上锁：night_charging 属主是 system:system、权限 644，而 MIUI 的充电服务
# 就是以 system 身份跑的 —— 它能把我们写的 1 改回 0（实测 22:20 写、22:36 已变 0）。
# chmod 440 去掉 owner 写位后 system 就写不动了（没有 CAP_DAC_OVERRIDE），root 仍能写。
# 写 1 → 440（上锁）；写 0 → 644（还原，不能把 MIUI 的夜间充电永久挡在外面）。
apply_lock() {
  is_lock_node "$1" || return 0
  case "$2" in
    1) chmod 440 "$1" 2>/dev/null && [ "$DEBUG" = "1" ] && log "  lock: chmod 440 $1（防止 MIUI 把它改回 0）" ;;
    0) chmod 644 "$1" 2>/dev/null ;;
  esac
  return 0
}

# 锁定节点被外力改回去了吗？（旁路状态下 night_charging 必须是 1）
# 这是不依赖"谁改的"的兜底：只要发现掉了，就跟"旁路失效"一样重打。
lock_released() {
  [ "$current_state" = "on" ] || return 1
  [ -n "$LOCK_NODES" ] || return 1
  for n in $LOCK_NODES; do
    read_val "$n"
    [ "$READ_VAL" = "1" ] || return 0
  done
  return 1
}

# v12.2：旁路"打了一半"——电池还在供电，说明只做到了停充、没做到真旁路。
# 判据（三条缺一不可，避免误判）：
#   ① 状态是旁路、充电器在线
#   ② 电池电流明显为正（> +30mA = 电池在给系统供电）
#   ③ POWER_PATH_CHECK（en_power_path）读回不是 1 → 主电源路径没使能
# 为什么要 ③：供电不足的适配器（如电脑 USB 口）下，即使旁路正常、电池也会补差额，
# 那种情况 en_power_path 是 1，不该重打。读到的值放在 PP_LAST 供日志用。
PP_LAST=""
stopped_not_bypassed() {
  PP_LAST=""
  [ "$current_state" = "on" ] || return 1
  case "$1" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$1" -gt "$STOPPED_IBAT" ] || return 1
  read_val "$USB_ONLINE_FILE"
  [ "$READ_VAL" = "1" ] || return 1
  [ -n "$POWER_PATH_CHECK" ] || return 1
  read_val "$POWER_PATH_CHECK"
  PP_LAST="$READ_VAL"
  [ "$PP_LAST" = "1" ] && return 1
  return 0
}

# 执行一串动作：每行 路径|写入值|说明
run_actions() {
  list="$1"
  rc=0
  while IFS='|' read -r node val desc; do
    [ -n "$node" ] || continue
    if [ ! -w "$node" ]; then
      log "ACTION SKIP (不可写): $node"
      rc=1
      continue
    fi
    case "$val" in
      *@THRESHOLD*) val=$(printf '%s' "$val" | sed "s/@THRESHOLD/$ENABLE_THRESHOLD/g") ;;
    esac
    case "$val" in
      *@SC_ORIG*)   val=$(printf '%s' "$val" | sed "s/@SC_ORIG/${SC_ORIG:-80}/g") ;;
    esac
    if write_node "$node" "$val"; then
      [ "$DEBUG" = "1" ] && log "ACTION ok: '$val' -> $node   ($desc)"
      sleep 1
    else
      rc=1
    fi
  done <<EOF
$list
EOF
  return $rc
}

# 读状态节点 -> 设置 STATE_ACTUAL 为 on / off / 空，READ_VAL 保留节点原文。
# 常见路径完全不 fork；只有值不是标准形态时才回退到 cat|tr|sed。
STATE_ACTUAL=""
read_control_state() {
  STATE_ACTUAL=""
  read -r READ_VAL 2>/dev/null < "$STATE_NODE"
  case "$READ_VAL" in
    "$STATE_STOP")  STATE_ACTUAL="on";  return 0 ;;
    "$STATE_START") STATE_ACTUAL="off"; return 0 ;;
  esac
  # 读不到就不要回退，否则节点坏掉时每轮都白 fork 三个进程
  [ -n "$READ_VAL" ] || return 0
  # 罕见：值里有多余空白（read 不折叠），归一化后再比一次
  READ_VAL=$(cat "$STATE_NODE" 2>/dev/null | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//')
  case "$READ_VAL" in
    "$STATE_STOP")  STATE_ACTUAL="on" ;;
    "$STATE_START") STATE_ACTUAL="off" ;;
  esac
  return 0
}

# 「应该处于旁路，但电池实际还在被充」——插拔充电器后 PD 会重新协商回充电泵快充，
# 而泵绕开了 current_cmd，需要重打一遍（重打里包含压泵的 night_charging）。
# $1 = 本轮已经读到的 ibat（避免重复读同一个文件）
bypass_ineffective() {
  [ "$current_state" = "on" ] || return 1
  case "$1" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$1" -lt "-$INEFFECTIVE_IBAT" ] || return 1
  read_val "$USB_ONLINE_FILE" || return 1
  [ "$READ_VAL" = "1" ] || return 1
  return 0
}

# ---- 先确保状态目录存在（必须在写 PID 文件之前）----
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null

# ---- 把自己移出「会被冻结」的 cgroup（很重要，实测踩过）----
# 从 KernelSU 管理器 WebUI 里点「保存并重启」时，新守护进程会继承管理器 App 的
# cgroup（形如 /uid_10228/...）。用户一离开管理器，Android 就把整个 cgroup 冻结，
# 守护进程随之进入 do_freezer_trap —— 之后日志一个字不写、阈值也不触发，
# 表现成「模块突然失效」，而且完全静默，极难排查。
# 从 adb / 开机 service.sh 启动的进程落在根 cgroup，不会遇到这个问题。
# 写根 cgroup.procs 把自己挪出去即可，之后 fork 的子进程会继承新 cgroup。
CGROUP_BEFORE=$(sed -n 's/^0:://p' /proc/$$/cgroup 2>/dev/null)
if [ "$CGROUP_BEFORE" != "/" ] && [ -w /sys/fs/cgroup/cgroup.procs ]; then
  echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
fi
CGROUP_AFTER=$(sed -n 's/^0:://p' /proc/$$/cgroup 2>/dev/null)

if [ ! -f "$CONF_FILE" ]; then
  # 正式版默认 DEBUG=0（日志安静）。要排查问题可以在 WebUI 里勾上，或手改 config.sh。
  printf 'ENABLE_THRESHOLD=95\nDISABLE_THRESHOLD=80\nCHECK_INTERVAL=60\nDEBUG=0\n' > "$CONF_FILE" 2>/dev/null
  chmod 600 "$CONF_FILE" 2>/dev/null
fi
load_config

# 当前策略不写 sc_tuisoc，所以不需要记录/还原它的原值。
# 这里只读一次（早期版本留下的文件），让 nodes.conf 末尾用到 @SC_ORIG 的
# 备用方案仍然可用；读不到就按本机原值 80 兜底。
SC_ORIG=""
read -r SC_ORIG 2>/dev/null < "$ORIG_TUISOC_FILE"
case "$SC_ORIG" in ''|*[!0-9]*) SC_ORIG=80 ;; esac

# ---- 单实例保护 ----
if [ -f "$PID_FILE" ]; then
  oldpid=$(read_digits "$PID_FILE")
  if [ -n "$oldpid" ] && [ -d "/proc/$oldpid" ] \
     && cat "/proc/$oldpid/cmdline" 2>/dev/null | tr '\0' ' ' | grep -q 'auto_bypass'; then
    exit 0
  fi
  rm -f "$PID_FILE" 2>/dev/null
fi
echo $$ > "$PID_FILE" 2>/dev/null

SLEEP_PID=""
cleanup() {
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  rm -f "$PID_FILE" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM HUP

# v12.1：WebUI 切换模式后发 USR1，让守护进程立刻醒来重新判定，不用等满一轮。
# 注意两点：
#   1) 信号只会打断当前的 `wait`，而 nap_watch 是"5 秒一格"的循环 —— 光靠打断
#      只会少睡一格、然后接着睡下一格。所以这里额外置 WAKE=1，
#      由 nap_watch 检查它并立刻返回（主循环每轮开头会把 WAKE 清零）。
#   2) 顺便把当前那个 sleep 杀掉，免得每次打断都留一个孤儿 sleep 进程。
WAKE=0
trap 'WAKE=1; [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; SLEEP_PID=""' USR1

# 可被信号打断的 sleep（直接 sleep 时 SIGTERM 要等这一轮睡完才生效）
nap() {
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
}

# v11.16：等待期间顺便盯充电器。旁路态下每 5 秒瞄一眼 usb/online，
# 一旦被拔掉就提前返回，让主循环立刻退出旁路。
# 为什么需要：主循环一轮默认 60 秒，若"拔掉再插上"整个落在这一轮里，
# 就完全检测不到 —— 而 night_charging 还挂着，重插后框架会把充电压在 80%，
# 用户设的阈值（比如 90）在这条路径上就不生效了。
# 代价：旁路态下每分钟多约 11 次 fork（sleep 是 busybox 的 NOFORK applet，1ms 级），可忽略。
WATCH_STEP=5
nap_watch() {
  nw_total=0
  while [ "$nw_total" -lt "$1" ]; do
    [ "$WAKE" = "1" ] && return 0          # 被 USR1 叫醒：立刻回主循环重判
    nw_step=$WATCH_STEP
    [ $(( nw_total + nw_step )) -gt "$1" ] && nw_step=$(( $1 - nw_total ))
    sleep "$nw_step" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
    [ "$WAKE" = "1" ] && return 0          # 睡到一半被叫醒
    nw_total=$(( nw_total + nw_step ))
    if [ "$current_state" = "on" ]; then
      read_val "$USB_ONLINE_FILE"
      [ "$READ_VAL" = "0" ] && return 0    # 拔了，提前回主循环
    fi
  done
  return 0
}

# ---- 进入 / 退出旁路的统一出口（v12.2 抽出，避免三处重复）----
# 进入时多做一次"10 秒后复核"：这段时间正好是主电源路径接管系统负载的收敛窗口
# （实测约 10 秒，见 实测记录.md 第 18.6 节）。如果复核发现电池还在供电
# （也就是只做到"停充"），就幂等地补写一次进入序列。
# $1 = 日志后缀（如 "手动模式"），可为空
do_bypass_on() {
  if ! run_actions "$BYPASS_ON_ACTIONS"; then
    if [ "$last_err" != "on" ]; then
      last_err="on"; log "ERROR 进入旁路失败（检查上面的 ACTION FAILED）"
    fi
    return 1
  fi
  current_state="on"; last_err=""
  last_apply_tick=$tick_no
  if [ -n "$1" ]; then log "bypass ON  (capacity=$cap / $1)"; else log "bypass ON  (capacity=$cap)"; fi
  nap 10                                    # 可被信号/拔充电器打断
  read_val "$IBAT_FILE"; confirm_ibat="$READ_VAL"
  if stopped_not_bypassed "$confirm_ibat"; then
    log "进入后复核：电池仍在供电（ibat=$confirm_ibat、en_power_path=${PP_LAST:-?}），补写一次进入序列"
    run_actions "$BYPASS_ON_ACTIONS"
    last_apply_tick=$tick_no
  fi
  return 0
}

# $1 = 日志后缀（如 "充电器已拔"），可为空
do_bypass_off() {
  if ! run_actions "$BYPASS_OFF_ACTIONS"; then
    if [ "$last_err" != "off" ]; then
      last_err="off"; log "ERROR 退出旁路失败"
    fi
    return 1
  fi
  current_state="off"; last_err=""
  if [ -n "$1" ]; then log "bypass OFF (capacity=$cap / $1)"; else log "bypass OFF (capacity=$cap)"; fi
  return 0
}

# ---- 参数校验 ----
case "$CHECK_INTERVAL" in ''|*[!0-9]*) CHECK_INTERVAL=60 ;; esac
[ "$CHECK_INTERVAL" -lt "$MIN_INTERVAL" ] && CHECK_INTERVAL=$MIN_INTERVAL
case "$ENABLE_THRESHOLD" in ''|*[!0-9]*) ENABLE_THRESHOLD=95 ;; esac
case "$DISABLE_THRESHOLD" in ''|*[!0-9]*) DISABLE_THRESHOLD=80 ;; esac
if [ "$ENABLE_THRESHOLD" -le "$DISABLE_THRESHOLD" ]; then
  log "WARN invalid thresholds ($ENABLE_THRESHOLD/$DISABLE_THRESHOLD), fallback to 95/80"
  ENABLE_THRESHOLD=95
  DISABLE_THRESHOLD=80
fi

if [ -z "$STATE_NODE" ] || [ ! -w "$STATE_NODE" ]; then
  log "ERROR 状态节点不可用: ${STATE_NODE:-未定义}，模块不生效"
fi

log "start pid=$$ on>=$ENABLE_THRESHOLD off<=$DISABLE_THRESHOLD interval=${CHECK_INTERVAL}s debug=$DEBUG"
log "state node: $STATE_NODE  (stop='$STATE_STOP' start='$STATE_START')"
read_mode
mode_prev="$MODE"
log "mode=$MODE  (auto=按阈值自动 / on=手动强制旁路，无视阈值)"
if [ "$DEBUG" = "1" ]; then
  log "debug: KSU=${KSU:-unset} RUNTIME=${KSU_RUNTIME_MODE:-unset} umask=$(umask)"
  log "debug: state_dir=$STATE_DIR status_file=$STATUS_FILE"
  log "debug: cgroup=$CGROUP_BEFORE -> $CGROUP_AFTER（非 / 会被系统冻结）"
fi

read_control_state
current_state="$STATE_ACTUAL"
log "initial state=${current_state:-unknown}"

# ---- 主循环 ----
# 冷却判断用「轮数」代替墙上时间：原来每轮都调一次 date（约 20ms/次）只为算冷却，
# 而冷却本身就是个启发值，换算成轮数完全等价。这样每轮省掉一个 date 进程。
last_err=""
tick_no=0
last_apply_tick=0
COOLDOWN_TICKS=$((REAPPLY_COOLDOWN / CHECK_INTERVAL + 1))

while :; do
  tick_no=$((tick_no + 1))
  WAKE=0     # 每轮开头清掉"被 USR1 叫醒"的标记

  if ! read_digits_val "$STATUS_FILE"; then
    [ "$DEBUG" = "1" ] && log "tick: 读不到电量 ($STATUS_FILE)"
    nap "$CHECK_INTERVAL"
    continue
  fi
  cap="$READ_VAL"

  # 每轮重读节点实际值，不信缓存（驱动/框架可能把它重置）
  read_control_state
  actual="$STATE_ACTUAL"
  ctrl_raw="$READ_VAL"
  if [ -n "$actual" ] && [ "$actual" != "$current_state" ]; then
    log "state resync: cached=${current_state:-unknown} actual=$actual node=[$ctrl_raw]"
    current_state=$actual
  fi

  read_val "$IBAT_FILE"; ibat="$READ_VAL"
  # 充电器在不在线：退出旁路要用它判定，进入旁路前也要先看它（v11.16）
  read_val "$USB_ONLINE_FILE"; usb_on_v="$READ_VAL"
  # 运行模式：WebUI 可以在 auto（按阈值）与 on（手动强制旁路）之间切换（v12.1）
  read_mode
  if [ "$MODE" != "$mode_prev" ]; then
    log "模式切换：${mode_prev:-未知} -> $MODE"
    mode_prev="$MODE"
  fi
  if [ "$DEBUG" = "1" ]; then
    read_val "$USB_IN_FILE";   usb_in_v="$READ_VAL"
    read_val "$CP_IBUS_FILE";  cp_v="$READ_VAL"
    read_val "$USB_TYPE_FILE"; type_v="$READ_VAL"
    log "tick cap=$cap state=${current_state:-unknown} mode=$MODE ibat=$ibat usb_on=$usb_on_v usb_in=$usb_in_v node=[$ctrl_raw] cp=$cp_v type=$type_v"
  fi

  # ---- 充电器被拔掉 -> 立刻退出旁路（v11.16）----
  # 不这么做的后果：night_charging 还挂着 1，重新插上时框架会把充电压在 80%，
  # 用户设的阈值（比如 90）在这条路径上就失效了。
  # 只在明确读到 "0" 时才动作；读不到（空值）不动，避免节点异常时误退出。
  if [ "$current_state" = "on" ] && [ "$usb_on_v" = "0" ]; then
    do_bypass_off "充电器已拔"
    nap "$CHECK_INTERVAL"
    continue
  fi

  # 自愈：已经在旁路状态，但
  #   ① 电池还在被充 -> 插拔过充电器，PD 重新快充了
  #   ② 锁定节点（night_charging）被外力改回 0 -> 压泵能力没了，必须补回来
  #   ③ 只做到"停充"：电池在供电、而 en_power_path 没使能（v12.2）
  # last_apply_tick=0 表示「本次启动后还没重打过」，此时不受冷却限制
  # （原来用墙上时间时 now-0 必然远大于冷却值，效果就是首轮立即重打）。
  why=""
  bypass_ineffective "$ibat" && why="电池仍在充 ibat=$ibat"
  if [ -z "$why" ] && stopped_not_bypassed "$ibat"; then
    why="只做到停充（电池在供电 ibat=$ibat、en_power_path=${PP_LAST:-?}）"
  fi
  if lock_released; then
    if [ -n "$why" ]; then why="$why；"; fi
    why="${why}锁定节点已被改回"
  fi
  if [ -n "$why" ] && { [ "$last_apply_tick" = "0" ] || [ $((tick_no - last_apply_tick)) -ge "$COOLDOWN_TICKS" ]; }; then
    log "bypass 失效（$why），重打进入序列"
    do_bypass_on
    nap_watch "$CHECK_INTERVAL"
    continue
  fi

  # ---- ⑥⑦ 进入 / 退出判定 ----
  # 两种模式的规则不同（v12.1）：
  #   auto（自动）  ：插着充电器 且 电量>=ENABLE_THRESHOLD -> 进；电量<=DISABLE_THRESHOLD -> 出
  #   on（手动旁路）：无视阈值，只要插着充电器就保持旁路；退出只由「拔充电器」或「切回自动」触发
  # 两种模式都保留：拔充电器退出（上面 ④）、自愈重打（上面 ⑤）、以及"没充电器不进旁路"。
  if [ "$MODE" = "on" ]; then
    if [ "$usb_on_v" != "0" ] && [ "$current_state" != "on" ]; then
      do_bypass_on "手动模式"
    fi
  else
    # 自动模式：进入前必须确认充电器在线（usb/online != 0）。
    # 没有充电器时进旁路毫无意义，而且会留下 night_charging=1 —— 那正是
    # "拔掉再插上被压在 80%" 这个例外的根源。（读不到就按原来的行为放行。）
    if [ "$usb_on_v" != "0" ] && [ "$cap" -ge "$ENABLE_THRESHOLD" ] && [ "$current_state" != "on" ]; then
      do_bypass_on
    elif [ "$cap" -le "$DISABLE_THRESHOLD" ] && [ "$current_state" != "off" ]; then
      do_bypass_off
    fi
  fi

  nap_watch "$CHECK_INTERVAL"
done
