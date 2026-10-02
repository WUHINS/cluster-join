#!/bin/sh
#===============================================================================
#  cluster-batch.sh —— 服务器集群批量并网下发脚本
#  Server cluster batch deploy: push cluster-join.sh to many hosts in parallel
#
#  特点 / Features
#    * POSIX sh 兼容（dash / ash / busybox / bash），无需 TTY
#    * 并发下发（按 --jobs 分批 wait），每台机器独立日志文件
#    * 脚本来源二选一：本地文件（走 ssh stdin 管道）或远程 URL（curl | sh）
#    * 所有 --komari-* / --et-* / --web-* 参数原样透传给节点脚本
#
#  语言策略 / Language policy（与 cluster-join.sh 一致）
#    * 交互式 TTY  -> 一律英文（English only）
#    * 非 TTY      -> 按系统 locale：zh* 用中文，其余英文
#    * CLUSTER_JOIN_LANG / CLUSTER_BATCH_LANG / --lang 可显式覆盖
#
#  典型用法 / Typical usage
#    # 1) 远程脚本地址下发（推荐，节点无需预置脚本）
#    sh cluster-batch.sh -f hosts.txt --script-url https://example.com/cluster-join.sh \
#        --komari-endpoint https://komari.example.com --komari-ad-key KEY \
#        --et-config-server udp://10.0.0.1:22020/admin
#
#    # 2) 本地脚本文件下发
#    sh cluster-batch.sh -f hosts.txt -j 8 --script ./cluster-join.sh \
#        --komari-ad-key KEY --et-mode peer --et-network-name mynet \
#        --et-network-secret s3cret --et-peers 'tcp://1.2.3.4:11010'
#
#  主机清单 hosts.txt（每行一个，# 开头为注释）
#    10.0.0.1
#    10.0.0.2:2222
#    root@10.0.0.3
#    ops@10.0.0.4:2222
#===============================================================================

BATCH_VERSION='1.0.1'

HOSTS_FILE=''
HOSTS_INLINE=''
SCRIPT_PATH=''
SCRIPT_URL=''
SSH_USER=''
SSH_PORT=''
JOBS=5
TIMEOUT=300
OUTDIR='./cluster-logs'
DRY_RUN=0
LIST_ONLY=0
SSH_EXTRA_OPTS=''
NODE_ARGS=''
BATCH_MODE=1
HAVE_TTY=0
MSG_LANG='en'
RESULT_FILE=''
TMP_DIR=''

#-------------------------------------------------------------------------------
# 兼容层
#-------------------------------------------------------------------------------
_probe_local() { local __probe=1 2>/dev/null; }
if ! _probe_local 2>/dev/null; then
    eval 'local() { :; }' 2>/dev/null || :
fi

#-------------------------------------------------------------------------------
# 终端探测 + 语言层
#-------------------------------------------------------------------------------
detect_tty() {
    HAVE_TTY=0
    if [ -n "${CLUSTER_JOIN_NO_TTY:-}" ]; then
        return 1
    fi
    if [ -c /dev/tty ] && [ -r /dev/tty ]; then
        if (exec </dev/tty) 2>/dev/null; then
            HAVE_TTY=1
            return 0
        fi
    fi
    if [ -t 0 ] 2>/dev/null; then
        HAVE_TTY=1
        return 0
    fi
    return 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_system_locale() {
    for _dl_v in LC_ALL LC_MESSAGES LANG LANGUAGE; do
        eval "_dl_val=\${$_dl_v:-}"
        if [ -n "$_dl_val" ]; then
            printf '%s' "$_dl_val"
            return 0
        fi
    done
    for _dl_f in /etc/locale.conf /etc/default/locale /etc/sysconfig/i18n; do
        [ -r "$_dl_f" ] || continue
        _dl_val=$(sed -n 's/^[[:space:]]*\(LANG\|LC_MESSAGES\|LC_ALL\)[[:space:]]*=[[:space:]]*//p' "$_dl_f" 2>/dev/null | head -n1)
        _dl_val=$(printf '%s' "$_dl_val" | tr -d '"'"'"'')
        if [ -n "$_dl_val" ]; then
            printf '%s' "$_dl_val"
            return 0
        fi
    done
    if have_cmd localectl; then
        _dl_val=$(localectl status 2>/dev/null | sed -n 's/.*System Locale:[[:space:]]*LANG=\([^[:space:]]*\).*/\1/p' | head -n1)
        if [ -n "$_dl_val" ]; then
            printf '%s' "$_dl_val"
            return 0
        fi
    fi
    printf ''
}

is_zh_locale() {
    case "$1" in
        zh*|*_zh*|*zh_*|*zh-*|*ZH_*|*Chinese*) return 0 ;;
        *) return 1 ;;
    esac
}

lang_init() {
    _li_req=${CLUSTER_BATCH_LANG:-${CLUSTER_JOIN_LANG:-}}
    case "$_li_req" in
        zh|zh_*|zh-*|cn|CN) MSG_LANG=zh; lang_load; return 0 ;;
        en|en_*|en-*|EN|C|POSIX) MSG_LANG=en; lang_load; return 0 ;;
    esac
    if [ "$HAVE_TTY" = 1 ]; then
        MSG_LANG=en
    else
        if is_zh_locale "$(detect_system_locale)"; then
            MSG_LANG=zh
        else
            MSG_LANG=en
        fi
    fi
    lang_load
}

lang_load() {
    if [ "$MSG_LANG" = zh ]; then
        lang_load_zh
    else
        lang_load_en
    fi
}

# 消息均为「静态文本」或「标签 + 值」拼接，用户数据不作为 printf 格式串
lang_load_en() {
    T_INFO='INFO' ; T_OK='OK' ; T_WARN='WARN' ; T_ERR='ERROR'
    T_TITLE='Server Cluster Join - batch deploy'
    T_SCRIPT_SRC='Node script source:'
    T_NODE_ARGS='Node args:'
    T_CONCURRENCY='Concurrency:'
    T_PER_TIMEOUT='per-host timeout:'
    T_LOGDIR='log dir:'
    T_NO_TIMEOUT_CMD='timeout command not found; per-host timeout protection is disabled'
    T_HOSTS_PARSED='Target hosts parsed:'
    T_NEED_HOSTS='You must specify target hosts via -f/--file or --hosts'
    T_NO_SSH='ssh client not found on this machine'
    T_SCRIPT_MISSING='Local node script not found:'
    T_SCRIPT_MISSING_HINT='(use --script-url to point at a remote copy)'
    T_JOBS_BAD='--jobs must be a positive integer'
    T_JOBS_MIN='--jobs must be >= 1'
    T_TIMEOUT_BAD='--timeout must be a positive integer'
    T_LOGDIR_FAIL='Cannot create the log directory:'
    T_HOSTFILE_MISSING='Host list file not found:'
    T_HOSTS_EMPTY='Host list is empty'
    T_SENDING='deploying ...'
    T_RC_OK='success'
    T_RC_TIMEOUT='timed out'
    T_RC_FAIL='failed'
    T_RC_NOPRIV='no root/sudo'
    T_EXITCODE='exit='
    T_SUMMARY_TITLE='Batch join summary'
    T_SUM_TOTAL='total:'
    T_SUM_OK='ok:'
    T_SUM_FAIL='failed:'
    T_SUM_TIMEOUT='timeout:'
    T_SUM_NOPRIV='no-priv:'
    T_ALL_OK='All hosts were deployed successfully'
    T_FAIL_TAIL='Tail of the failed hosts log:'
    T_DRYRUN='dry-run'
    T_REMOTE_NOPRIV='[batch] remote host is neither root nor has sudo; cannot join'
    T_LOG_TARGET='### target:'
    T_LOG_TIME='### time:'
    T_LOG_CMD='### command:'
    T_LOG_SCRIPT='### script:'
    T_LOG_VIA_STDIN='(piped via stdin)'
    T_OPT_NEEDS_VALUE='option requires a value:'
    T_UNKNOWN_OPT='Unknown option:'
    T_SEE_HELP='(use --help for usage)'
    return 0
}

lang_load_zh() {
    T_INFO='信息' ; T_OK='完成' ; T_WARN='警告' ; T_ERR='错误'
    T_TITLE='服务器集群并网 - 批量下发'
    T_SCRIPT_SRC='节点脚本来源:'
    T_NODE_ARGS='并网参数:'
    T_CONCURRENCY='并发数:'
    T_PER_TIMEOUT='单机超时:'
    T_LOGDIR='日志目录:'
    T_NO_TIMEOUT_CMD='系统无 timeout 命令，单机超时保护不生效'
    T_HOSTS_PARSED='解析到目标主机数:'
    T_NEED_HOSTS='必须通过 -f/--file 或 --hosts 指定目标主机'
    T_NO_SSH='本机缺少 ssh 客户端'
    T_SCRIPT_MISSING='本地节点脚本不存在:'
    T_SCRIPT_MISSING_HINT='（可用 --script-url 指定远程地址）'
    T_JOBS_BAD='--jobs 必须是正整数'
    T_JOBS_MIN='--jobs 必须 >= 1'
    T_TIMEOUT_BAD='--timeout 必须是正整数'
    T_LOGDIR_FAIL='无法创建日志目录:'
    T_HOSTFILE_MISSING='主机清单文件不存在:'
    T_HOSTS_EMPTY='主机清单解析结果为空'
    T_SENDING='下发中 ...'
    T_RC_OK='成功'
    T_RC_TIMEOUT='超时'
    T_RC_FAIL='失败'
    T_RC_NOPRIV='缺少 root/sudo'
    T_EXITCODE='exit='
    T_SUMMARY_TITLE='批量并网汇总'
    T_SUM_TOTAL='共'
    T_SUM_OK='成功'
    T_SUM_FAIL='失败'
    T_SUM_TIMEOUT='超时'
    T_SUM_NOPRIV='无权限'
    T_ALL_OK='所有主机均已下发成功'
    T_FAIL_TAIL='失败机器日志末尾：'
    T_DRYRUN='dry-run'
    T_REMOTE_NOPRIV='[batch] 远端既非 root 也没有 sudo，无法并网'
    T_LOG_TARGET='### 目标:'
    T_LOG_TIME='### 时间:'
    T_LOG_CMD='### 命令:'
    T_LOG_SCRIPT='### 脚本:'
    T_LOG_VIA_STDIN='（经 stdin 传入）'
    T_OPT_NEEDS_VALUE='选项缺少取值:'
    T_UNKNOWN_OPT='未知选项:'
    T_SEE_HELP='（用 --help 查看帮助）'
    return 0
}

#-------------------------------------------------------------------------------
# 颜色与输出
#-------------------------------------------------------------------------------
USE_COLOR=0
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ] 2>/dev/null; then
    USE_COLOR=1
fi
c_rst='' c_bold='' c_red='' c_grn='' c_ylw='' c_cyn='' c_dim=''
setup_colors() {
    if [ "$USE_COLOR" = 1 ]; then
        c_rst=$(printf '\033[0m');  c_bold=$(printf '\033[1m')
        c_red=$(printf '\033[31m'); c_grn=$(printf '\033[32m')
        c_ylw=$(printf '\033[33m'); c_cyn=$(printf '\033[36m')
        c_dim=$(printf '\033[2m')
    else
        c_rst='' ; c_bold='' ; c_red='' ; c_grn='' ; c_ylw='' ; c_cyn='' ; c_dim=''
    fi
}
setup_colors

info() { printf '%s%s%s %s\n' "$c_cyn" "$T_INFO" "$c_rst" "$*"; }
ok()   { printf '%s%s%s %s\n' "$c_grn" "$T_OK"   "$c_rst" "$*"; }
warn() { printf '%s%s%s %s\n' "$c_ylw" "$T_WARN" "$c_rst" "$*"; }
err()  { printf '%s%s%s %s\n' "$c_red" "$T_ERR"  "$c_rst" "$*" >&2; }
dim()  { printf '%s      %s%s\n' "$c_dim" "$*" "$c_rst"; }
hr()   { printf '%s----------------------------------------------------------------------%s\n' "$c_dim" "$c_rst"; }
die()  { err "$@"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# 单引号安全引用（用于拼装远端命令，已针对 dash/bash 验证）
shq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

usage() {
    if [ "$MSG_LANG" = zh ]; then
        usage_zh
    else
        usage_en
    fi
}

usage_en() {
    cat <<EOF
cluster-batch v$BATCH_VERSION -- Server cluster batch join

Usage:
  sh cluster-batch.sh -f hosts.txt [script source] [--yes] [join options...]

Hosts:
  -f, --file FILE        Host list file (one per line, # comments, user@host:port)
      --hosts 'A,B,C'    Inline host list, comma separated
      --list             Only parse and print the host list, do not execute

Script source (defaults to cluster-join.sh next to this script):
      --script PATH      Local node script (piped over ssh stdin)
      --script-url URL   Remote URL of the node script (remote curl | sh, recommended)

SSH:
  -u, --user USER        ssh login user (overrides the entry)
  -p, --port PORT        ssh port (overrides the entry)
  -j, --jobs N           Concurrency, default $JOBS
  -t, --timeout SEC      Per-host timeout in seconds, default $TIMEOUT
  -o, --outdir DIR       Log output directory, default $OUTDIR
      --ssh-opt 'OPTS'   Extra ssh options, e.g. --ssh-opt '-i /root/.ssh/id_ed25519'
      --insecure-ssh     Skip host key verification (StrictHostKeyChecking=no)
      --ssh-password     Allow interactive ssh password (default BatchMode=yes)

Execution:
  -n, --dry-run          Only print the command that would run on each host
      --no-color         Disable colored output
      --lang zh|en       Force the message language (default: TTY=English,
                         non-TTY=follows the system locale)
  -h, --help             Show this help

Join options (passed through to cluster-join.sh unchanged):
  --komari-endpoint --komari-token --komari-ad-key --komari-interval
  --komari-no-web-ssh --komari-insecure --komari-no-autoupdate --komari-extra
  --et-mode --et-config-server --et-machine-id --et-network-name
  --et-network-secret --et-peers --et-ip --et-no-dhcp --et-hostname
  --et-version --et-extra --gh-proxy --no-gh-proxy
  --et-mode off / --no-easytier   do NOT join the mesh (Komari only)
  --fetch / --with-fetch / --fetch-tool TOOL   install fastfetch / neofetch
  --ip-family 4|6|auto / --no-download         IPv6-only / offline hosts

Examples:
  sh cluster-batch.sh -f hosts.txt --yes -j 8 \\
      --komari-endpoint https://komari.example.com --komari-ad-key 'AD-XXXX' \\
      --et-config-server udp://10.0.0.1:22020/admin
EOF
}

usage_zh() {
    cat <<EOF
cluster-batch v$BATCH_VERSION —— 服务器集群批量并网下发

用法:
  sh cluster-batch.sh -f hosts.txt [脚本来源] [--yes] [并网参数...]

主机来源:
  -f, --file FILE        主机清单文件（每行一个，支持 # 注释与 user@host:port）
      --hosts 'A,B,C'    直接内联主机列表，逗号分隔
      --list             仅解析并打印主机列表，不执行

脚本来源（默认取同目录 cluster-join.sh）:
      --script PATH      本地节点脚本路径（通过 ssh stdin 管道传过去）
      --script-url URL   节点脚本的远程地址（远端 curl | sh，推荐）

SSH 相关:
  -u, --user USER        ssh 登录用户（覆盖清单中的用户）
  -p, --port PORT        ssh 端口（覆盖清单中的端口）
  -j, --jobs N           并发数，默认 $JOBS
  -t, --timeout SEC      单机超时秒数，默认 $TIMEOUT（无 timeout 命令时不生效）
  -o, --outdir DIR       日志输出目录，默认 $OUTDIR
      --ssh-opt 'OPTS'   追加 ssh 选项，例如：--ssh-opt '-i /root/.ssh/id_ed25519'
      --insecure-ssh     跳过主机指纹校验（StrictHostKeyChecking=no）
      --ssh-password     允许 ssh 交互输入密码（默认 BatchMode=yes 免密）

执行控制:
  -n, --dry-run          只打印将要在各节点执行的命令
      --no-color         关闭彩色输出
      --lang zh|en       强制指定消息语言（默认：TTY 用英文，
                         非 TTY 跟随系统 locale）
  -h, --help             显示帮助

并网参数（原样透传给 cluster-join.sh，无需完整列出）:
  --komari-endpoint --komari-token --komari-ad-key --komari-interval
  --komari-no-web-ssh --komari-insecure --komari-no-autoupdate --komari-extra
  --et-mode --et-config-server --et-machine-id --et-network-name
  --et-network-secret --et-peers --et-ip --et-no-dhcp --et-hostname
  --et-version --et-extra --gh-proxy --no-gh-proxy
  --et-mode off / --no-easytier   不启用并网（仅装 Komari 监控）
  --fetch / --with-fetch / --fetch-tool TOOL   安装 fastfetch / neofetch
  --ip-family 4|6|auto / --no-download         纯 IPv6 / 离线环境

示例:
  sh cluster-batch.sh -f hosts.txt --yes -j 8 \\
      --komari-endpoint https://komari.example.com --komari-ad-key 'AD-XXXX' \\
      --et-config-server udp://10.0.0.1:22020/admin
EOF
}

#-------------------------------------------------------------------------------
# 参数解析：batch 自己的选项 + 原样透传选项
#-------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        _a=$1
        case "$_a" in
            -h|--help)      usage; exit 0 ;;
            -f|--file)      [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; HOSTS_FILE=$2; shift ;;
            --file=*)       HOSTS_FILE=${_a#*=} ;;
            --hosts)        [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; HOSTS_INLINE=$2; shift ;;
            --hosts=*)      HOSTS_INLINE=${_a#*=} ;;
            --list)         LIST_ONLY=1 ;;
            --script)       [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; SCRIPT_PATH=$2; shift ;;
            --script=*)     SCRIPT_PATH=${_a#*=} ;;
            --script-url)   [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; SCRIPT_URL=$2; shift ;;
            --script-url=*) SCRIPT_URL=${_a#*=} ;;
            -u|--user)      [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; SSH_USER=$2; shift ;;
            --user=*)       SSH_USER=${_a#*=} ;;
            -p|--port)      [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; SSH_PORT=$2; shift ;;
            --port=*)       SSH_PORT=${_a#*=} ;;
            -j|--jobs)      [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; JOBS=$2; shift ;;
            --jobs=*)       JOBS=${_a#*=} ;;
            -t|--timeout)   [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; TIMEOUT=$2; shift ;;
            --timeout=*)    TIMEOUT=${_a#*=} ;;
            -o|--outdir)    [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; OUTDIR=$2; shift ;;
            --outdir=*)     OUTDIR=${_a#*=} ;;
            --ssh-opt)      [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; SSH_EXTRA_OPTS="$SSH_EXTRA_OPTS $2"; shift ;;
            --ssh-opt=*)    SSH_EXTRA_OPTS="$SSH_EXTRA_OPTS ${_a#*=}" ;;
            --insecure-ssh) SSH_EXTRA_OPTS="$SSH_EXTRA_OPTS -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" ;;
            --ssh-password) BATCH_MODE=0 ;;
            -n|--dry-run)   DRY_RUN=1 ;;
            --no-color)     USE_COLOR=0; setup_colors ;;
            --lang)         [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"; CLUSTER_BATCH_LANG=$2; lang_init; shift ;;
            --lang=*)       CLUSTER_BATCH_LANG=${_a#*=}; lang_init ;;
            -y|--yes)       NODE_ARGS="$NODE_ARGS --yes" ;;

            # ---- 无值的布尔开关：原样透传 ----
            --komari-no-web-ssh|--komari-web-ssh|--komari-insecure|--komari-no-autoupdate|\
            --komari-force-register|--no-service|--install-no-mirror|\
            --fetch|--with-fetch|--fetch-motd|--no-fetch-motd|--no-download|\
            --no-komari|--no-easytier|--no-et|\
            --et-no-dhcp|--et-dhcp|--no-gh-proxy|--purge|--reset-conf)
                NODE_ARGS="$NODE_ARGS $_a" ;;

            # ---- 形如 --opt=value：整体透传 ----
            --komari-*=*|--et-*=*|--web-*=*|--install-*=*|--gh-proxy=*|--uninstall-target=*|--log=*)
                NODE_ARGS="$NODE_ARGS $(shq "$_a")" ;;

            # ---- 需要取值的透传选项（长短写法）----
            -e|--endpoint|--komari-endpoint|--token|--komari-token|\
            --auto-discovery|--komari-ad-key|--komari-interval|--komari-info-interval|\
            --komari-version|--install-dir|--install-service-name|--install-ghproxy|\
            --fetch-tool|--ip-family|--komari-prefer-ip-version|\
            --komari-extra|-w|--et-mode|--et-config-server|--et-machine-id|\
            --et-network-name|--et-network-secret|--et-peers|--et-ip|--et-ipv4|\
            --et-hostname|--et-version|--et-extra|--gh-proxy|--uninstall-target|--log|\
            --web-deploy|--web-port|--web-cfg-port|--web-cfg-proto|--web-api-host)
                [ -n "${2:-}" ] || die "$T_OPT_NEEDS_VALUE $_a"
                NODE_ARGS="$NODE_ARGS $(shq "$_a") $(shq "$2")"; shift ;;

            --) shift
                while [ $# -gt 0 ]; do NODE_ARGS="$NODE_ARGS $(shq "$1")"; shift; done
                break ;;
            *) die "$T_UNKNOWN_OPT $_a $T_SEE_HELP" ;;
        esac
        shift
    done

    # 批量场景下 stdin 被脚本占用，必须无人值守
    case "$NODE_ARGS" in
        *--yes*) : ;;
        *) NODE_ARGS="$NODE_ARGS --yes" ;;
    esac
}

#-------------------------------------------------------------------------------
# 主机清单
#-------------------------------------------------------------------------------
clean_line() {
    printf '%s' "$1" | sed 's/[[:space:]]*#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

parse_hosts() {
    if [ -n "$HOSTS_FILE" ]; then
        [ -f "$HOSTS_FILE" ] || die "$T_HOSTFILE_MISSING $HOSTS_FILE"
        while IFS= read -r _line; do
            _line=$(clean_line "$_line")
            [ -z "$_line" ] && continue
            for _h in $(printf '%s' "$_line" | tr ',' ' '); do
                printf '%s\n' "$_h"
            done
        done <"$HOSTS_FILE"
    fi
    if [ -n "$HOSTS_INLINE" ]; then
        printf '%s\n' "$HOSTS_INLINE" | tr ',' '\n' | while IFS= read -r _l; do
            _l=$(clean_line "$_l")
            [ -n "$_l" ] && printf '%s\n' "$_l"
        done
    fi
}

# 拆分 user@host:port -> HOST_USER / HOST_NAME / HOST_PORT
split_host() {
    _raw=$1
    HOST_USER=''; HOST_NAME=''; HOST_PORT=''
    case "$_raw" in
        *@*) HOST_USER=${_raw%%@*}; _rest=${_raw#*@} ;;
        *)   _rest=$_raw ;;
    esac
    case "$_rest" in
        \[*\]:*) HOST_NAME=${_rest%%]*}; HOST_NAME=${HOST_NAME#[}; HOST_PORT=${_rest##*:} ;;
        *:*)     HOST_NAME=${_rest%%:*}; HOST_PORT=${_rest##*:} ;;
        *)       HOST_NAME=$_rest ;;
    esac
    [ -n "$SSH_USER" ] && HOST_USER=$SSH_USER
    [ -n "$SSH_PORT" ] && HOST_PORT=$SSH_PORT
    [ -n "$HOST_USER" ] || HOST_USER='root'
    return 0
}

safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

#-------------------------------------------------------------------------------
# 远端命令拼装
#-------------------------------------------------------------------------------
build_remote_cmd() {
    if [ -n "$SCRIPT_URL" ]; then
        _src="curl -fsSL $(shq "$SCRIPT_URL") |"
    else
        _src=''
    fi
    printf 'if [ "$(id -u)" = 0 ]; then %s sh -s --%s; ' "$_src" "$NODE_ARGS"
    printf 'elif command -v sudo >/dev/null 2>&1; then %s sudo -n sh -s --%s; ' "$_src" "$NODE_ARGS"
    printf 'else echo %s; exit 77; fi' "$(shq "$T_REMOTE_NOPRIV")"
}

do_ssh() {
    _ds_opts=$1; _ds_target=$2; _ds_cmd=$3; _ds_stdin=${4:-}
    if [ -n "$_ds_stdin" ]; then
        if [ -n "$TIMEOUT_BIN" ]; then
            "$TIMEOUT_BIN" "$TIMEOUT" ssh $_ds_opts "$_ds_target" "$_ds_cmd" <"$_ds_stdin"
        else
            ssh $_ds_opts "$_ds_target" "$_ds_cmd" <"$_ds_stdin"
        fi
    else
        if [ -n "$TIMEOUT_BIN" ]; then
            "$TIMEOUT_BIN" "$TIMEOUT" ssh $_ds_opts "$_ds_target" "$_ds_cmd"
        else
            ssh $_ds_opts "$_ds_target" "$_ds_cmd"
        fi
    fi
}

#-------------------------------------------------------------------------------
# 单机下发
#-------------------------------------------------------------------------------
run_one() {
    _t=$1
    split_host "$_t"
    _target="${HOST_USER}@${HOST_NAME}"
    _log="$OUTDIR/$(safe_name "$_t").log"

    _opts="-o ConnectTimeout=10"
    [ "$BATCH_MODE" = 1 ] && _opts="$_opts -o BatchMode=yes"
    [ -n "$SSH_EXTRA_OPTS" ] && _opts="$_opts $SSH_EXTRA_OPTS"
    [ -n "$HOST_PORT" ] && _opts="$_opts -p $HOST_PORT"

    _remote=$(build_remote_cmd)

    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[%s]%s %s\n' "$c_ylw" "$T_DRYRUN" "$c_rst" "$_t"
        printf '          ssh %s %s %s\n' "$_opts" "$_target" "$_remote"
        [ -z "$SCRIPT_URL" ] && printf '          < %s\n' "$SCRIPT_PATH"
        printf 'OK %s\n' "$_t" >>"$RESULT_FILE"
        return 0
    fi

    {
        printf '%s %s\n' "$T_LOG_TARGET" "$_t"
        printf '%s %s\n' "$T_LOG_TIME" "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        printf '### batch: %s\n' "$BATCH_VERSION"
        printf '%s ssh %s %s %s\n' "$T_LOG_CMD" "$_opts" "$_target" "$_remote"
        if [ -z "$SCRIPT_URL" ]; then printf '%s %s %s\n' "$T_LOG_SCRIPT" "$SCRIPT_PATH" "$T_LOG_VIA_STDIN"; fi
        printf '\n'
    } >"$_log" 2>&1

    printf '%s>>>%s %s %s\n' "$c_cyn" "$c_rst" "$_t" "$T_SENDING"

    if [ -n "$SCRIPT_URL" ]; then
        do_ssh "$_opts" "$_target" "$_remote" >>"$_log" 2>&1
    else
        do_ssh "$_opts" "$_target" "$_remote" "$SCRIPT_PATH" >>"$_log" 2>&1
    fi
    _rc=$?

    case "$_rc" in
        0)   printf 'OK %s\n' "$_t" >>"$RESULT_FILE"
             printf '%s<<<%s %s %s%s%s\n' "$c_grn" "$c_rst" "$_t" "$c_grn" "$T_RC_OK" "$c_rst" ;;
        124) printf 'TIMEOUT %s\n' "$_t" >>"$RESULT_FILE"
             printf '%s<<<%s %s %s%s(%ss)%s\n' "$c_red" "$c_rst" "$_t" "$c_red" "$T_RC_TIMEOUT" "$TIMEOUT" "$c_rst" ;;
        77)  printf 'NOPRIV %s\n' "$_t" >>"$RESULT_FILE"
             printf '%s<<<%s %s %s%s%s\n' "$c_red" "$c_rst" "$_t" "$c_red" "$T_RC_NOPRIV" "$c_rst" ;;
        *)   printf 'FAIL(%s) %s\n' "$_rc" "$_t" >>"$RESULT_FILE"
             printf '%s<<<%s %s %s%s(%s%s)%s\n' "$c_red" "$c_rst" "$_t" "$c_red" "$T_RC_FAIL" "$T_EXITCODE" "$_rc" "$c_rst" ;;
    esac
    return 0
}

#-------------------------------------------------------------------------------
# 汇总
#-------------------------------------------------------------------------------
print_summary() {
    _total=0; _ok=0; _bad=0; _to=0; _np=0
    if [ -f "$RESULT_FILE" ]; then
        while IFS=' ' read -r _st _h; do
            [ -z "$_st" ] && continue
            _total=$((_total + 1))
            case "$_st" in
                OK*)      _ok=$((_ok + 1)) ;;
                TIMEOUT*) _to=$((_to + 1)) ;;
                NOPRIV*)  _np=$((_np + 1)) ;;
                *)        _bad=$((_bad + 1)) ;;
            esac
        done <"$RESULT_FILE"
    fi
    FAILED_COUNT=$((_bad + _to + _np))

    printf '\n'
    hr
    printf '%s%s%s  %s %s  |  %s%s %s%s  |  %s%s %s%s  |  %s%s %s%s  |  %s%s %s%s\n' \
        "$c_bold" "$T_SUMMARY_TITLE" "$c_rst" \
        "$T_SUM_TOTAL" "$_total" \
        "$c_grn" "$T_SUM_OK" "$_ok" "$c_rst" \
        "$c_red" "$T_SUM_FAIL" "$_bad" "$c_rst" \
        "$c_ylw" "$T_SUM_TIMEOUT" "$_to" "$c_rst" \
        "$c_red" "$T_SUM_NOPRIV" "$_np" "$c_rst"
    hr
    if [ -f "$RESULT_FILE" ]; then
        while IFS=' ' read -r _st _h; do
            [ -z "$_st" ] && continue
            case "$_st" in
                OK*)      printf '  %s%-10s%s %-30s %s\n' "$c_grn" "$T_RC_OK"      "$c_rst" "$_h" "$OUTDIR/$(safe_name "$_h").log" ;;
                TIMEOUT*) printf '  %s%-10s%s %-30s %s\n' "$c_ylw" "$T_RC_TIMEOUT" "$c_rst" "$_h" "$OUTDIR/$(safe_name "$_h").log" ;;
                NOPRIV*)  printf '  %s%-10s%s %-30s %s\n' "$c_red" "$T_RC_NOPRIV"  "$c_rst" "$_h" "$OUTDIR/$(safe_name "$_h").log" ;;
                *)        printf '  %s%-10s%s %-30s %s\n' "$c_red" "$_st"          "$c_rst" "$_h" "$OUTDIR/$(safe_name "$_h").log" ;;
            esac
        done <"$RESULT_FILE"
    fi
    hr

    if [ -f "$RESULT_FILE" ]; then
        _shown=0
        while IFS=' ' read -r _st _h; do
            [ -z "$_st" ] && continue
            case "$_st" in OK*) continue ;; esac
            if [ "$_shown" = 0 ]; then
                info "$T_FAIL_TAIL"
                _shown=1
            fi
            printf '\n%s--- %s ---%s\n' "$c_bold" "$_h" "$c_rst"
            tail -n 8 "$OUTDIR/$(safe_name "$_h").log" 2>/dev/null || :
        done <"$RESULT_FILE"
        [ "$_shown" = 0 ] && ok "$T_ALL_OK"
    fi
    hr
}

#-------------------------------------------------------------------------------
# 入口
#-------------------------------------------------------------------------------
cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" 2>/dev/null || :
    fi
    :;
}

main() {
    # 先探测终端与语言（均无输出），保证之后所有消息语言正确
    detect_tty
    lang_init

    parse_args "$@"

    have ssh || die "$T_NO_SSH"

    if [ -z "$HOSTS_FILE" ] && [ -z "$HOSTS_INLINE" ]; then
        usage
        die "$T_NEED_HOSTS"
    fi

    if [ -z "$SCRIPT_URL" ]; then
        if [ -z "$SCRIPT_PATH" ]; then
            SCRIPT_PATH="$(dirname "$0" 2>/dev/null)/cluster-join.sh"
        fi
        if [ ! -f "$SCRIPT_PATH" ]; then
            die "$T_SCRIPT_MISSING $SCRIPT_PATH $T_SCRIPT_MISSING_HINT"
        fi
        SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$(basename "$SCRIPT_PATH")"
    fi

    case "$JOBS" in ''|*[!0-9]*) die "$T_JOBS_BAD" ;; esac
    [ "$JOBS" -ge 1 ] || die "$T_JOBS_MIN"
    case "$TIMEOUT" in ''|*[!0-9]*) die "$T_TIMEOUT_BAD" ;; esac

    TIMEOUT_BIN=''
    have timeout && TIMEOUT_BIN='timeout'

    TMP_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/cluster-batch.$$")
    [ -d "$TMP_DIR" ] || mkdir -p "$TMP_DIR" 2>/dev/null || TMP_DIR='/tmp'
    RESULT_FILE="$TMP_DIR/results.txt"
    : >"$RESULT_FILE"
    trap 'cleanup' EXIT
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM

    printf '%s=== cluster-batch v%s  %s ===%s\n' "$c_cyn" "$BATCH_VERSION" "$T_TITLE" "$c_rst"
    if [ -n "$SCRIPT_URL" ]; then
        dim "$T_SCRIPT_SRC $SCRIPT_URL"
    else
        dim "$T_SCRIPT_SRC $SCRIPT_PATH"
    fi
    dim "$T_NODE_ARGS --all$NODE_ARGS"
    dim "$T_CONCURRENCY $JOBS   $T_PER_TIMEOUT ${TIMEOUT}s   $T_LOGDIR $OUTDIR"
    [ -z "$TIMEOUT_BIN" ] && warn "$T_NO_TIMEOUT_CMD"

    parse_hosts >"$TMP_DIR/hosts.txt"
    _count=0
    while IFS= read -r _l; do
        [ -n "$_l" ] && _count=$((_count + 1))
    done <"$TMP_DIR/hosts.txt"
    [ "$_count" -gt 0 ] || die "$T_HOSTS_EMPTY"
    info "$T_HOSTS_PARSED $_count"

    if [ "$LIST_ONLY" = 1 ]; then
        hr
        while IFS= read -r _h; do
            [ -z "$_h" ] && continue
            split_host "$_h"
            if [ -n "$HOST_PORT" ]; then
                printf '  %-30s -> %s@%s:%s\n' "$_h" "$HOST_USER" "$HOST_NAME" "$HOST_PORT"
            else
                printf '  %-30s -> %s@%s\n' "$_h" "$HOST_USER" "$HOST_NAME"
            fi
        done <"$TMP_DIR/hosts.txt"
        hr
        cleanup; trap - EXIT
        return 0
    fi

    if [ "$DRY_RUN" != 1 ]; then
        mkdir -p "$OUTDIR" || die "$T_LOGDIR_FAIL $OUTDIR"
    fi

    hr
    _i=0
    while IFS= read -r _h; do
        [ -z "$_h" ] && continue
        run_one "$_h" &
        _i=$((_i + 1))
        if [ $((_i % JOBS)) -eq 0 ]; then
            wait
        fi
    done <"$TMP_DIR/hosts.txt"
    wait

    print_summary
    cleanup
    trap - EXIT

    [ "${FAILED_COUNT:-0}" = 0 ] && return 0
    return 1
}

main "$@"
exit $?
