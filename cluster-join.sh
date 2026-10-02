#!/bin/sh
#===============================================================================
#  cluster-join.sh —— 服务器集群并网脚本 / Server cluster join script
#
#  Komari Agent 安装  +  EasyTier 组网安装（支持 Web 控制台 / web 托管）
#  Komari Agent install + EasyTier mesh networking (web-console managed)
#
#  设计目标 / Design goals
#    * 同时兼容 POSIX sh (dash / ash / busybox sh) 与 bash，不依赖 bash 专有语法
#    * 同时支持三种运行环境：
#        1) 交互式 TTY          —— 菜单 + 逐项提问
#        2) 管道执行 curl|sh    —— 自动改用 /dev/tty 读取输入
#        3) 无 TTY / 无人值守    —— 全部走命令行参数与环境变量，绝不挂起
#    * 幂等：重复执行只会重新安装/更新并重启服务
#
#  语言策略 / Language policy
#    * 交互式 TTY          -> 一律英文（English only）
#    * 非 TTY（脚本/批量）  -> 按系统 locale 决定：zh* 用中文，其余用英文
#    * 可用 CLUSTER_JOIN_LANG=zh|en 或 --lang 显式覆盖
#
#  快速使用 / Quick start
#    交互式菜单:  sudo sh cluster-join.sh
#    管道式:      curl -fsSL <脚本地址> | sudo sh -s -- --yes --komari-endpoint ... --et-config-server ...
#    无人值守:    sudo sh cluster-join.sh --yes --komari-endpoint ... --et-config-server ...
#    只打印命令:  sh cluster-join.sh --emit-cmd --komari-endpoint ...
#
#  官方资料 / References
#    Komari   https://www.komari.wiki/
#    EasyTier https://easytier.cn/
#===============================================================================

# --- 运行环境自检 ---------------------------------------------------------
# zsh 默认**不做单词分割**，且未匹配的 glob 会直接报错（nomatch），
# 与本脚本依赖的 POSIX sh 语义不符（镜像列表、代理参数、架构候选等 15 处依赖分词，
# 不分词会让整串被当成单个参数，表现为下载静默失败）。
# 切到 zsh 的 sh 模拟；其他 shell 没有 emulate，会被 if 跳过。
if [ -n "${ZSH_VERSION:-}" ]; then
    emulate -R sh 2>/dev/null || :
    # 自检：确认分词真的可用。宁可明确报错，也不要静默装错东西。
    _sc_probe='a b'
    _sc_n=0
    for _sc_x in $_sc_probe; do _sc_n=$((_sc_n + 1)); done
    if [ "$_sc_n" != 2 ]; then
        printf 'ERROR: this script requires POSIX sh word splitting.\n' >&2
        printf '       请改用 sh 或 bash 运行，例如: sh %s ...\n' "$0" >&2
        exit 1
    fi
    unset _sc_probe _sc_n _sc_x
fi
APP_NAME='cluster-join'
APP_VERSION='1.0.1'
SCRIPT_START_TS=$(date +%s 2>/dev/null || echo 0)

#-------------------------------------------------------------------------------
# 0. 兼容层：local 在 dash / ash / busybox / bash / mksh 中均可用；
#    ksh93 等不支持，用 eval 在运行期降级为 no-op（写在 eval 里可避免 dash 解析期报错）
#-------------------------------------------------------------------------------
_probe_local() { local __probe=1 2>/dev/null; }
if ! _probe_local 2>/dev/null; then
    eval 'local() { :; }' 2>/dev/null || :
fi

#-------------------------------------------------------------------------------
# 1. 默认值（可被命令行 / 环境变量 / 配置文件覆盖）
#-------------------------------------------------------------------------------
# 目录与文件
ET_DIR=${ET_DIR:-/opt/easytier}
ET_CONF_DIR="$ET_DIR/config"
ET_WEB_DIR="$ET_DIR/web"
ET_CORE="$ET_DIR/easytier-core"
ET_CLI="$ET_DIR/easytier-cli"
ET_WEB_BIN="$ET_DIR/easytier-web-embed"

KOMARI_DIR=${KOMARI_DIR:-/opt/komari}
KOMARI_BIN="$KOMARI_DIR/komari-agent"
# 脚本生成的 0600 配置文件：密钥只落在这里，服务单元不出现任何密钥
KOMARI_AGENT_CFG="$KOMARI_DIR/agent.json"
# agent 自己写出的注册产物（含 uuid + 节点令牌）
KOMARI_AD_FILE="$KOMARI_DIR/auto-discovery.json"

KOMARI_SERVICE=${KOMARI_SERVICE:-komari-agent}
ET_SERVICE=${ET_SERVICE:-easytier}
ET_WEB_SERVICE=${ET_WEB_SERVICE:-easytier-web}

LOG_FILE=${LOG_FILE:-/var/log/cluster-join.log}
# 参数存档文件：默认 root 用 /etc/cluster-join/cluster.env，普通用户用 ~/.config/...
CONF_FILE=${CLUSTER_JOIN_CONF:-}
TMP_DIR=''

# GitHub 相关
GH_KOMARI_REPO='komari-monitor/komari-agent'
GH_EASYTIER_REPO='EasyTier/EasyTier'
# 自动 GitHub 加速镜像（按顺序尝试，可用 --gh-proxy 指定或 --no-gh-proxy 关闭）
GH_MIRRORS_DEFAULT='https://ghfast.top/ https://gh-proxy.com/ https://ghproxy.net/'
# IPv6 纯机时会被过滤成「实测可达」的子集
GH_MIRRORS_ACTIVE="$GH_MIRRORS_DEFAULT"

# --- 运行状态变量 ---
ACTION='auto'            # auto | menu | all | komari | easytier | web | status | uninstall | emit | help
INTERACTIVE=0            # 1 = 允许交互提问
HAVE_TTY=0               # 1 = 存在可用的控制终端
ASSUME_YES=0             # 1 = 所有提问取默认值
DRY_RUN=0
NO_KOMARI=0
NO_ET=0
UNINSTALL_TARGET='all'
UNINSTALL_PURGE=0
GH_PROXY=''
NO_GH_PROXY=${NO_GH_PROXY:-}
IP_FAMILY=${IP_FAMILY:-}          # auto | 4 | 6
CURL_FAMILY=''                    # 传给 curl/wget 的 -4 / -6
NET_IPV6_ONLY=0                   # 1 = 本机只有 IPv6
KOMARI_PREFER_IP=${KOMARI_PREFER_IP:-}
NO_DOWNLOAD=${NO_DOWNLOAD:-0}      # 1 = 只用预置二进制，不联网下载
# 出网代理 / Resin 反向代理
PROXY_URL=${PROXY_URL:-}           # 正向代理，如 http://127.0.0.1:2260
PROXY_AUTH=${PROXY_AUTH:-}         # 代理认证（Resin: Platform.Account:TOKEN）
RESIN_URL=${RESIN_URL:-}           # Resin 反向代理入口，如 http://127.0.0.1:2260
RESIN_TOKEN=${RESIN_TOKEN:-}       # Resin 反向代理 token（URL 路径段）
RESIN_ACCOUNT=${RESIN_ACCOUNT:-}   # Resin [Platform.]Account，可选
CURL_PROXY_ARGS=''
WGET_PROXY_ENV=''
HTTP_NO_RESIN=0                   # 1 = 本次请求绕过 Resin（用于回退）
ALT_SCREEN=${ALT_SCREEN:-}         # '' = auto（交互 TTY 时启用）| 1 | 0
ALT_SCREEN_ON=0                    # 当前是否处于备用屏
LOG_TO_FILE=0
SERVICE_MODE=''          # systemd | openrc | procd | manual
OS_NAME=''
ARCH_RAW=''
MSG_LANG='en'            # en | zh —— 由 lang_init 决定

# --- Komari 参数 ---
# 说明：凡是「可能来自参数存档文件」的变量，这里一律不给非空默认值，
#       统一交给 apply_defaults 在 load_conf 之后兜底。否则像 ET_MODE=web 这种
#       非空默认值会挡住存档文件里的 ET_MODE=peer（load_conf 只填空值）。
KOMARI_ENDPOINT=${KOMARI_ENDPOINT:-}
KOMARI_TOKEN=${KOMARI_TOKEN:-}
KOMARI_AD_KEY=${KOMARI_AD_KEY:-}
KOMARI_INTERVAL=${KOMARI_INTERVAL:-}
KOMARI_INFO_INTERVAL=${KOMARI_INFO_INTERVAL:-}
KOMARI_DISABLE_WEB_SSH=${KOMARI_DISABLE_WEB_SSH:-}
KOMARI_INSECURE=${KOMARI_INSECURE:-}
KOMARI_DISABLE_AUTOUPDATE=${KOMARI_DISABLE_AUTOUPDATE:-}
KOMARI_EXTRA=${KOMARI_EXTRA:-}
KOMARI_FORCE_REGISTER=${KOMARI_FORCE_REGISTER:-0}
KOMARI_VERSION=${KOMARI_VERSION:-}
KOMARI_ARGS=''

# --- EasyTier 参数 ---
ET_MODE=${ET_MODE:-}                    # web | peer | server
ET_CONFIG_SERVER=${ET_CONFIG_SERVER:-}  # udp://host:22020/user 或 仅用户名（官方控制台）
ET_MACHINE_ID=${ET_MACHINE_ID:-}
ET_NETWORK_NAME=${ET_NETWORK_NAME:-}
ET_NETWORK_SECRET=${ET_NETWORK_SECRET:-}
ET_PEERS=${ET_PEERS:-}
ET_IPV4=${ET_IPV4:-}
ET_DHCP=${ET_DHCP:-}
ET_HOSTNAME=${ET_HOSTNAME:-}
ET_EXTRA=${ET_EXTRA:-}
ET_VERSION=${ET_VERSION:-}
ET_LISTEN_PORT=${ET_LISTEN_PORT:-}
ET_ARGS=''
WEB_ARGS=''

# --- EasyTier Web 控制台（服务端 / web 托管）参数 ---
WEB_DEPLOY=${WEB_DEPLOY:-}              # binary | docker | none
WEB_PORT=${WEB_PORT:-}
WEB_CFG_PORT=${WEB_CFG_PORT:-}
WEB_CFG_PROTO=${WEB_CFG_PROTO:-}
WEB_API_HOST=${WEB_API_HOST:-}
WEB_BIND_ADDR=${WEB_BIND_ADDR:-}

# --- 系统信息工具（fastfetch / neofetch）---
FETCH_TOOL=${FETCH_TOOL:-}                    # auto | fastfetch | neofetch
WITH_FETCH=${WITH_FETCH:-0}                   # 1 = 并网动作结束后追加安装
FETCH_MOTD=${FETCH_MOTD:-1}                     # 1 = 安装 MOTD 钩子（探针终端/SSH 登录显示）
FETCH_MOTD_EXPLICIT=0                           # 用户是否显式指定过 --fetch-motd
FETCH_SHELLRC=${FETCH_SHELLRC:-0}               # 1 = 安装交互式 shell rc 钩子（含 GNOME 终端新窗口）
FETCH_SHELLRC_SNIP=${FETCH_SHELLRC_SNIP:-/etc/profile.d/99-fastfetch.sh}
FETCH_SHELLRC_RCS=${FETCH_SHELLRC_RCS:-/etc/bash.bashrc /etc/zsh/zshrc /etc/zshrc}
FETCH_MOTD_DIR=${FETCH_MOTD_DIR:-/etc/update-motd.d}
FETCH_BIN_DIR=${FETCH_BIN_DIR:-/usr/local/bin}
FETCH_SHARE_DIR=${FETCH_SHARE_DIR:-/usr/local/share}

# 兜底默认值：必须在 load_conf 之后调用
apply_defaults() {
    [ -n "$ET_MODE" ] || ET_MODE='web'
    [ -n "$ET_DHCP" ] || ET_DHCP=1
    [ -n "$ET_LISTEN_PORT" ] || ET_LISTEN_PORT=11010
    # --install-dir 可能在 parse_args 里改过 KOMARI_DIR，这里归一化并重算派生路径
    case "$KOMARI_DIR" in */) KOMARI_DIR=${KOMARI_DIR%/} ;; esac
    case "$ET_DIR" in */) ET_DIR=${ET_DIR%/} ;; esac
    ET_CONF_DIR="$ET_DIR/config"
    ET_WEB_DIR="$ET_DIR/web"
    ET_CORE="$ET_DIR/easytier-core"
    ET_CLI="$ET_DIR/easytier-cli"
    ET_WEB_BIN="$ET_DIR/easytier-web-embed"
    KOMARI_BIN="$KOMARI_DIR/komari-agent"
    KOMARI_AGENT_CFG="$KOMARI_DIR/agent.json"
    KOMARI_AD_FILE="$KOMARI_DIR/auto-discovery.json"
    [ -n "$KOMARI_VERSION" ] || KOMARI_VERSION='latest'
    [ -n "$KOMARI_INTERVAL" ] || KOMARI_INTERVAL=1
    [ -n "$KOMARI_DISABLE_WEB_SSH" ] || KOMARI_DISABLE_WEB_SSH=0
    [ -n "$KOMARI_INSECURE" ] || KOMARI_INSECURE=0
    [ -n "$KOMARI_DISABLE_AUTOUPDATE" ] || KOMARI_DISABLE_AUTOUPDATE=0
    [ -n "$WEB_DEPLOY" ] || WEB_DEPLOY='binary'
    [ -n "$WEB_PORT" ] || WEB_PORT=11211
    [ -n "$WEB_CFG_PORT" ] || WEB_CFG_PORT=22020
    [ -n "$WEB_CFG_PROTO" ] || WEB_CFG_PROTO='udp'
    [ -n "$WEB_BIND_ADDR" ] || WEB_BIND_ADDR='0.0.0.0'
    [ -n "$FETCH_TOOL" ] || FETCH_TOOL='auto'
    [ -n "$IP_FAMILY" ] || IP_FAMILY='auto'
    [ -n "$NO_GH_PROXY" ] || NO_GH_PROXY=0
    build_proxy_args
    parse_resin_url
    # shell rc 钩子覆盖面是 MOTD 钩子的超集（非登录交互式 shell 也覆盖）；
    # 两者同开会让 SSH 登录显示两次，所以启用 rc 钩子时默认关掉 MOTD 钩子。
    if [ "$FETCH_SHELLRC" = 1 ] && [ "$FETCH_MOTD_EXPLICIT" != 1 ]; then
        FETCH_MOTD=0
    fi
    return 0
}

#-------------------------------------------------------------------------------
# 2. 终端探测（无输出，必须在 lang_init 之前完成）
#-------------------------------------------------------------------------------
# 探测是否存在可打开的控制终端（管道执行时 stdin 是脚本本身，必须用 /dev/tty）。
# 注意：在子 shell 中试探 exec 重定向，避免 dash 因重定向失败而直接退出。
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

#-------------------------------------------------------------------------------
# 3. 语言层
#    交互式 TTY  -> 英文（固定策略）
#    非 TTY      -> 按系统 locale：zh* 用中文，其余英文
#    CLUSTER_JOIN_LANG / --lang 可显式覆盖
#-------------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 读取系统 locale（环境变量 -> 系统配置文件 -> localectl）
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

# 语言判定：无输出
lang_init() {
    case "${CLUSTER_JOIN_LANG:-}" in
        zh|zh_*|zh-*|cn|CN) MSG_LANG=zh; lang_load; return 0 ;;
        en|en_*|en-*|EN|C|POSIX) MSG_LANG=en; lang_load; return 0 ;;
    esac
    if [ "$HAVE_TTY" = 1 ]; then
        # 交互式终端：一律英文
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

# 说明：所有消息都是「静态文本」或「标签 + 值」的拼接，
#       绝不把用户数据当 printf 格式串使用，避免 % 引发格式注入。
lang_load_en() {
    # --- 日志标签 ---
    T_INFO='INFO' ; T_OK='OK' ; T_WARN='WARN' ; T_ERR='ERROR'
    # --- banner ---
    T_BANNER_TITLE='Server Cluster Join  |  Komari Agent + EasyTier (web-managed)'
    T_BANNER_SUB="v$APP_VERSION  |  sh/bash compatible  |  TTY / pipe / unattended"
    T_BANNER_LANG='Language: English (interactive TTY always uses English)'
    # --- 通用 ---
    T_HR_TITLE_MAIN='Server Cluster Join  |  Main menu'
    T_SELECT='Select'
    T_YESNO_HINT='Please answer y or n'
    T_RANGE_A='Please enter a number between 1 and'
    T_EOF_MENU='Input finished, leaving the menu.'
    T_CANCELLED='Cancelled'
    T_NEED_YES='Non-interactive environment: this operation needs an explicit --yes'
    T_CONFIRM_UNINSTALL='Uninstall the selected components? (y/n)'
    T_BYE='Goodbye!'
    T_BAD_CHOICE='Invalid choice, please enter 0-10'
    # --- fastfetch / neofetch ---
    T_STEP_FETCH='Installing a system info tool (fastfetch / neofetch)'
    T_FETCH_DONE='Installed:'
    T_FETCH_WOULD='Would install:'
    T_FETCH_ALREADY='Already installed:'
    T_FETCH_FALLBACK='fastfetch is unavailable; falling back to neofetch'
    T_FETCH_FAIL='Failed to install the system info tool'
    T_FETCH_TOOL_BAD='Invalid --fetch-tool (expected auto|fastfetch|neofetch):'
    T_FETCH_ARCH_UNSUPPORTED='No prebuilt fastfetch binary for this architecture:'
    T_FETCH_TAG_FAIL='Cannot resolve the latest release tag for:'
    T_FETCH_UNPACK_FAIL='Failed to unpack the archive:'
    T_FETCH_NO_BIN='Executable not found in the archive:'
    T_FETCH_NEED_BASH='neofetch is a bash script but bash is not available'
    T_FETCH_PKG='Trying the system package manager:'
    T_FETCH_BIN='Installing the official release:'
    T_FETCH_MOTD_OK='Login hook installed (shows on SSH login and in the Komari web terminal):'
    T_FETCH_MOTD_FAIL='Cannot install the login hook:'
    T_FETCH_SHELLRC_OK='Interactive-shell hook installed:'
    T_FETCH_SHELLRC_RC='hooked into interactive shell rc:'
    T_FETCH_SHELLRC_PRESENT='already hooked:'
    T_FETCH_SHELLRC_FAIL='Cannot install the interactive-shell hook:'
    T_FETCH_SHELLRC_REMOVED='Interactive-shell hook removed from:'
    T_NEED_VALUE='option requires a value:'
    T_UNKNOWN_OPT='Unknown option:'
    T_SEE_HELP='(use --help for usage)'
    T_UNKNOWN_ARG='Unknown argument:'
    # --- root / 依赖 ---
    T_ROOT_DRYRUN='Running as non-root (continuing because of --dry-run)'
    T_ROOT_NEED='Root privileges are required. Run with sudo, or install sudo first.'
    T_ROOT_RERUN='Non-root detected; re-executing with sudo ...'
    T_ROOT_PIPE='Running from a pipe as non-root. Use: curl ... | sudo sh -s -- <args>'
    T_NO_DOWNLOADER='Neither curl nor wget is available and it could not be installed automatically'
    T_IP_FAMILY_BAD='Invalid --ip-family (expected auto|4|6):'
    T_RESIN_NEED_TOKEN='--resin requires --resin-token (the <token> path segment)'
    T_RESIN_USING='Resin reverse proxy:'
    T_RESIN_RETRY='Resin gateway returned 5xx/timeout, retrying:'
    T_DL_FALLBACK_DIRECT='Resin failed for every source; falling back to direct / mirrors:'
    T_RESIN_TAIL_IGNORED='(--resin: only the <token>/[Platform.]Account prefix is used; the rest is ignored)'
    T_RESIN_REDIRECT_NOTE='redirects are followed manually so every hop stays inside Resin'
    T_PROXY_USING='Outbound proxy:'
    T_NET_IPV6_ONLY='IPv6-only host detected'
    T_NET_V6_NO_GITHUB='GitHub publishes no AAAA at all (github.com / api.github.com / objects.githubusercontent.com), and the built-in mirrors are IPv4-only. Downloading is impossible from this host.'
    T_NET_V6_PROBE_SKIP='(dry-run: mirror reachability not probed)'
    T_NODL_MISSING='--no-download was given but the binary is missing:'
    T_NODL_USING='--no-download: using the existing binary:'
    T_NET_V6_MIRRORS='Reachable IPv6 mirrors kept:'
    T_NET_V6_NO_MIRROR='No IPv6-capable mirror is reachable; downloads cannot proceed.'
    T_NET_V6_HINT='Workarounds: (1) --gh-proxy URL pointing at an IPv6-capable GitHub proxy; (2) pre-place the binaries (Komari agent, EasyTier core+cli) and re-run with --no-download; (3) NAT64/DNS64, or push from a dual-stack jump host.'
    T_NET_V6_PREFER='Komari agent will prefer IPv6 for panel connections.'
    T_DL_INSTALLING='curl / wget not found; trying to install one ...'
    T_DL_INSTALLED='Download tool installed:'
    T_NO_UNZIP='Cannot install unzip automatically; please install it manually and retry'
    T_UNZIP_TRY='unzip / python3 not found, trying to install unzip ...'
    T_DL_FAILED='download failed (direct and all mirrors)'
    T_DL_REASONS='per-attempt reason:'
    T_DL_NODIR='destination directory does not exist:'
    T_BIN_EMPTY='downloaded file is empty:'
    T_BIN_SMALL='downloaded file is suspiciously small (truncated download?):'
    T_DL_BAD_CONTENT='HTTP 200 but the content is not a binary; trying the next source:'
    T_DL_BYTES='bytes, magic'
    T_DL_ALL_BAD_CONTENT='every source returned a non-binary response; a captive portal or interception is likely'
    T_BIN_NOT_EXEC='downloaded file is not an executable (HTML / error page / captive portal?):'
    T_BIN_NOT_EXEC_MAGIC='first bytes:'
    T_BIN_NOT_EXEC_HINT='a captive portal or transparent proxy often returns HTTP 200 with an HTML page; retry with --gh-proxy, --proxy or --resin'
    T_KOMARI_BIN_BROKEN='the komari-agent binary at this path does not run:'
    T_KOMARI_BIN_BROKEN_HINT='the download was truncated or is not a real binary; delete it and retry, or use --gh-proxy / --proxy / --resin'
    T_DL_NOWRITE='destination directory is not writable:'
    T_DL_HINT_RESIN='a Resin reverse proxy is configured and may be unreachable:'
    T_DL_HINT_PROXY='a forward proxy is configured and may be unreachable:'
    T_DL_HINT_ENVPROXY='the environment sets proxy variables, which curl/wget honor:'
    T_DL_HINT_NOMIRROR='mirrors are disabled (--no-gh-proxy); only direct GitHub was tried'
    T_DL_HINT_GENERIC='check outbound connectivity, or route through --proxy / --resin / --gh-proxy'
    T_E_PROXY_RESOLVE='cannot resolve the proxy host'
    T_E_RESOLVE='cannot resolve the host (DNS)'
    T_E_CONNECT='connection failed (unreachable or refused)'
    T_E_HTTP='HTTP error (403/404/...)'
    T_E_WRITE='cannot write to the destination'
    T_E_TIMEOUT='timeout'
    T_E_TRUNCATED='transfer truncated (got/expected bytes):'
    T_E_TRUNCATED_SIMPLE='transfer truncated (connection closed early)'
    T_E_TLS='TLS/SSL handshake failed'
    T_E_RECV='connection reset while receiving'
    T_E_RESIN='Resin reverse-proxy request failed'
    T_E_OTHER='failed with exit code'
    T_OS_UNSUPPORTED='Unsupported OS, continuing anyway:'
    # --- 预检 ---
    T_STEP_PREFLIGHT='Environment preflight'
    T_OS_INFO='OS / arch / init:'
    T_INIT_MANUAL_1='No systemd / OpenRC / procd detected; will fall back to nohup (common in containers).'
    T_INIT_MANUAL_2='In containers make sure --device /dev/net/tun --cap-add NET_ADMIN are set.'
    T_INIT_MANUAL_3='No autostart in this mode: the process will NOT come back after a reboot.'
    T_TTY_YES='Interactive terminal detected: prompts enabled'
    T_TTY_STDIN='No terminal: reading interactive answers from standard input'
    T_TTY_NO='No terminal detected: non-interactive mode, defaults are used for anything not provided'
    T_TUN_OK='TUN device /dev/net/tun is present'
    T_TUN_MISSING='/dev/net/tun is missing; EasyTier may fail to create the virtual interface'
    T_TUN_LOADED='tun module loaded'
    T_TUN_LOADFAIL='failed to load the tun module'
    T_TUN_HINT='No TUN device: either enable it on the host (OpenVZ/LXC must allow it; containers need --device /dev/net/tun --cap-add NET_ADMIN), or run EasyTier without a virtual interface via: --et-extra "--no-tun" (subnet proxy / SOCKS5 only)'
    T_DL_OK='Download tools available'
    T_PREFLIGHT_DONE='Preflight passed'
    # --- Komari ---
    T_STEP_KOMARI_CFG='Komari Agent configuration'
    T_KOMARI_PANEL='Komari panel URL (e.g. https://komari.example.com)'
    T_KOMARI_PANEL_SET='Komari panel URL:'
    T_KOMARI_SKIP_URL='No panel URL provided; skipping Komari Agent'
    T_KOMARI_USE_AD='Use an auto-discovery key (AD Key)? [y = AD Key, n = per-node Token]'
    T_KOMARI_AD='Auto-discovery key (AD Key; panel -> Auto discovery; used ONCE, never stored)'
    T_KOMARI_TOKEN='Per-node Agent Token (panel -> Add node)'
    T_KOMARI_NO_TOKEN='No node token available: run once with --komari-ad-key (recommended) or --komari-token'
    T_KOMARI_INTERVAL='Reporting interval in seconds'
    T_KOMARI_REGISTERING='Registering with the panel using the AD Key (one-time bootstrap) ...'
    T_KOMARI_REGISTERED='Registered; the node token was obtained and stored locally'
    T_KOMARI_REGISTER_FAIL='Registration failed; check the AD Key and panel reachability. Last output:'
    T_KOMARI_CFG_WRITTEN='Agent config written (mode 600):'
    T_KOMARI_CFG_FAIL='Cannot write the agent config file:'
    T_KOMARI_REUSE='Reusing the locally registered node token (no AD Key needed)'
    T_KOMARI_NO_CONFIG_FLAG='This komari-agent build does not support --config; cannot keep the token out of the unit file. Update the agent.'
    T_KOMARI_VERSION_IS='Installing Komari Agent version:'
    T_KOMARI_VER_FAIL='Cannot resolve the requested Komari Agent version:'
    T_KOMARI_NOWEBSSH='Disable remote control (Web SSH / remote exec)? (y/n)'
    T_STEP_KOMARI_INSTALL='Installing Komari Agent'
    T_KOMARI_BAD_ARCH='Komari Agent does not support this architecture:'
    T_KOMARI_OS_WARN='Komari official binaries target Linux; current OS:'
    T_LABEL_KOMARI='Komari Agent'
    T_BIN_READY='Binary ready:'
    T_BIN_REPLACE_FAIL='Cannot replace the running binary (is the service still holding it?):'
    T_CMDLINE='Command line:'
    # --- EasyTier ---
    T_STEP_ET_CFG='EasyTier networking configuration'
    T_ET_CUR_MODE='Current mode:'
    T_ET_CHOOSE_MODE='Select the EasyTier mode (join the mesh or not)'
    T_ET_MODE_WEB='Join mesh - Web console managed (recommended)'
    T_ET_MODE_PEER='Join mesh - Shared node / P2P (network name + secret)'
    T_ET_MODE_SERVER='Join mesh - This host as a shared node (relay server)'
    T_ET_MODE_OFF='Do NOT join the mesh (skip EasyTier; Komari monitoring only)'
    T_ET_DISABLED='EasyTier mesh join is disabled; skipping EasyTier'
    T_ET_MODE_BAD='Invalid --et-mode (expected web|peer|server|off):'
    T_ET_CHOOSE_CONSOLE='Web console type'
    T_ET_CONSOLE_SELF='Self-hosted console (this script can deploy it; udp://IP:22020/user)'
    T_ET_CONSOLE_PUBLIC='EasyTier public console (username only)'
    T_ET_CFG_SERVER='Config server address (udp://IP:22020/username)'
    T_ET_CONSOLE_USER='Public console username'
    T_ET_SKIP_CFG='No config server provided; skipping EasyTier'
    T_ET_MACHINE_ID='Fixed machine-id (empty = auto; set it to keep the same node identity across reinstalls)'
    T_ET_HOSTNAME='Virtual network hostname (empty = system hostname)'
    T_ET_NETNAME='Network name (network-name)'
    T_ET_NETNAME_EMPTY='Network name cannot be empty'
    T_ET_NETSECRET='Network secret (network-secret)'
    T_ET_NETSECRET_EMPTY='Network secret cannot be empty'
    T_ET_PEERS='Peer / shared node addresses (space separated, e.g. tcp://1.2.3.4:11010)'
    T_ET_PEERS_EMPTY='At least one peer address is required'
    T_ET_IP='Virtual IP of this node (empty = auto assign)'
    T_ET_SERVER_IP='Virtual IP of this node'
    T_ET_LISTEN_PORT='Listen port'
    T_ET_SERVER_NOTE='TCP/UDP listeners will be opened and traffic relayed for other networks'
    T_ET_VERSION='EasyTier version (empty = latest, e.g. v2.6.4)'
    T_STEP_ET_INSTALL='Installing EasyTier'
    T_ET_BIN_PRESENT='EasyTier binaries already present:'
    T_ET_RESOLVING='Resolving the latest EasyTier version ...'
    T_ET_VER_UNKNOWN='Cannot determine the EasyTier version; pass --et-version explicitly (e.g. --et-version v2.6.4)'
    T_ET_VERSION_IS='EasyTier version:'
    T_ET_BAD_ARCH='EasyTier does not support this architecture:'
    T_ET_TRY_ARCH='Trying package: linux-'
    T_ET_DL_FAIL='EasyTier download failed'
    T_ET_DL_OK='Downloaded: linux-'
    T_ET_UNZIP_FAIL='Extraction failed; check that unzip or python3 is available'
    T_ET_MISSING='Expected files are missing from the archive:'
    T_ET_NOSPACE='Not enough free space to unpack the archive on:'
    T_ET_NEED='need about'
    T_ET_FREE='available'
    T_ET_BIN_READY='EasyTier binaries ready:'
    T_ET_SVC_OFFICIAL='Registering the service through the official interface: easytier-cli service install'
    T_ET_SVC_FALLBACK='easytier-cli service install failed; falling back to writing the unit file manually'
    # --- Web 控制台 ---
    T_STEP_WEB_CFG='EasyTier Web Console (server) configuration'
    T_WEB_CHOOSE='Deployment method'
    T_WEB_BINARY='Binary deployment (recommended, no Docker needed)'
    T_WEB_DOCKER='Docker deployment'
    T_WEB_NONE='Skip for now'
    T_WEB_PORT='Web UI/API port'
    T_WEB_CFG_PORT='Config push port'
    T_WEB_CFG_PROTO='Config push protocol (udp/tcp/ws)'
    T_WEB_API_HOST='API host used by the web frontend'
    T_STEP_WEB_INSTALL='Deploying the EasyTier Web Console'
    T_WEB_NO_DOCKER='Docker not found; falling back to binary deployment'
    T_WEB_CONTAINER_OK='Web console container started'
    T_WEB_NEED_BIN='EasyTier binaries are not installed yet; downloading binaries only (no node service)'
    T_WEB_URL='Web console URL:'
    T_WEB_REGISTER='Open it and click Register to create an account (built-in test accounts: admin / user)'
    # --- 服务管理 ---
    T_SVC_RESTARTED='Enabled and restarted:'
    T_SVC_UNKNOWN_MANUAL='Unknown service in manual mode:'
    T_SVC_NOHUP='Started in background (nohup):'
    T_SVC_PID='pid'
    T_SVC_PIDFILE_FAIL='pid file not writable:'
    # --- 状态 ---
    T_STEP_STATUS='Runtime status'
    T_ST_COMPONENT='Component'
    T_ST_SERVICE='Service'
    T_ST_STATUS='Status'
    T_ST_RUNNING='running'
    T_ST_STOPPED='stopped'
    T_ST_ET_PEERS='EasyTier virtual network peers:'
    T_ST_ET_NODE='EasyTier local node:'
    T_ST_IFACES='Virtual interfaces:'
    T_ST_PORTS='Listening ports:'
    T_ST_LOGS='Recent logs:'
    T_ST_NO_PEER='(no output from easytier-cli peer)'
    T_ST_NO_IFACE='(no virtual interface found)'
    T_ST_NO_PORT='(no related listening port found)'
    T_ST_NO_SS='(ss/netstat not available)'
    T_ST_NO_LOG='(no log)'
    # --- 卸载 ---
    T_STEP_UNINSTALL='Uninstall (target:'
    T_UNINSTALLED='removed:'
    T_PURGED='Configuration and data directories deleted'
    T_KEPT='Configuration and data directories kept (add --purge to delete them)'
    T_PATHS='Paths:'
    # --- emit ---
    T_EMIT_1='1) With the script already downloaded:'
    T_EMIT_2='2) One-liner via pipe (recommended):'
    # --- 菜单 ---
    T_MENU_1='All-in-one join (EasyTier + Komari Agent)'
    T_MENU_2='Install / update Komari Agent only'
    T_MENU_3='Install / configure EasyTier only'
    T_MENU_4='Deploy EasyTier Web Console (server / web-managed)'
    T_MENU_5='Show runtime status'
    T_MENU_6='Print the batch deployment command'
    T_MENU_7='Uninstall'
    T_MENU_8='Install fastfetch / neofetch (system info tool)'
    T_MENU_9='Switch language / 切换语言'
    T_MENU_10='Network & proxy settings (gh-proxy / proxy / Resin)'
    T_MENU_BACK='Back'
    T_PRESS_ENTER='Press Enter to return to the menu ...'
    T_PM_TITLE='Network & proxy settings'
    T_PM_GH='GitHub acceleration prefix'
    T_PM_MIRROR='Use built-in GitHub mirrors?'
    T_PM_PROXY='Forward proxy (http:// or socks5h://)'
    T_PM_PROXY_AUTH='Forward proxy credentials (Resin: Platform.Account:TOKEN)'
    T_PM_RESIN='Resin reverse-proxy base URL'
    T_PM_RESIN_TOKEN='Resin reverse-proxy token'
    T_PM_RESIN_ACCOUNT='Resin [Platform.]Account (optional)'
    T_PM_CLEAR='Clear all proxy settings?'
    T_PM_CLEARED='Proxy settings cleared'
    T_PM_SAVED='Saved and active for this session'
    T_PM_NONE='(not set)'
    T_PM_ON='enabled'
    T_PM_OFF='disabled'
    T_PM_BAD='Invalid choice, please enter 0-8'
    T_LANG_CHOOSE='Choose the message language'
    T_LANG_SWITCHED='Language switched to'
    T_LANG_SESSION_ONLY='Applies to this run only. To make it permanent: --lang zh|en or CLUSTER_JOIN_LANG=zh|en'
    T_MENU_0='Exit'
    T_MENU_RECOMMENDED='recommended'
    T_MENU_DEFAULT='default'
    # --- 汇总 ---
    T_SUMMARY_DONE='This join operation completed'
    T_SUMMARY_PANEL='Komari panel:'
    T_SUMMARY_REMOTE_ON='Note: remote control is enabled; add --komari-no-web-ssh to tighten it'
    T_SUMMARY_ET_WEB='EasyTier: web managed   config server:'
    T_SUMMARY_ET_PEER='EasyTier: P2P   network:'
    T_SUMMARY_ET_PEER2='peers:'
    T_SUMMARY_ET_SERVER='EasyTier: shared node   IP:'
    T_SUMMARY_ET_SERVER2='port:'
    T_SUMMARY_ET_OFF='EasyTier: disabled (mesh join skipped)'
    # --- main ---
    T_ERR_NO_CONF='Non-interactive environment with no configuration provided.'
    T_ERR_MENU_TTY='--menu requires an interactive terminal; pass CLI arguments instead (see --help).'
    T_SAVED_CONF='Configuration saved:'
    T_SAVE_FAIL='Cannot create the configuration directory, skipping save:'
    T_SAVE_WRITE_FAIL='Failed to write the configuration file:'
    return 0
}

lang_load_zh() {
    # --- 日志标签 ---
    T_INFO='信息' ; T_OK='完成' ; T_WARN='警告' ; T_ERR='错误'
    # --- banner ---
    T_BANNER_TITLE='服务器集群并网  ·  Komari Agent + EasyTier (web托管)'
    T_BANNER_SUB="v$APP_VERSION  ·  兼容 sh/bash  ·  TTY / 管道 / 无人值守"
    T_BANNER_LANG='语言: 中文（非交互环境，按系统 locale 选择）'
    # --- 通用 ---
    T_HR_TITLE_MAIN='服务器集群并网  ·  主菜单'
    T_SELECT='请选择'
    T_YESNO_HINT='请输入 y 或 n'
    T_RANGE_A='请输入 1 到'
    T_EOF_MENU='输入已结束，退出菜单。'
    T_CANCELLED='已取消'
    T_NEED_YES='非交互环境：该操作需要显式加 --yes 才会执行'
    T_CONFIRM_UNINSTALL='确认要卸载所选组件吗？(y/n)'
    T_BYE='再见！'
    T_BAD_CHOICE='无效选择，请输入 0-10'
    # --- fastfetch / neofetch ---
    T_STEP_FETCH='安装系统信息工具（fastfetch / neofetch）'
    T_FETCH_DONE='已安装:'
    T_FETCH_WOULD='将安装:'
    T_FETCH_ALREADY='已安装:'
    T_FETCH_FALLBACK='fastfetch 不可用，回退安装 neofetch'
    T_FETCH_FAIL='系统信息工具安装失败'
    T_FETCH_TOOL_BAD='--fetch-tool 取值无效（应为 auto|fastfetch|neofetch）:'
    T_FETCH_ARCH_UNSUPPORTED='该架构没有 fastfetch 预编译二进制:'
    T_FETCH_TAG_FAIL='无法解析最新 release 标签:'
    T_FETCH_UNPACK_FAIL='解压失败:'
    T_FETCH_NO_BIN='压缩包中未找到可执行文件:'
    T_FETCH_NEED_BASH='neofetch 是 bash 脚本，但系统没有 bash'
    T_FETCH_PKG='尝试系统包管理器:'
    T_FETCH_BIN='安装官方发布物:'
    T_FETCH_MOTD_OK='已装登录钩子（SSH 登录与 Komari 探针终端都会显示）:'
    T_FETCH_MOTD_FAIL='无法安装登录钩子:'
    T_FETCH_SHELLRC_OK='已装交互式 shell 钩子:'
    T_FETCH_SHELLRC_RC='已接入交互式 shell rc:'
    T_FETCH_SHELLRC_PRESENT='已接入过:'
    T_FETCH_SHELLRC_FAIL='无法安装交互式 shell 钩子:'
    T_FETCH_SHELLRC_REMOVED='已从以下文件移除交互式 shell 钩子:'
    T_NEED_VALUE='选项缺少取值:'
    T_UNKNOWN_OPT='未知选项:'
    T_SEE_HELP='（用 --help 查看帮助）'
    T_UNKNOWN_ARG='未知参数:'
    # --- root / 依赖 ---
    T_ROOT_DRYRUN='当前非 root（dry-run 模式继续）'
    T_ROOT_NEED='需要 root 权限，请使用 sudo 运行，或先安装 sudo。'
    T_ROOT_RERUN='检测到非 root，正在通过 sudo 重新执行 ...'
    T_ROOT_PIPE='当前以管道方式运行且非 root，请改用: curl ... | sudo sh -s -- <参数>'
    T_NO_DOWNLOADER='缺少 curl / wget，且自动安装失败，请手动安装其中之一'
    T_IP_FAMILY_BAD='--ip-family 取值无效（应为 auto|4|6）:'
    T_RESIN_NEED_TOKEN='使用 --resin 时必须同时给 --resin-token（URL 里的 <token> 段）'
    T_RESIN_USING='Resin 反向代理:'
    T_RESIN_RETRY='Resin 网关返回 5xx/超时，重试第'
    T_DL_FALLBACK_DIRECT='Resin 对所有源均失败，回退到直连 / 镜像:'
    T_RESIN_TAIL_IGNORED='（--resin：只取 <token>/[Platform.]Account 前缀，其余部分忽略）'
    T_RESIN_REDIRECT_NOTE='重定向由脚本自行跟随，保证每一跳都在 Resin 内'
    T_PROXY_USING='出网代理:'
    T_NET_IPV6_ONLY='检测到纯 IPv6 主机'
    T_NET_V6_NO_GITHUB='GitHub 完全没有 IPv6（github.com / api.github.com / objects.githubusercontent.com 均无 AAAA），内置镜像也全是 IPv4-only。本机无法下载。'
    T_NET_V6_PROBE_SKIP='（dry-run：未实测镜像可达性）'
    T_NODL_MISSING='指定了 --no-download，但二进制不存在:'
    T_NODL_USING='--no-download：使用已有二进制:'
    T_NET_V6_MIRRORS='保留实测可达的 IPv6 镜像:'
    T_NET_V6_NO_MIRROR='没有可达的 IPv6 镜像，下载无法进行。'
    T_NET_V6_HINT='可选办法：(1) 用 --gh-proxy 指定支持 IPv6 的 GitHub 代理；(2) 预置二进制（Komari agent、EasyTier core+cli）后加 --no-download 重跑；(3) 走 NAT64/DNS64，或从双栈跳板机下发。'
    T_NET_V6_PREFER='Komari Agent 将优先用 IPv6 连接面板。'
    T_DL_INSTALLING='未找到 curl / wget，尝试自动安装 ...'
    T_DL_INSTALLED='已安装下载工具:'
    T_NO_UNZIP='无法自动安装 unzip，请手动安装后重试'
    T_UNZIP_TRY='未找到 unzip / python3，尝试自动安装 unzip ...'
    T_DL_FAILED='下载失败（直连与所有镜像均不可用）'
    T_DL_REASONS='逐次失败原因:'
    T_DL_NODIR='目标目录不存在:'
    T_BIN_EMPTY='下载到的文件为空:'
    T_BIN_SMALL='下载到的文件异常偏小（可能被截断）:'
    T_DL_BAD_CONTENT='返回 HTTP 200 但内容不是二进制，换下一个源:'
    T_DL_BYTES='字节，文件头'
    T_DL_ALL_BAD_CONTENT='所有源返回的都不是二进制，很可能被门户页 / 劫持拦截'
    T_BIN_NOT_EXEC='下载到的不是可执行文件（HTML / 错误页 / 门户页？）:'
    T_BIN_NOT_EXEC_MAGIC='文件头字节:'
    T_BIN_NOT_EXEC_HINT='门户页或透明代理常返回 HTTP 200 + 一段 HTML；请改用 --gh-proxy / --proxy / --resin 重试'
    T_KOMARI_BIN_BROKEN='该路径下的 komari-agent 无法运行:'
    T_KOMARI_BIN_BROKEN_HINT='下载可能被截断或不是真二进制；删掉后重试，或用 --gh-proxy / --proxy / --resin'
    T_DL_NOWRITE='目标目录不可写:'
    T_DL_HINT_RESIN='已配置 Resin 反向代理，可能不可达:'
    T_DL_HINT_PROXY='已配置正向代理，可能不可达:'
    T_DL_HINT_ENVPROXY='环境变量里设了代理，curl/wget 会使用它们:'
    T_DL_HINT_NOMIRROR='已禁用镜像（--no-gh-proxy），只尝试了直连'
    T_DL_HINT_GENERIC='请检查出网连通性，或用 --proxy / --resin / --gh-proxy 指定出口'
    T_E_PROXY_RESOLVE='无法解析代理主机'
    T_E_RESOLVE='无法解析主机（DNS）'
    T_E_CONNECT='连接失败（不可达或被拒绝）'
    T_E_HTTP='HTTP 错误（403/404 等）'
    T_E_WRITE='无法写入目标文件'
    T_E_TIMEOUT='超时'
    T_E_TRUNCATED='传输被截断（实收/应收字节）:'
    T_E_TRUNCATED_SIMPLE='传输被截断（连接提前关闭）'
    T_E_TLS='TLS/SSL 握手失败'
    T_E_RECV='接收过程中连接被重置'
    T_E_RESIN='Resin 反向代理请求失败'
    T_E_OTHER='失败，退出码'
    T_OS_UNSUPPORTED='未在支持列表内的系统，继续尝试:'
    # --- 预检 ---
    T_STEP_PREFLIGHT='环境预检'
    T_OS_INFO='系统 / 架构 / 服务管理:'
    T_INIT_MANUAL_1='未检测到 systemd / OpenRC / procd，将退化为 nohup 方式启动（容器环境常见）。'
    T_INIT_MANUAL_2='容器中请确保已挂载 --device /dev/net/tun --cap-add NET_ADMIN。'
    T_INIT_MANUAL_3='此模式下没有自启动：机器重启后进程不会自动拉起。'
    T_TTY_YES='检测到控制终端：支持交互输入'
    T_TTY_STDIN='无控制终端：改为从标准输入读取交互答案'
    T_TTY_NO='未检测到控制终端：进入非交互模式，未提供的参数将使用默认值'
    T_TUN_OK='TUN 设备 /dev/net/tun 正常'
    T_TUN_MISSING='/dev/net/tun 不存在，EasyTier 可能无法创建虚拟网卡'
    T_TUN_LOADED='已加载 tun 模块'
    T_TUN_LOADFAIL='tun 模块加载失败'
    T_TUN_HINT='无 TUN 设备：要么在宿主侧开启（OpenVZ/LXC 需宿主放行；容器需 --device /dev/net/tun --cap-add NET_ADMIN），要么用 --et-extra "--no-tun" 让它不建虚拟网卡（仅子网代理/SOCKS5 可用）'
    T_DL_OK='下载工具正常'
    T_PREFLIGHT_DONE='预检通过'
    # --- Komari ---
    T_STEP_KOMARI_CFG='Komari Agent 配置'
    T_KOMARI_PANEL='Komari 面板地址 (例 https://komari.example.com)'
    T_KOMARI_PANEL_SET='Komari 面板地址:'
    T_KOMARI_SKIP_URL='未填写面板地址，跳过 Komari Agent 安装'
    T_KOMARI_USE_AD='使用自动发现密钥(AD Key)？[y=AD Key，n=单节点 Token]'
    T_KOMARI_AD='自动发现密钥 (AD Key；面板 → 自动发现；仅用一次，不落盘)'
    T_KOMARI_TOKEN='单节点 Agent Token（面板 → 添加节点 中获取）'
    T_KOMARI_NO_TOKEN='没有可用的节点令牌：请带 --komari-ad-key（推荐）或 --komari-token 跑一次完成注册'
    T_KOMARI_INTERVAL='数据上报间隔(秒)'
    T_KOMARI_REGISTERING='正在用 AD Key 向面板注册（一次性引导）...'
    T_KOMARI_REGISTERED='注册成功，节点令牌已取得并保存在本机'
    T_KOMARI_REGISTER_FAIL='注册失败，请检查 AD Key 与面板连通性。末尾输出:'
    T_KOMARI_CFG_WRITTEN='Agent 配置已写入（权限 600）:'
    T_KOMARI_CFG_FAIL='无法写入 Agent 配置文件:'
    T_KOMARI_REUSE='复用本机已注册的节点令牌（无需再提供 AD Key）'
    T_KOMARI_NO_CONFIG_FLAG='当前 komari-agent 不支持 --config，无法把令牌放在服务单元之外，请更新 Agent。'
    T_KOMARI_VERSION_IS='正在安装 Komari Agent 版本:'
    T_KOMARI_VER_FAIL='无法解析指定的 Komari Agent 版本:'
    T_KOMARI_NOWEBSSH='禁用远程控制（Web SSH / 远程执行）？(y/n)'
    T_STEP_KOMARI_INSTALL='安装 Komari Agent'
    T_KOMARI_BAD_ARCH='Komari Agent 不支持当前架构:'
    T_KOMARI_OS_WARN='Komari 官方二进制主要面向 Linux，当前系统:'
    T_LABEL_KOMARI='Komari Agent'
    T_BIN_READY='二进制就绪:'
    T_BIN_REPLACE_FAIL='无法替换正在运行的二进制（服务是否仍占用？）:'
    T_CMDLINE='启动参数:'
    # --- EasyTier ---
    T_STEP_ET_CFG='EasyTier 组网配置'
    T_ET_CUR_MODE='当前模式:'
    T_ET_CHOOSE_MODE='请选择 EasyTier 模式（启用并网 / 不启用）'
    T_ET_MODE_WEB='启用并网 · Web 控制台托管（推荐，集中管理、配置下发）'
    T_ET_MODE_PEER='启用并网 · 共享节点/P2P 直连（自填网络名与密码）'
    T_ET_MODE_SERVER='启用并网 · 本机作为共享节点（中继服务器）'
    T_ET_MODE_OFF='不启用并网（跳过 EasyTier，仅安装 Komari 监控）'
    T_ET_DISABLED='已选择不启用并网，跳过 EasyTier'
    T_ET_MODE_BAD='--et-mode 取值无效（应为 web|peer|server|off）:'
    T_ET_CHOOSE_CONSOLE='Web 控制台类型'
    T_ET_CONSOLE_SELF='自建控制台（本脚本可部署，格式 udp://IP:22020/用户名）'
    T_ET_CONSOLE_PUBLIC='EasyTier 官方公共控制台（只需填写用户名）'
    T_ET_CFG_SERVER='配置下发地址 (udp://IP:22020/用户名)'
    T_ET_CONSOLE_USER='官方控制台用户名'
    T_ET_SKIP_CFG='未填写配置下发地址，跳过 EasyTier'
    T_ET_MACHINE_ID='固定机器标识 machine-id（留空自动生成，重装保持同一身份可填写）'
    T_ET_HOSTNAME='虚拟网络主机名 hostname（留空用系统主机名）'
    T_ET_NETNAME='虚拟网络名称 network-name'
    T_ET_NETNAME_EMPTY='网络名称不能为空'
    T_ET_NETSECRET='虚拟网络密码 network-secret'
    T_ET_NETSECRET_EMPTY='网络密码不能为空'
    T_ET_PEERS='共享节点/对端地址（空格分隔，如 tcp://1.2.3.4:11010）'
    T_ET_PEERS_EMPTY='至少填写一个对端地址'
    T_ET_IP='本节点虚拟 IP（留空自动分配）'
    T_ET_SERVER_IP='本机在虚拟网络中的 IP'
    T_ET_LISTEN_PORT='监听端口'
    T_ET_SERVER_NOTE='将开放 tcp/udp 监听并允许转发其它网络流量'
    T_ET_VERSION='EasyTier 版本（留空安装最新版，如 v2.6.4）'
    T_STEP_ET_INSTALL='安装 EasyTier'
    T_ET_BIN_PRESENT='EasyTier 二进制已就绪:'
    T_ET_RESOLVING='正在解析 EasyTier 最新版本 ...'
    T_ET_VER_UNKNOWN='无法获取 EasyTier 版本号，请用 --et-version 手动指定（如 --et-version v2.6.4）'
    T_ET_VERSION_IS='EasyTier 版本:'
    T_ET_BAD_ARCH='EasyTier 不支持当前架构:'
    T_ET_TRY_ARCH='尝试架构包: linux-'
    T_ET_DL_FAIL='EasyTier 下载失败'
    T_ET_DL_OK='已下载: linux-'
    T_ET_UNZIP_FAIL='解压失败，请检查 unzip/python3 是否可用'
    T_ET_MISSING='压缩包中缺少预期文件:'
    T_ET_NOSPACE='磁盘可用空间不足，无法解压压缩包:'
    T_ET_NEED='需要约'
    T_ET_FREE='可用'
    T_ET_BIN_READY='EasyTier 二进制就绪:'
    T_ET_SVC_OFFICIAL='使用官方接口注册服务: easytier-cli service install'
    T_ET_SVC_FALLBACK='easytier-cli service install 失败，回退为手工写入服务文件'
    # --- Web 控制台 ---
    T_STEP_WEB_CFG='EasyTier Web 控制台（服务端）配置'
    T_WEB_CHOOSE='部署方式'
    T_WEB_BINARY='二进制部署（推荐，无需 Docker）'
    T_WEB_DOCKER='Docker 部署'
    T_WEB_NONE='暂不部署'
    T_WEB_PORT='Web 前后端端口'
    T_WEB_CFG_PORT='配置下发端口'
    T_WEB_CFG_PROTO='配置下发协议 (udp/tcp/ws)'
    T_WEB_API_HOST='前端访问后端的地址'
    T_STEP_WEB_INSTALL='部署 EasyTier Web 控制台'
    T_WEB_NO_DOCKER='未检测到 docker，自动改为二进制部署'
    T_WEB_CONTAINER_OK='Web 控制台容器已启动'
    T_WEB_NEED_BIN='未安装 EasyTier 二进制，先下载二进制（不注册节点服务）'
    T_WEB_URL='Web 控制台地址:'
    T_WEB_REGISTER='首次访问请点击 Register 注册账户（内置测试账户: admin / user）'
    # --- 服务管理 ---
    T_SVC_RESTARTED='已启用并重启:'
    T_SVC_UNKNOWN_MANUAL='manual 模式下未知服务:'
    T_SVC_NOHUP='已后台启动 (nohup):'
    T_SVC_PID='pid'
    T_SVC_PIDFILE_FAIL='pid 文件不可写:'
    # --- 状态 ---
    T_STEP_STATUS='运行状态'
    T_ST_COMPONENT='组件'
    T_ST_SERVICE='服务'
    T_ST_STATUS='状态'
    T_ST_RUNNING='运行中'
    T_ST_STOPPED='已停止'
    T_ST_ET_PEERS='EasyTier 虚拟网络节点:'
    T_ST_ET_NODE='EasyTier 本机节点:'
    T_ST_IFACES='虚拟网卡:'
    T_ST_PORTS='监听端口:'
    T_ST_LOGS='最近日志:'
    T_ST_NO_PEER='（easytier-cli peer 无输出）'
    T_ST_NO_IFACE='（未发现虚拟网卡）'
    T_ST_NO_PORT='（未发现相关监听端口）'
    T_ST_NO_SS='（系统缺少 ss/netstat）'
    T_ST_NO_LOG='（无日志）'
    # --- 卸载 ---
    T_STEP_UNINSTALL='卸载 (目标:'
    T_UNINSTALLED='已卸载:'
    T_PURGED='配置与数据目录已删除'
    T_KEPT='已保留配置与数据目录（加 --purge 可一并删除）'
    T_PATHS='相关路径:'
    # --- emit ---
    T_EMIT_1='1) 已下载脚本时:'
    T_EMIT_2='2) 管道一键下发（推荐）:'
    # --- 菜单 ---
    T_MENU_1='一键并网（EasyTier 组网 + Komari Agent）'
    T_MENU_2='仅安装/更新 Komari Agent'
    T_MENU_3='仅安装/配置 EasyTier 组网'
    T_MENU_4='部署 EasyTier Web 控制台（服务端 / web 托管）'
    T_MENU_5='查看运行状态'
    T_MENU_6='输出批量下发命令'
    T_MENU_7='卸载'
    T_MENU_8='安装 fastfetch / neofetch（系统信息工具）'
    T_MENU_9='切换语言 / Switch language'
    T_MENU_10='网络与代理设置（gh-proxy / 代理 / Resin）'
    T_MENU_BACK='返回'
    T_PRESS_ENTER='按回车返回主菜单 ...'
    T_PM_TITLE='网络与代理设置'
    T_PM_GH='GitHub 加速前缀'
    T_PM_MIRROR='启用内置 GitHub 镜像？'
    T_PM_PROXY='正向代理（http:// 或 socks5h://）'
    T_PM_PROXY_AUTH='正向代理认证（Resin 为 Platform.Account:TOKEN）'
    T_PM_RESIN='Resin 反向代理入口 URL'
    T_PM_RESIN_TOKEN='Resin 反向代理 token'
    T_PM_RESIN_ACCOUNT='Resin [Platform.]Account（可选）'
    T_PM_CLEAR='清空全部代理设置？'
    T_PM_CLEARED='代理设置已清空'
    T_PM_SAVED='已保存，本次会话立即生效'
    T_PM_NONE='(未设置)'
    T_PM_ON='启用'
    T_PM_OFF='禁用'
    T_PM_BAD='无效选择，请输入 0-8'
    T_LANG_CHOOSE='请选择消息语言'
    T_LANG_SWITCHED='语言已切换为'
    T_LANG_SESSION_ONLY='仅对本次运行生效。要永久生效：--lang zh|en 或 CLUSTER_JOIN_LANG=zh|en'
    T_MENU_0='退出'
    T_MENU_RECOMMENDED='推荐'
    T_MENU_DEFAULT='默认'
    # --- 汇总 ---
    T_SUMMARY_DONE='本次并网操作完成'
    T_SUMMARY_PANEL='Komari 面板:'
    T_SUMMARY_REMOTE_ON='提示: 未禁用远程控制，如需收紧权限请加 --komari-no-web-ssh'
    T_SUMMARY_ET_WEB='EasyTier: Web 托管  配置下发:'
    T_SUMMARY_ET_PEER='EasyTier: P2P  网络:'
    T_SUMMARY_ET_PEER2='对端:'
    T_SUMMARY_ET_SERVER='EasyTier: 共享节点  IP:'
    T_SUMMARY_ET_SERVER2='端口:'
    T_SUMMARY_ET_OFF='EasyTier: 未启用并网（已跳过）'
    # --- main ---
    T_ERR_NO_CONF='非交互环境且未提供任何配置参数。'
    T_ERR_MENU_TTY='--menu 需要可交互的终端；无终端时请直接用命令行参数（见 --help）。'
    T_SAVED_CONF='已保存配置:'
    T_SAVE_FAIL='无法创建配置目录，跳过配置保存:'
    T_SAVE_WRITE_FAIL='写入配置失败:'
    return 0
}

#-------------------------------------------------------------------------------
# 4. 输出 / 日志
#-------------------------------------------------------------------------------
USE_COLOR=0
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ] 2>/dev/null; then
    USE_COLOR=1
fi

c_rst='' c_bold='' c_red='' c_grn='' c_ylw='' c_blu='' c_cyn='' c_dim=''
setup_colors() {
    if [ "$USE_COLOR" = 1 ]; then
        c_rst=$(printf '\033[0m')  ; c_bold=$(printf '\033[1m')
        c_red=$(printf '\033[31m') ; c_grn=$(printf '\033[32m')
        c_ylw=$(printf '\033[33m') ; c_blu=$(printf '\033[34m')
        c_cyn=$(printf '\033[36m') ; c_dim=$(printf '\033[2m')
    else
        c_rst='' ; c_bold='' ; c_red='' ; c_grn='' ; c_ylw='' ; c_blu='' ; c_cyn='' ; c_dim=''
    fi
}
setup_colors

_ts() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-'; }

# ---- 备用屏（alternate screen）----
# 像 vim/less 一样接管整屏，退出时把原屏幕内容原样还回来。
# 只在「有控制终端 + stdout 是终端 + TERM 可用」时启用：
# stdout 若被重定向到文件，绝不能把转义序列写进去。
ALT_SEQ_ENTER=''
ALT_SEQ_LEAVE=''
alt_screen_supported() {
    [ "$ALT_SCREEN" = 0 ] && return 1
    [ "$HAVE_TTY" = 1 ] || return 1
    [ -t 1 ] 2>/dev/null || return 1
    case "${TERM:-}" in ''|dumb) return 1 ;; esac
    return 0
}

alt_screen_seq() { # alt_screen_seq <smcup|rmcup> <xterm 回退序列>
    _as_cap=$1; _as_fb=$2; _as_out=''
    if have tput; then
        _as_out=$(tput "$_as_cap" 2>/dev/null) || _as_out=''
    fi
    [ -n "$_as_out" ] || _as_out=$_as_fb
    printf '%s' "$_as_out"
}

alt_screen_enter() {
    [ "$ALT_SCREEN_ON" = 1 ] && return 0
    alt_screen_supported || return 0
    ALT_SEQ_ENTER=$(alt_screen_seq smcup "$(printf '\033[?1049h')")
    printf '%s' "$ALT_SEQ_ENTER"
    # 只把光标归位，不主动清屏：[2J 清的是「当前可见屏」，
    # 在支持备用屏的终端里多余，在不支持备用屏的终端里会真的抹掉用户屏幕内容。
    printf '\033[H'
    ALT_SCREEN_ON=1
    return 0
}

alt_screen_leave() {
    [ "$ALT_SCREEN_ON" = 1 ] || return 0
    ALT_SEQ_LEAVE=$(alt_screen_seq rmcup "$(printf '\033[?1049l')")
    printf '%s' "$ALT_SEQ_LEAVE"
    ALT_SCREEN_ON=0
    return 0
}

# emit <color> <tag> <message...>
emit() {
    _c=$1; _tag=$2; shift 2
    printf '%s%s%s %s\n' "$_c" "$_tag" "$c_rst" "$*"
    if [ "$LOG_TO_FILE" = 1 ]; then
        printf '%s [%s] %s\n' "$(_ts)" "$_tag" "$*" 2>/dev/null >>"$LOG_FILE" || :
    fi
}

info()  { emit "${c_blu}"  "$T_INFO" "$@"; }
ok()    { emit "${c_grn}"  "$T_OK"   "$@"; }
warn()  { emit "${c_ylw}"  "$T_WARN" "$@"; }
err()   { emit "${c_red}"  "$T_ERR"  "$@" >&2; }
dim()   { emit "${c_dim}"  '      '  "$@"; }
step()  { printf '\n%s==>%s %s%s%s\n' "$c_cyn" "$c_rst" "$c_bold" "$*" "$c_rst"; }
hr()    { printf '%s%s%s\n' "$c_dim" '----------------------------------------------------------------------' "$c_rst"; }
die()   { err "$@"; exit 1; }

banner() {
    printf '%s' "$c_cyn"
    cat <<'BANNER'
   ___  _     _   _  ___  ___      _  _  _  _
  / __|| |   | | | || __|/ __|    | || \| || |
 | (__ | |__ | |_| || _| \__ \ _  | || |\  ||
  \___||____| \___/ |___||___/(_) |_||_| \_||_|
BANNER
    printf '%s' "$c_rst"
    printf '%s  %s%s\n' "$c_dim" "$T_BANNER_TITLE" "$c_rst"
    printf '%s  %s%s\n' "$c_dim" "$T_BANNER_SUB" "$c_rst"
    printf '%s  %s%s\n' "$c_dim" "$T_BANNER_LANG" "$c_rst"
}

#-------------------------------------------------------------------------------
# 5. 输入层（TTY 感知）
#-------------------------------------------------------------------------------
# 从终端读取一行到全局 REPLY；成功返回 0，EOF 返回 1
read_line() {
    if [ "$HAVE_TTY" = 1 ]; then
        IFS= read -r REPLY </dev/tty 2>/dev/null
    else
        IFS= read -r REPLY
    fi
}

_wr() { # 向终端（或 stdout）写提示
    if [ "$HAVE_TTY" = 1 ]; then
        printf '%s' "$*" >/dev/tty
    else
        printf '%s' "$*"
    fi
}

# ask_text <标签> [默认值] [是否密文 0/1]
#   结果写入全局 ANS；取消/EOF 时 ANS 取默认值
ANS=''
ask_text() {
    _at_label=$1
    _at_def=${2:-}
    _at_mask=${3:-0}

    if [ "$INTERACTIVE" != 1 ]; then
        ANS=$_at_def
        return 0
    fi

    if [ "$_at_def" != '' ]; then
        _wr "$_at_label [$(_mask_hint "$_at_def" "$_at_mask")]: "
    else
        _wr "$_at_label: "
    fi

    if [ "$_at_mask" = 1 ] && [ "$HAVE_TTY" = 1 ]; then
        _stty_echo_off
        if ! read_line; then
            _stty_echo_on
            printf '\n' >/dev/tty 2>/dev/null
            ANS=$_at_def
            return 1
        fi
        _stty_echo_on
        printf '\n' >/dev/tty 2>/dev/null
    else
        if ! read_line; then
            printf '\n'
            ANS=$_at_def
            return 1
        fi
    fi

    if [ "$REPLY" = '' ]; then
        ANS=$_at_def
    else
        ANS=$REPLY
    fi
    return 0
}

# 密文回显时只展示首尾，避免 token 泄漏
_mask_hint() {
    _mh_val=$1; _mh_mask=$2
    if [ "$_mh_mask" != 1 ]; then
        printf '%s' "$_mh_val"
        return
    fi
    _mh_len=${#_mh_val}
    if [ "$_mh_len" -le 8 ]; then
        printf '******'
    else
        printf '%s****%s' "$(printf '%s' "$_mh_val" | cut -c1-4)" "$(printf '%s' "$_mh_val" | cut -c$((_mh_len - 3))-)"
    fi
}

_stty_echo_off() { [ "$HAVE_TTY" = 1 ] && stty -echo </dev/tty 2>/dev/null; :; }
_stty_echo_on()  { [ "$HAVE_TTY" = 1 ] && stty echo  </dev/tty 2>/dev/null; :; }

# ask_yesno <标签> [默认 y/n]  ->  ANS = y | n
ask_yesno() {
    _ay_label=$1
    _ay_def=${2:-n}
    if [ "$INTERACTIVE" != 1 ]; then
        ANS=$_ay_def
        return 0
    fi
    while :; do
        if [ "$_ay_def" = y ]; then
            ask_text "$_ay_label" 'y'
        else
            ask_text "$_ay_label" 'n'
        fi
        case "$ANS" in
            [Yy]|[Yy][Ee][Ss]) ANS=y; return 0 ;;
            [Nn]|[Nn][Oo])     ANS=n; return 0 ;;
            '')                ANS=$_ay_def; return 0 ;;
            *) warn "$T_YESNO_HINT" ;;
        esac
    done
}

# choose <标题> <默认序号> <选项1> <选项2> ...  ->  ANS = 选中序号(1..n)
choose() {
    _ch_title=$1; _ch_def=$2; shift 2
    if [ "$INTERACTIVE" != 1 ]; then
        ANS=$_ch_def
        return 0
    fi
    _ch_i=1
    printf '\n%s%s%s\n' "$c_bold" "$_ch_title" "$c_rst"
    for _ch_opt in "$@"; do
        if [ "$_ch_i" = "$_ch_def" ]; then
            printf '  %s%d)%s %s %s(%s)%s\n' "$c_cyn" "$_ch_i" "$c_rst" "$_ch_opt" "$c_dim" "$T_MENU_DEFAULT" "$c_rst"
        else
            printf '  %s%d)%s %s\n' "$c_cyn" "$_ch_i" "$c_rst" "$_ch_opt"
        fi
        _ch_i=$((_ch_i + 1))
    done
    _ch_max=$((_ch_i - 1))
    while :; do
        ask_text "$T_SELECT" "$_ch_def"
        case "$ANS" in
            ''|*[!0-9]*) : ;;
            *) if [ "$ANS" -ge 1 ] && [ "$ANS" -le "$_ch_max" ]; then
                   return 0
               fi ;;
        esac
        warn "$T_RANGE_A $_ch_max"
    done
}

confirm_or_die() {
    if [ "$ASSUME_YES" = 1 ]; then
        return 0
    fi
    if [ "$INTERACTIVE" != 1 ]; then
        warn "$T_NEED_YES"
        return 1
    fi
    ask_yesno "$1" 'y'
    if [ "$ANS" != y ]; then
        info "$T_CANCELLED"
        return 1
    fi
    return 0
}

#-------------------------------------------------------------------------------
# 6. 通用工具
#-------------------------------------------------------------------------------
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s %s\n' "$c_ylw" "$c_rst" "$*"
        return 0
    fi
    "$@"
}

run_sh() { # 执行一段 shell 片段（用于带重定向/管道的复杂命令）
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s %s\n' "$c_ylw" "$c_rst" "$*"
        return 0
    fi
    sh -c "$*"
}

have() { command -v "$1" >/dev/null 2>&1; }

# 需要 root：非 root 时尝试用 sudo 自我提权
require_root() {
    if [ "$(id -u)" = 0 ]; then
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        warn "$T_ROOT_DRYRUN"
        return 0
    fi
    if ! have sudo; then
        die "$T_ROOT_NEED"
    fi
    info "$T_ROOT_RERUN"
    case "$0" in
        */*) _rr_self=$0 ;;
        *)   _rr_self='' ;;
    esac
    if [ -n "$_rr_self" ] && [ -r "$_rr_self" ]; then
        exec sudo -E sh "$_rr_self" "$@"
    fi
    die "$T_ROOT_PIPE"
}

# --- HTTP ---
# 组装代理参数：curl 用 -x/--proxy-user；wget 只认环境变量且认证需内嵌在 URL 里
build_proxy_args() {
    CURL_PROXY_ARGS=''
    WGET_PROXY_ENV=''
    [ -n "$PROXY_URL" ] || return 0
    CURL_PROXY_ARGS="-x $PROXY_URL"
    if [ -n "$PROXY_AUTH" ]; then
        CURL_PROXY_ARGS="$CURL_PROXY_ARGS --proxy-user $PROXY_AUTH"
        case "$PROXY_URL" in
            *://*) WGET_PROXY_ENV="${PROXY_URL%%://*}://${PROXY_AUTH}@${PROXY_URL#*://}" ;;
            *)     WGET_PROXY_ENV="$PROXY_URL" ;;
        esac
    else
        WGET_PROXY_ENV="$PROXY_URL"
    fi
    return 0
}

# --resin 允许直接给完整前缀：
#   http://host:port[/<token>[/<Platform.Account>]]
# 这样用户可以把网关里看到的地址整段粘进来，不必再拆成三个参数。
parse_resin_url() {
    [ -n "$RESIN_URL" ] || return 0
    case "$RESIN_URL" in
        *://*) : ;;
        *) return 0 ;;
    esac
    _pr_scheme=${RESIN_URL%%://*}
    _pr_rest=${RESIN_URL#*://}
    _pr_hostport=${_pr_rest%%/*}
    _pr_path=${_pr_rest#"$_pr_hostport"}
    _pr_path=${_pr_path#/}
    RESIN_URL="${_pr_scheme}://${_pr_hostport}"
    [ -n "$_pr_path" ] || return 0
    _pr_tok=${_pr_path%%/*}
    _pr_tail=${_pr_path#"$_pr_tok"}
    _pr_tail=${_pr_tail#/}
    _pr_acct=${_pr_tail%%/*}
    [ -n "$RESIN_TOKEN" ] || RESIN_TOKEN=$_pr_tok
    [ -n "$RESIN_ACCOUNT" ] || RESIN_ACCOUNT=$_pr_acct
    [ -n "$_pr_acct" ] && [ "$_pr_acct" != "$_pr_tail" ] && \
        dim "$T_RESIN_TAIL_IGNORED"
    return 0
}

# 把普通 URL 包成 Resin 反向代理 URL：
#   http://host:port/<token>/[Platform.]Account/<proto>/<target-host><path>
resin_wrap() {
    _rw_u=$1
    case "$_rw_u" in
        http://*)  _rw_proto=http;  _rw_rest=${_rw_u#http://} ;;
        https://*) _rw_proto=https; _rw_rest=${_rw_u#https://} ;;
        *) printf '%s' "$_rw_u"; return 0 ;;
    esac
    case "$_rw_rest" in
        */*) _rw_host=${_rw_rest%%/*}; _rw_path="/${_rw_rest#*/}" ;;
        *)   _rw_host=$_rw_rest;       _rw_path='' ;;
    esac
    printf '%s/%s/%s/%s/%s%s' "${RESIN_URL%/}" "$RESIN_TOKEN" \
        "${RESIN_ACCOUNT:-.}" "$_rw_proto" "$_rw_host" "$_rw_path"
}

# Resin 反向代理下自己跟随重定向：curl -L 会把第二跳指向真实主机，从而绕过 Resin。
# resin_to_file <url> <out>
resin_to_file() {
    _rtf_url=$1; _rtf_out=$2
    _rtf_i=0
    _rtf_try=0
    RESIN_ERR=''
    while [ "$_rtf_i" -lt 6 ]; do
        _rtf_px=$(resin_wrap "$_rtf_url")
        # shellcheck disable=SC2086
        _rtf_res=$(curl $CURL_FAMILY $CURL_PROXY_ARGS -s -o "$_rtf_out" \
            -w '%{http_code} %{redirect_url}' --connect-timeout 15 "$_rtf_px" 2>/dev/null)
        _rtf_code=${_rtf_res%% *}
        _rtf_loc=${_rtf_res#* }
        case "$_rtf_code" in
            2*) return 0 ;;
            3*) [ -n "$_rtf_loc" ] || return 1
                _rtf_url=$_rtf_loc
                _rtf_i=$((_rtf_i + 1))
                _rtf_try=0 ;;
            5*|000)
                # 网关上游超时很常见（实测 502/504，5~12s），值一次重试
                if [ "$_rtf_try" -lt 2 ]; then
                    _rtf_try=$((_rtf_try + 1))
                    dim "$T_RESIN_RETRY $_rtf_try"
                    sleep 2
                    continue
                fi
                RESIN_ERR=$(head -c 200 "$_rtf_out" 2>/dev/null | tr -d '\r\n')
                [ -n "$RESIN_ERR" ] || RESIN_ERR="HTTP $_rtf_code"
                return 1 ;;
            *)  RESIN_ERR="HTTP $_rtf_code"
                return 1 ;;
        esac
    done
    return 1
}

# resin_to_stdout <url>
# 只发一次请求：body 落临时文件，状态码/重定向由 -w 取得，
# 避免为了探状态码而重复请求（GitHub 未认证 API 只有 60 次/小时）。
resin_to_stdout() {
    _rts_url=$1
    _rts_i=0
    _rts_tmp="${TMP_DIR:-/tmp}/resin.out.$$"
    while [ "$_rts_i" -lt 6 ]; do
        _rts_px=$(resin_wrap "$_rts_url")
        # shellcheck disable=SC2086
        _rts_res=$(curl $CURL_FAMILY $CURL_PROXY_ARGS -s -o "$_rts_tmp" \
            -w '%{http_code} %{redirect_url}' --connect-timeout 15 "$_rts_px" 2>/dev/null)
        _rts_code=${_rts_res%% *}
        _rts_loc=${_rts_res#* }
        case "$_rts_code" in
            2*)
                cat "$_rts_tmp" 2>/dev/null
                rm -f "$_rts_tmp" 2>/dev/null || :
                return 0 ;;
            3*) [ -n "$_rts_loc" ] || { rm -f "$_rts_tmp" 2>/dev/null || :; return 1; }
                _rts_url=$_rts_loc
                _rts_i=$((_rts_i + 1)) ;;
            *)  rm -f "$_rts_tmp" 2>/dev/null || :
                return 1 ;;
        esac
    done
    rm -f "$_rts_tmp" 2>/dev/null || :
    return 1
}

# curl 退出码 -> 可读原因（写进全局 HTTP_ERR）
curl_reason() {
    case "$1" in
        5)  printf '%s' "$T_E_PROXY_RESOLVE" ;;
        6)  printf '%s' "$T_E_RESOLVE" ;;
        7)  printf '%s' "$T_E_CONNECT" ;;
        22) printf '%s' "$T_E_HTTP" ;;
        23) printf '%s' "$T_E_WRITE" ;;
        18) printf '%s' "$T_E_TRUNCATED_SIMPLE" ;;
        28) printf '%s' "$T_E_TIMEOUT" ;;
        35|51|53|54|55|58|59|60|66|77|80|82|83|90|91) printf '%s' "$T_E_TLS" ;;
        56) printf '%s' "$T_E_RECV" ;;
        *)  printf '%s %s' "$T_E_OTHER" "$1" ;;
    esac
}

# wget 退出码 -> 可读原因
wget_reason() {
    case "$1" in
        3) printf '%s' "$T_E_WRITE" ;;
        4) printf '%s' "$T_E_CONNECT" ;;
        5) printf '%s' "$T_E_TLS" ;;
        6|8) printf '%s' "$T_E_HTTP" ;;
        *) printf '%s %s' "$T_E_OTHER" "$1" ;;
    esac
}

# 校验拿到的确实是可执行文件（ELF / Mach-O）。
# 门户页、透明代理、被拦截的下载常常返回 HTTP 200 + 一段 HTML，
# 若不校验，后面会以「二进制不支持某参数」这种完全误导的方式失败。
# 文件头 4 字节（十六进制），用于诊断
file_magic() {
    head -c 4 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'
}

# 静默判断是否为可执行文件（ELF / Mach-O）。
# 取不到魔数（head/od 不可用）时不阻塞流程，返回 0。
is_executable_file() {
    [ -s "$1" ] || return 1
    case "$(file_magic "$1")" in
        7f454c46*) return 0 ;;                                        # ELF
        cffaedfe*|cefaedfe*|cafebabe*|feedface*|feedfacf*) return 0 ;; # Mach-O / fat
        '') return 0 ;;
    esac
    return 1
}

verify_executable() {
    _ve_file=$1; _ve_label=${2:-binary}
    if [ ! -s "$_ve_file" ]; then
        err "$T_BIN_EMPTY $_ve_label"
        return 1
    fi
    # 体积异常偏小 → 下载很可能被截断（这两个二进制都是多 MB 级）
    _ve_sz=$(wc -c <"$_ve_file" 2>/dev/null | tr -d ' ')
    case "$_ve_sz" in ''|*[!0-9]*) _ve_sz=0 ;; esac
    if [ "$_ve_sz" -lt 1048576 ]; then
        warn "$T_BIN_SMALL $_ve_label $_ve_sz"
    fi
    if ! is_executable_file "$_ve_file"; then
        err "$T_BIN_NOT_EXEC $_ve_label"
        dim "$T_BIN_NOT_EXEC_MAGIC $(file_magic "$_ve_file")"
        dim "$T_BIN_NOT_EXEC_HINT"
        return 1
    fi
    return 0
}

# 下载前确认目标目录存在且可写：否则 curl 的写失败会被笼统报成「下载失败」，
# 把人引向网络排查方向。
dl_precheck_dir() {
    _dp_dir=$(dirname "$1")
    if [ ! -d "$_dp_dir" ]; then
        err "$T_DL_NODIR $_dp_dir"
        return 1
    fi
    if ! ( umask 077; : >"$_dp_dir/.dlwtest.$$" ) 2>/dev/null; then
        err "$T_DL_NOWRITE $_dp_dir"
        return 1
    fi
    rm -f "$_dp_dir/.dlwtest.$$" 2>/dev/null || :
    return 0
}

# http_to_file <url> <out> : 成功返回 0，失败时把原因写入全局 HTTP_ERR
http_to_file() {
    _hf_url=$1; _hf_out=$2
    HTTP_ERR=''
    if [ -n "$RESIN_URL" ] && [ "$HTTP_NO_RESIN" != 1 ]; then
        if ! resin_to_file "$_hf_url" "$_hf_out"; then
            if [ -n "$RESIN_ERR" ]; then
                HTTP_ERR="$T_E_RESIN ($RESIN_ERR)"
            else
                HTTP_ERR="$T_E_RESIN"
            fi
            return 1
        fi
        return 0
    fi
    if have curl; then
        _hf_hdr="${TMP_DIR:-/tmp}/.cjhdr.$$"
        # shellcheck disable=SC2086
        curl $CURL_FAMILY $CURL_PROXY_ARGS -fL --connect-timeout 15 --retry 2 \
            -D "$_hf_hdr" -o "$_hf_out" "$_hf_url" >/dev/null 2>&1
        _hf_rc=$?
        if [ "$_hf_rc" = 0 ]; then
            # 截断检测：服务端声明的 Content-Length 与实际落盘大小不符时，
            # curl 仍可能返回 0（连接被中途"正常"关闭）。截断的 ELF 仍带合法魔数，
            # 只靠魔数无法发现，必须比对长度。
            _hf_want=$(grep -i '^content-length:' "$_hf_hdr" 2>/dev/null | tail -n1 | tr -d '\r' | awk '{print $2}')
            _hf_got=$(wc -c <"$_hf_out" 2>/dev/null | tr -d ' ')
            case "$_hf_want" in ''|*[!0-9]*) : ;; *)
                case "$_hf_got" in ''|*[!0-9]*) : ;; *)
                    if [ "$_hf_want" != "$_hf_got" ]; then
                        HTTP_ERR="$T_E_TRUNCATED $_hf_got/$_hf_want"
                        rm -f "$_hf_hdr" 2>/dev/null || :
                        return 1
                    fi ;;
                esac ;;
            esac
        else
            HTTP_ERR=$(curl_reason "$_hf_rc")
        fi
        rm -f "$_hf_hdr" 2>/dev/null || :
        return $_hf_rc
    elif have wget; then
        # shellcheck disable=SC2086
        http_proxy="$WGET_PROXY_ENV" https_proxy="$WGET_PROXY_ENV" \
            wget $CURL_FAMILY -q -T 20 -O "$_hf_out" "$_hf_url" >/dev/null 2>&1
        _hf_rc=$?
        [ "$_hf_rc" = 0 ] || HTTP_ERR=$(wget_reason "$_hf_rc")
        return $_hf_rc
    else
        HTTP_ERR="$T_E_OTHER 127"
        return 127
    fi
}

# http_to_stdout <url>
http_to_stdout() {
    _hs_url=$1
    if [ -n "$RESIN_URL" ]; then
        resin_to_stdout "$_hs_url"
        return $?
    fi
    if have curl; then
        # shellcheck disable=SC2086
        curl $CURL_FAMILY $CURL_PROXY_ARGS -fsSL --connect-timeout 15 "$_hs_url" 2>/dev/null
    elif have wget; then
        # shellcheck disable=SC2086
        http_proxy="$WGET_PROXY_ENV" https_proxy="$WGET_PROXY_ENV" \
            wget $CURL_FAMILY -q -O - -T 20 "$_hs_url" 2>/dev/null
    else
        return 127
    fi
}

# 生成带镜像的候选 URL 列表（GitHub 加速）
url_candidates() {
    printf '%s\n' "$1"
    if [ "$NO_GH_PROXY" = 1 ]; then
        return 0
    fi
    if [ -n "$GH_PROXY" ]; then
        printf '%s\n' "${GH_PROXY%/}/$1"
    fi
    for _uc_m in $GH_MIRRORS_ACTIVE; do
        if [ -n "$GH_PROXY" ] && [ "${_uc_m%/}" = "${GH_PROXY%/}" ]; then
            continue
        fi
        printf '%s\n' "${_uc_m%/}/$1"
    done
}

# dl <url> <out> [标签]
# 下载失败时给出针对性提示，而不是笼统的「网络不行」
dl_hint() {
    if [ -n "$RESIN_URL" ]; then
        dim "$T_DL_HINT_RESIN $RESIN_URL"
    fi
    if [ -n "$PROXY_URL" ]; then
        dim "$T_DL_HINT_PROXY $PROXY_URL"
    fi
    _dh_env=''
    for _dh_v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
        eval "_dh_cur=\${$_dh_v:-}"
        [ -n "$_dh_cur" ] && _dh_env="$_dh_env $_dh_v=$_dh_cur"
    done
    if [ -n "$_dh_env" ]; then
        dim "$T_DL_HINT_ENVPROXY$_dh_env"
    fi
    if [ "$NO_GH_PROXY" = 1 ]; then
        dim "$T_DL_HINT_NOMIRROR"
    fi
    dim "$T_DL_HINT_GENERIC"
}

# dl <url> <out> <label> [expect]
#   expect=binary 时逐个候选校验文件内容：门户页/透明代理会返回 HTTP 200 + HTML，
#   此时应当换下一个源（镜像往往没被拦截），而不是直接放弃。
dl() {
    _dl_url=$1; _dl_out=$2; _dl_label=${3:-file}; _dl_expect=${4:-}
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s download %s -> %s\n' "$c_ylw" "$c_rst" "$_dl_url" "$_dl_out"
        return 0
    fi
    dl_precheck_dir "$_dl_out" || return 1
    _dl_ok=0
    _dl_reasons=''
    _dl_badcontent=0
    # 第一轮经 Resin（若配置）；全部失败后第二轮退回直连/镜像——
    # 网关上游不通时不该让整台机器装不上；内容校验会挡住被劫持的响应。
    for _dl_pass in 1 2; do
        if [ "$_dl_pass" = 1 ]; then
            [ -n "$RESIN_URL" ] || continue
            HTTP_NO_RESIN=0
        else
            HTTP_NO_RESIN=1
            [ -n "$RESIN_URL" ] && dim "$T_DL_FALLBACK_DIRECT"
        fi
        for _dl_u in $(url_candidates "$_dl_url"); do
            dim "$_dl_u"
            rm -f "$_dl_out" 2>/dev/null || :
            if http_to_file "$_dl_u" "$_dl_out" && [ -s "$_dl_out" ]; then
                if [ "$_dl_expect" = binary ] && ! is_executable_file "$_dl_out"; then
                    _dl_badcontent=1
                    warn "$T_DL_BAD_CONTENT $_dl_u ($(wc -c <"$_dl_out" 2>/dev/null | tr -d ' ') $T_DL_BYTES $(file_magic "$_dl_out"))"
                    rm -f "$_dl_out" 2>/dev/null || :
                    continue
                fi
                _dl_ok=1
                break
            fi
            if [ -n "$HTTP_ERR" ]; then
                if [ -n "$_dl_reasons" ]; then
                    _dl_reasons="$_dl_reasons
  - $HTTP_ERR"
                else
                    _dl_reasons="  - $HTTP_ERR"
                fi
            fi
            rm -f "$_dl_out" 2>/dev/null || :
        done
        [ "$_dl_ok" = 1 ] && break
    done
    HTTP_NO_RESIN=0
    if [ "$_dl_ok" != 1 ]; then
        err "$_dl_label: $T_DL_FAILED"
        if [ "$_dl_badcontent" = 1 ]; then
            warn "$T_DL_ALL_BAD_CONTENT"
        fi
        if [ -n "$_dl_reasons" ]; then
            dim "$T_DL_REASONS"
            printf '%s\n' "$_dl_reasons"
        fi
        dl_hint
        return 1
    fi
    return 0
}

# 返回 <path> 所在文件系统的可用空间（KB）；取不到返回空
free_space_kb() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# 只解压指定条目（pattern 形如 */easytier-core），避免整包展开占满小磁盘
# 优先 unzip，其次 python3，最后 busybox
unzip_entries() {
    _ue_zip=$1; _ue_dir=$2; shift 2
    [ $# -gt 0 ] || return 1
    mkdir -p "$_ue_dir" 2>/dev/null || :
    if have unzip; then
        unzip -o -q "$_ue_zip" "$@" -d "$_ue_dir"
    elif have python3; then
        python3 -c '
import sys, zipfile, os
zf = zipfile.ZipFile(sys.argv[1]); dst = sys.argv[2]
want = [os.path.basename(p) for p in sys.argv[3:]]
for m in zf.namelist():
    if m.endswith("/"):
        continue
    if os.path.basename(m) in want:
        zf.extract(m, dst)
' "$_ue_zip" "$_ue_dir" "$@"
    elif have busybox; then
        busybox unzip -o -q "$_ue_zip" "$@" -d "$_ue_dir"
    else
        return 127
    fi
}

# 解压 zip（优先 unzip，其次 python3，最后 busybox）
unzip_file() {
    _uz_zip=$1; _uz_dir=$2
    if have unzip; then
        unzip -o -q "$_uz_zip" -d "$_uz_dir"
    elif have python3; then
        python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$_uz_zip" "$_uz_dir"
    elif have busybox; then
        busybox unzip -o -q "$_uz_zip" -d "$_uz_dir"
    else
        return 127
    fi
}

# 自动安装 unzip
ensure_unzip() {
    if have unzip || have python3 || have busybox; then
        return 0
    fi
    warn "$T_UNZIP_TRY"
    if have apk; then run apk add --no-cache unzip
    elif have apt-get; then run apt-get update && run apt-get install -y unzip
    elif have apt; then run apt update && run apt install -y unzip
    elif have dnf; then run dnf install -y unzip
    elif have yum; then run yum install -y unzip
    elif have pacman; then run pacman -Sy --noconfirm unzip
    elif have opkg; then run opkg update && run opkg install unzip
    elif have brew; then run brew install unzip
    else
        err "$T_NO_UNZIP"
        return 1
    fi
    have unzip || have python3 || have busybox
}

# 确保存在下载工具。
# 精简镜像（Debian minimal、部分 OpenVZ/LXC 模板）常常 curl 和 wget 一个都没有，
# 此时不能直接退出，应当像 unzip 那样先尝试自动补装。
ensure_downloader() {
    if [ "$NO_DOWNLOAD" = 1 ]; then
        return 0
    fi
    if have curl || have wget; then
        return 0
    fi
    warn "$T_DL_INSTALLING"
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s install curl via the system package manager\n' "$c_ylw" "$c_rst"
        return 0
    fi
    if have apt-get; then
        apt-get install -y curl >/dev/null 2>&1 || :
        if ! have curl; then
            apt-get update -qq >/dev/null 2>&1 || :
            apt-get install -y curl >/dev/null 2>&1 || :
        fi
    elif have apt; then
        apt install -y curl >/dev/null 2>&1 || :
        if ! have curl; then
            apt update -qq >/dev/null 2>&1 || :
            apt install -y curl >/dev/null 2>&1 || :
        fi
    elif have dnf; then dnf install -y curl >/dev/null 2>&1 || :
    elif have yum; then yum install -y curl >/dev/null 2>&1 || :
    elif have zypper; then zypper --non-interactive install curl >/dev/null 2>&1 || :
    elif have pacman; then pacman -Sy --noconfirm curl >/dev/null 2>&1 || :
    elif have apk; then apk add --no-cache curl >/dev/null 2>&1 || :
    elif have opkg; then opkg update >/dev/null 2>&1 || :; opkg install curl >/dev/null 2>&1 || :
    elif have brew; then brew install curl >/dev/null 2>&1 || :
    else
        return 1
    fi
    if have curl; then
        ok "$T_DL_INSTALLED curl"
        return 0
    fi
    if have wget; then
        ok "$T_DL_INSTALLED wget"
        return 0
    fi
    return 1
}

detect_os_arch() {
    OS_NAME=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
    ARCH_RAW=$(uname -m 2>/dev/null)
    case "$OS_NAME" in
        linux|darwin|freebsd) : ;;
        *) warn "$T_OS_UNSUPPORTED $OS_NAME" ;;
    esac
}

komari_arch() {
    case "$ARCH_RAW" in
        x86_64|amd64)          echo amd64 ;;
        aarch64|arm64)         echo arm64 ;;
        armv7l|armv7|armv6l)   echo arm ;;
        i386|i486|i586|i686)   echo 386 ;;
        loongarch64|loong64)   echo loong64 ;;
        *) return 1 ;;
    esac
}

et_arch_candidates() {
    case "$ARCH_RAW" in
        x86_64|amd64)          echo 'x86_64' ;;
        aarch64|arm64)         echo 'aarch64' ;;
        armv7l|armv7)          echo 'armv7hf armv7 arm' ;;
        armv6l|armv6)          echo 'armhf arm' ;;
        riscv64)               echo 'riscv64' ;;
        loongarch64|loong64)   echo 'loongarch64' ;;
        mips64)                echo 'mips' ;;
        mips)                  echo 'mips' ;;
        mipsel)                echo 'mipsel' ;;
        *) return 1 ;;
    esac
}

# 解析 EasyTier 最新版本号（GitHub API -> 重定向）
et_latest_version() {
    _ev_ver=''
    _ev_api="https://api.github.com/repos/$GH_EASYTIER_REPO/releases/latest"
    for _ev_u in $(url_candidates "$_ev_api"); do
        _ev_json=$(http_to_stdout "$_ev_u" || :)
        if [ -n "$_ev_json" ]; then
            _ev_ver=$(printf '%s' "$_ev_json" \
                | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
                | head -n 1 \
                | sed 's/.*"\([^"]*\)".*/\1/')
            [ -n "$_ev_ver" ] && break
        fi
    done
    if [ -z "$_ev_ver" ] && have curl; then
        _ev_ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "https://github.com/$GH_EASYTIER_REPO/releases/latest" 2>/dev/null \
            | sed 's#.*/tag/##')
        case "$_ev_ver" in v[0-9]*) : ;; *) _ev_ver='' ;; esac
    fi
    printf '%s' "$_ev_ver"
}

# 解析任意 GitHub 仓库的最新 release tag
github_latest_tag() {
    _gl_repo=$1
    _gl_ver=''
    for _gl_u in $(url_candidates "https://api.github.com/repos/$_gl_repo/releases/latest"); do
        _gl_json=$(http_to_stdout "$_gl_u" || :)
        [ -n "$_gl_json" ] || continue
        _gl_ver=$(printf '%s' "$_gl_json" \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -n 1 | sed 's/.*"\([^"]*\)".*/\1/')
        [ -n "$_gl_ver" ] && break
    done
    [ -n "$_gl_ver" ] || return 1
    printf '%s' "$_gl_ver"
}

# 探测本机网络族：输出 46 / 4 / 6 / 空
net_family_detect() {
    _nf_v4=0; _nf_v6=0
    if have ip; then
        ip -o -4 addr show scope global 2>/dev/null | grep -q . && _nf_v4=1
        ip -o -6 addr show scope global 2>/dev/null | grep -q . && _nf_v6=1
    elif have ifconfig; then
        ifconfig 2>/dev/null | grep -q 'inet ' && _nf_v4=1
        # 只认全局 IPv6：fe80::/10 是 link-local，几乎每台机器都有，不能当连通性
        if ifconfig 2>/dev/null | grep 'inet6' | grep -v 'fe80' | grep -vq '::1/'; then
            _nf_v6=1
        fi
    fi
    # 拿不到接口信息时用连通性兜底。
    # 必须 --noproxy：否则 -6 探测会被 IPv4-only 的 HTTP 代理"成功"返回，
    # 从而把只走代理的机器误判成有原生 IPv6。
    if [ "$_nf_v4" = 0 ] && [ "$_nf_v6" = 0 ] && have curl; then
        curl -4 --noproxy '*' -s -o /dev/null --connect-timeout 5 http://1.1.1.1 2>/dev/null && _nf_v4=1
        curl -6 --noproxy '*' -s -o /dev/null --connect-timeout 5 "http://[2606:4700:4700::1111]" 2>/dev/null && _nf_v6=1
    fi
    if [ "$_nf_v4" = 1 ] && [ "$_nf_v6" = 1 ]; then printf '46'
    elif [ "$_nf_v4" = 1 ]; then printf '4'
    elif [ "$_nf_v6" = 1 ]; then printf '6'
    fi
}

# 应用地址族；IPv6 纯机时过滤掉不可达的镜像
apply_ip_family() {
    case "$IP_FAMILY" in
        4) CURL_FAMILY='-4'; NET_IPV6_ONLY=0 ;;
        6) CURL_FAMILY='-6'; NET_IPV6_ONLY=1 ;;
        auto|'')
            case "$(net_family_detect)" in
                6) CURL_FAMILY='-6'; NET_IPV6_ONLY=1 ;;
                *) CURL_FAMILY=''; NET_IPV6_ONLY=0 ;;
            esac
            ;;
        *) die "$T_IP_FAMILY_BAD $IP_FAMILY" ;;
    esac

    if [ -n "$RESIN_URL" ] && [ -z "$RESIN_TOKEN" ]; then
        die "$T_RESIN_NEED_TOKEN"
    fi
    if [ -n "$PROXY_URL" ]; then
        dim "$T_PROXY_USING $PROXY_URL"
    fi
    if [ -n "$RESIN_URL" ]; then
        dim "$T_RESIN_USING $RESIN_URL"
        dim "$T_RESIN_REDIRECT_NOTE"
    fi

    if [ "$NET_IPV6_ONLY" = 1 ]; then
        warn "$T_NET_IPV6_ONLY"
        dim "$T_NET_V6_NO_GITHUB"
        # 只有实测可达的镜像才留下：纯 v6 机器上 IPv4-only 的镜像纯属浪费时间
        if [ "$DRY_RUN" = 1 ]; then
            dim "$T_NET_V6_PROBE_SKIP"
        else
            _af_ok=''
            for _af_m in $GH_MIRRORS_DEFAULT; do
                if curl -6 --noproxy '*' -sIL -o /dev/null --connect-timeout 8 "${_af_m%/}/" 2>/dev/null; then
                    _af_ok="$_af_ok $_af_m"
                fi
            done
            GH_MIRRORS_ACTIVE="$_af_ok"
            if [ -n "$_af_ok" ]; then
                dim "$T_NET_V6_MIRRORS$_af_ok"
            else
                warn "$T_NET_V6_NO_MIRROR"
            fi
        fi
        dim "$T_NET_V6_HINT"
        # agent 侧也优先走 IPv6 连面板
        if [ -z "$KOMARI_PREFER_IP" ]; then
            KOMARI_PREFER_IP=6
            dim "$T_NET_V6_PREFER"
        fi
    fi
    return 0
}

detect_init() {
    if have systemctl && [ -d /run/systemd/system ]; then
        SERVICE_MODE='systemd'; return 0
    fi
    if [ -f /etc/alpine-release ] && have rc-service; then
        SERVICE_MODE='openrc'; return 0
    fi
    if have rc-service && [ -d /etc/init.d ]; then
        SERVICE_MODE='openrc'; return 0
    fi
    if [ -f /etc/rc.common ] && have uci; then
        SERVICE_MODE='procd'; return 0
    fi
    SERVICE_MODE='manual'; return 1
}

# 本地主 IP（用于默认 web 控制台地址）
local_ip() {
    _li_ip=''
    if have ip; then
        _li_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
    fi
    if [ -z "$_li_ip" ] && have hostname; then
        _li_ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -n1)
    fi
    [ -z "$_li_ip" ] && _li_ip=$(uname -n 2>/dev/null)
    printf '%s' "$_li_ip"
}

#-------------------------------------------------------------------------------
# 7. 帮助
#-------------------------------------------------------------------------------
usage() {
    if [ "$MSG_LANG" = zh ]; then
        usage_zh
    else
        usage_en
    fi
}

usage_en() {
    cat <<EOF
$APP_NAME v$APP_VERSION -- Server cluster join (Komari Agent + EasyTier)

Usage:
  sh $APP_NAME.sh [action] [options]

Actions:
  (none)               Interactive menu on a TTY; error out without a TTY
  --menu               Force the interactive menu
  --all                All-in-one: EasyTier networking + Komari Agent
  --komari-only        Install / update Komari Agent only
  --easytier-only      Install / configure EasyTier only
  --web-only           Deploy the EasyTier Web Console (server / web-managed) only
  --fetch              Install a system info tool (fastfetch, falling back to neofetch)
  --status             Show runtime status
  --uninstall          Uninstall (Komari + EasyTier by default)
  --emit-cmd           Print the canonical command for other nodes; change nothing
  -h, --help           Show this help

General:
  -y, --yes            Unattended: every prompt uses its default
      --dry-run        Print what would be done without touching the system
      --lang zh|en     Force the message language (default: TTY=English,
                       non-TTY=follows the system locale)
      --gh-proxy URL   Use this GitHub acceleration prefix (e.g. https://ghfast.top/)
      --no-gh-proxy    Do not use any GitHub mirror
      --install-ghproxy URL    Same as --gh-proxy (official installer naming)
      --install-no-mirror      Same as --no-gh-proxy
      --install-dir DIR        Install directory for the Komari agent (default /opt/komari)
      --install-service-name N Service name for the Komari agent (default komari-agent)
      --with-fetch             Also install fastfetch/neofetch after a successful join
      --fetch-tool TOOL        auto (default) | fastfetch | neofetch
      --ip-family FAMILY       auto (default) | 4 | 6 -- force the host IP family
      --alt-screen / --no-alt-screen
                               Take over the screen like vim (default: on for an
                               interactive terminal). The final summary is printed
                               after leaving it so it stays in the scrollback.
      --no-download            Never download; require pre-placed binaries
                               (for IPv6-only / air-gapped hosts)
      --proxy URL              HTTP/SOCKS5 forward proxy, e.g. http://127.0.0.1:2260
      --proxy-auth USER:PASS   Proxy credentials (Resin: Platform.Account:TOKEN)
      --resin URL              Resin reverse-proxy base, e.g. http://127.0.0.1:2260
      --resin-token TOKEN      Resin reverse-proxy token (the <token> path segment)
      --resin-account ID       Resin [Platform.]Account for sticky sessions (optional)
      --fetch-motd             Install the login hook (default: on)
      --no-fetch-motd          Skip the login hook; install the binary only
      --fetch-shellrc          Also hook interactive shells (covers new GNOME
                               Terminal windows, which are not login sessions);
                               implies --no-fetch-motd unless given explicitly
      --no-fetch-shellrc       Do not touch shell rc files (default)
      --no-color       Disable colored output (NO_COLOR=1 works too)
      --log FILE       Also append to this log file (default $LOG_FILE)
      --reset-conf     Ignore and delete the saved configuration

Komari Agent:
  -e, --komari-endpoint URL   Panel URL, e.g. https://komari.example.com
      --komari-ad-key KEY     Auto-discovery key (RECOMMENDED). Used ONCE during install:
                              the agent registers, the returned node token is written to
                              agent.json next to the binary (mode 600), and the AD Key
                              itself is never persisted.
  -t, --komari-token TOKEN    Per-node agent token, for when an AD Key is not available
      --komari-interval SEC   Report interval in seconds (default: 1)
      --komari-version VER    latest (default) | snapshot | a release tag such as 1.5.11
      --komari-force-register Re-register with the panel even if a local token already exists
      --komari-prefer-ip-version 4|6   Prefer this IP family when connecting to the panel
      --komari-info-interval MIN   Basic info report interval in minutes
      --komari-no-web-ssh     Disable remote control (Web SSH / RCE)
      --komari-insecure       Ignore panel certificate errors (self-signed)
      --komari-no-autoupdate  Disable agent auto-update
      --komari-extra 'ARGS'   Extra raw arguments passed to komari-agent

EasyTier:
      --et-mode MODE          web | peer | server | off (default: web)
                              off = do NOT join the mesh (skip EasyTier entirely)
      --et-config-server URL  Web console config server, two forms:
                              username only  admin              (public console)
                              full URL       udp://1.2.3.4:22020/admin (self-hosted)
      --et-machine-id ID      Fixed machine id (keeps the node identity across reinstalls)
      --et-network-name NAME  Virtual network name (peer mode)
      --et-network-secret SEC Virtual network secret (peer mode)
      --et-peers 'URL...'     Peers / shared nodes, space separated
      --et-ip IPV4            Virtual IP of this node, e.g. 10.126.126.3
      --et-no-dhcp            Disable DHCP virtual IP assignment
      --et-hostname NAME      Hostname inside the virtual network
      --et-version VER        Pin a version, e.g. v2.6.4 (default: latest)
      --et-extra 'ARGS'       Extra raw arguments passed to easytier-core
      --no-easytier           Same as --et-mode off: skip EasyTier entirely

EasyTier Web Console (server):
      --web-deploy MODE       binary | docker | none (default: binary)
      --web-port PORT         Web UI/API port (default 11211)
      --web-cfg-port PORT     Config push port (default 22020)
      --web-cfg-proto PROTO   Config push protocol udp|tcp|ws (default udp)
      --web-api-host URL      API host used by the frontend (default http://<ip>:<port>)

Uninstall:
      --uninstall-target T    all | komari | easytier | web (default all)
      --purge                 Also delete configuration / data directories

Environment variables (uppercase of the long options, '-' becomes '_'):
  KOMARI_ENDPOINT KOMARI_TOKEN KOMARI_AD_KEY ET_MODE ET_CONFIG_SERVER
  ET_NETWORK_NAME ET_NETWORK_SECRET ET_PEERS ET_IPV4 ET_MACHINE_ID
  GH_PROXY CLUSTER_JOIN_CONF=/path/cluster.env
  CLUSTER_JOIN_YES=1                same as --yes
  CLUSTER_JOIN_NO_TTY=1             force non-interactive
  CLUSTER_JOIN_FORCE_INTERACTIVE=1  read answers from stdin when there is no TTY
  CLUSTER_JOIN_LANG=zh|en           force the message language

Saved configuration: $CONF_FILE (mode 600), loaded automatically; command line
and environment variables take precedence. Use --reset-conf to discard it.
Secrets (AD Key / agent token) are deliberately NOT stored there: the node token
lives in agent.json next to the agent binary (mode 600) and the service unit only
references it via --config.

Examples:
  # 1) Interactive (recommended the first time)
  sudo sh $APP_NAME.sh

  # 2) One node, EasyTier via a self-hosted web console + Komari panel
  sudo sh $APP_NAME.sh --all --yes \\
      --komari-endpoint https://komari.example.com --komari-ad-key AD-XXXX \\
      --et-config-server udp://10.0.0.1:22020/admin

  # 3) No web console: shared-node / P2P networking
  sudo sh $APP_NAME.sh --all --yes \\
      --komari-endpoint https://komari.example.com --komari-ad-key AD-XXXX \\
      --et-mode peer --et-network-name mynet --et-network-secret s3cret \\
      --et-peers 'tcp://1.2.3.4:11010'

  # 4) Batch deployment (with cluster-batch.sh)
  curl -fsSL <script-url> | sudo sh -s -- --yes --komari-ad-key KEY \\
      --et-config-server udp://10.0.0.1:22020/admin

EOF
}

usage_zh() {
    cat <<EOF
$APP_NAME v$APP_VERSION —— 服务器集群并网（Komari Agent + EasyTier 组网）

用法:
  sh $APP_NAME.sh [动作] [选项]

动作:
  (无)                 有终端时进入交互菜单；无终端时报错退出
  --menu               强制进入交互菜单
  --all                一键并网：EasyTier 组网 + Komari Agent
  --komari-only        只安装/更新 Komari Agent
  --easytier-only      只安装/配置 EasyTier
  --web-only           只部署 EasyTier Web 控制台（服务端 / web 托管）
  --fetch              安装系统信息工具（fastfetch，失败回退 neofetch）
  --status             查看运行状态
  --uninstall          卸载（默认 Komari + EasyTier）
  --emit-cmd           只打印可下发到其它节点的标准命令，不做任何改动
  -h, --help           显示本帮助

通用选项:
  -y, --yes            无人值守：所有提问使用默认值（非交互必需）
      --dry-run        只打印将要执行的操作，不真正修改系统
      --lang zh|en     强制指定消息语言（默认：TTY 用英文，
                       非 TTY 跟随系统 locale）
      --gh-proxy URL   指定 GitHub 加速前缀，例如 https://ghfast.top/
      --no-gh-proxy    不使用任何 GitHub 加速镜像
      --install-ghproxy URL    等同于 --gh-proxy（官方安装脚本命名）
      --install-no-mirror      等同于 --no-gh-proxy
      --install-dir DIR        Komari Agent 安装目录（默认 /opt/komari）
      --install-service-name N Komari Agent 服务名（默认 komari-agent）
      --with-fetch             并网成功后追加安装 fastfetch/neofetch
      --fetch-tool TOOL        auto（默认）| fastfetch | neofetch
      --ip-family FAMILY       auto（默认）| 4 | 6，强制本机地址族
      --alt-screen / --no-alt-screen
                               像 vim 一样接管整屏（交互终端下默认开启）。
                               汇总会在退出备用屏之后再打印，因此会留在 scrollback 里。
      --no-download            完全不下载，只使用预置二进制
                               （供纯 IPv6 / 离线环境使用）
      --proxy URL              HTTP/SOCKS5 正向代理，如 http://127.0.0.1:2260
      --proxy-auth USER:PASS   代理认证（Resin 为 Platform.Account:TOKEN）
      --resin URL              Resin 反向代理入口，如 http://127.0.0.1:2260
      --resin-token TOKEN      Resin 反向代理 token（URL 里的 <token> 段）
      --resin-account ID       Resin [Platform.]Account，用于粘性会话（可选）
      --fetch-motd             安装登录钩子（默认开启）
      --no-fetch-motd          不装登录钩子，只装二进制
      --fetch-shellrc          同时接入交互式 shell（覆盖 GNOME 终端新窗口——
                               它不是登录会话）；除非显式给 --fetch-motd，
                               否则会自动关掉登录钩子以避免重复显示
      --no-fetch-shellrc       不改动 shell rc（默认）
      --no-color       关闭彩色输出（NO_COLOR=1 同理）
      --log FILE       同时写入日志文件（默认 $LOG_FILE）
      --reset-conf     忽略并删除已保存的配置

Komari Agent:
  -e, --komari-endpoint URL   面板地址，例如 https://komari.example.com
      --komari-ad-key KEY     自动发现密钥（推荐）。安装时只使用一次完成注册，
                              面板返回的节点令牌写入 agent.json（权限 600），
                              AD Key 本身不落盘、不进服务单元。
  -t, --komari-token TOKEN    单节点 Agent Token（拿不到 AD Key 时使用）
      --komari-interval SEC   上报间隔秒数（默认 1）
      --komari-version VER     latest（默认）| snapshot | 具体标签，如 1.5.11
      --komari-force-register 即使本机已有令牌也强制重新注册
      --komari-prefer-ip-version 4|6   连接面板时优先使用的地址族
      --komari-info-interval MIN  基础信息上报间隔分钟
      --komari-no-web-ssh     禁用远程控制（Web SSH / RCE）
      --komari-insecure       忽略面板证书错误（自签证书场景）
      --komari-no-autoupdate  禁用 Agent 自动更新
      --komari-extra 'ARGS'   追加透传给 komari-agent 的原始参数

EasyTier 组网:
      --et-mode MODE          web | peer | server | off（默认 web）
                              off = 不启用并网（完全跳过 EasyTier）
      --et-config-server URL  Web 控制台配置下发地址，两种写法：
                              仅用户名         admin            （官方控制台）
                              完整地址         udp://1.2.3.4:22020/admin（自建控制台）
      --et-machine-id ID      固定机器标识（重装/迁移后保持同一个节点身份）
      --et-network-name NAME  虚拟网络名（peer 模式）
      --et-network-secret SEC 虚拟网络密码（peer 模式）
      --et-peers 'URL...'     对端/共享节点，空格分隔
      --et-ip IPV4            本节点虚拟 IP，如 10.126.126.3
      --et-no-dhcp            关闭 DHCP 自动分配虚拟 IP
      --et-hostname NAME      虚拟网络中的主机名
      --et-version VER        指定版本，如 v2.6.4（默认最新）
      --et-extra 'ARGS'       追加透传给 easytier-core 的原始参数
      --no-easytier           等同于 --et-mode off：完全跳过 EasyTier

EasyTier Web 控制台（服务端）:
      --web-deploy MODE       binary | docker | none（默认 binary）
      --web-port PORT         Web 前后端端口（默认 11211）
      --web-cfg-port PORT     配置下发端口（默认 22020）
      --web-cfg-proto PROTO   配置下发协议 udp|tcp|ws（默认 udp）
      --web-api-host URL      前端访问后端的地址，默认 http://<本机IP>:<web-port>

卸载相关:
      --uninstall-target T    all | komari | easytier | web（默认 all）
      --purge                 连同配置/数据目录一起删除

环境变量（与上面长选项同名大写，下划线连接，可混合使用）:
  KOMARI_ENDPOINT KOMARI_TOKEN KOMARI_AD_KEY ET_MODE ET_CONFIG_SERVER
  ET_NETWORK_NAME ET_NETWORK_SECRET ET_PEERS ET_IPV4 ET_MACHINE_ID
  GH_PROXY CLUSTER_JOIN_CONF=/path/cluster.env
  CLUSTER_JOIN_YES=1              等价于 --yes
  CLUSTER_JOIN_NO_TTY=1           强制非交互
  CLUSTER_JOIN_FORCE_INTERACTIVE=1  无终端时改为从标准输入读取答案
  CLUSTER_JOIN_LANG=zh|en         强制指定消息语言

参数存档: $CONF_FILE（权限 600），运行时会自动读取，
          命令行参数与环境变量优先级更高；用 --reset-conf 可忽略并删除。
          密钥（AD Key / 节点令牌）故意不写入存档：节点令牌保存在 agent 二进制
          同目录的 agent.json（权限 600），服务单元只通过 --config 引用它。

示例:
  # 1) 交互式（推荐首次使用）
  sudo sh $APP_NAME.sh

  # 2) 单台并网：EasyTier 走自建 Web 控制台 + Komari 面板
  sudo sh $APP_NAME.sh --all --yes \\
      --komari-endpoint https://komari.example.com --komari-ad-key AD-XXXX \\
      --et-config-server udp://10.0.0.1:22020/admin

  # 3) 无公网控制台：共享节点直连组网
  sudo sh $APP_NAME.sh --all --yes \\
      --komari-endpoint https://komari.example.com --komari-ad-key AD-XXXX \\
      --et-mode peer --et-network-name mynet --et-network-secret s3cret \\
      --et-peers 'tcp://1.2.3.4:11010'

  # 4) 批量下发（配合 cluster-batch.sh）
  curl -fsSL <脚本地址> | sudo sh -s -- --yes --komari-ad-key KEY \\
      --et-config-server udp://10.0.0.1:22020/admin

EOF
}

#-------------------------------------------------------------------------------
# 8. 参数解析
#-------------------------------------------------------------------------------
need_val() { # need_val <选项名> <值>
    if [ -z "${2:-}" ]; then
        die "$T_NEED_VALUE $1"
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        _pa_a=$1
        case "$_pa_a" in
            -h|--help)            ACTION='help' ;;
            --menu)               ACTION='menu' ;;
            --all|--install)      ACTION='all' ;;
            --komari-only|--komari) ACTION='komari' ;;
            --easytier-only|--easytier) ACTION='easytier' ;;
            --web-only|--web)     ACTION='web' ;;
            --status)             ACTION='status' ;;
            --uninstall)          ACTION='uninstall' ;;
            --emit-cmd|--print-cmd) ACTION='emit' ;;

            -y|--yes|-f|--force)  ASSUME_YES=1 ;;
            --dry-run|--dry)      DRY_RUN=1 ;;
            --no-color)           USE_COLOR=0; setup_colors ;;
            --no-gh-proxy)        NO_GH_PROXY=1 ;;
            --reset-conf)         RESET_CONF=1 ;;
            --no-komari)          NO_KOMARI=1 ;;
            --no-easytier|--no-et) NO_ET=1 ;;
            --purge)              UNINSTALL_PURGE=1 ;;
            --fetch)              ACTION='fetch' ;;
            --with-fetch)         WITH_FETCH=1 ;;
            --fetch-tool)         need_val "$_pa_a" "${2:-}"; FETCH_TOOL=$2; shift ;;
            --fetch-tool=*)       FETCH_TOOL=${_pa_a#*=} ;;
            --fetch-motd)         FETCH_MOTD=1; FETCH_MOTD_EXPLICIT=1 ;;
            --fetch-shellrc)      FETCH_SHELLRC=1 ;;
            --no-fetch-shellrc)   FETCH_SHELLRC=0 ;;
            --no-download)        NO_DOWNLOAD=1 ;;
            --alt-screen)         ALT_SCREEN=1 ;;
            --no-alt-screen)      ALT_SCREEN=0 ;;
            --proxy)              need_val "$_pa_a" "${2:-}"; PROXY_URL=$2; shift ;;
            --proxy=*)            PROXY_URL=${_pa_a#*=} ;;
            --proxy-auth)         need_val "$_pa_a" "${2:-}"; PROXY_AUTH=$2; shift ;;
            --proxy-auth=*)       PROXY_AUTH=${_pa_a#*=} ;;
            --resin)              need_val "$_pa_a" "${2:-}"; RESIN_URL=$2; shift ;;
            --resin=*)            RESIN_URL=${_pa_a#*=} ;;
            --resin-token)        need_val "$_pa_a" "${2:-}"; RESIN_TOKEN=$2; shift ;;
            --resin-token=*)      RESIN_TOKEN=${_pa_a#*=} ;;
            --resin-account)      need_val "$_pa_a" "${2:-}"; RESIN_ACCOUNT=$2; shift ;;
            --resin-account=*)    RESIN_ACCOUNT=${_pa_a#*=} ;;
            --ip-family)          need_val "$_pa_a" "${2:-}"; IP_FAMILY=$2; shift ;;
            --ip-family=*)        IP_FAMILY=${_pa_a#*=} ;;
            --komari-prefer-ip-version)
                need_val "$_pa_a" "${2:-}"; KOMARI_PREFER_IP=$2; shift ;;
            --komari-prefer-ip-version=*) KOMARI_PREFER_IP=${_pa_a#*=} ;;
            --no-fetch-motd)      FETCH_MOTD=0 ;;
            --no-service)         SERVICE_MODE='manual' ;;

            --lang)               need_val "$_pa_a" "${2:-}"; CLUSTER_JOIN_LANG=$2; lang_init; shift ;;
            --lang=*)             CLUSTER_JOIN_LANG=${_pa_a#*=}; lang_init ;;
            --gh-proxy)           need_val "$_pa_a" "${2:-}"; GH_PROXY=$2; shift ;;
            --gh-proxy=*)         GH_PROXY=${_pa_a#*=} ;;
            # 兼容官方 install.sh 的参数命名
            --install-ghproxy)    need_val "$_pa_a" "${2:-}"; GH_PROXY=$2; shift ;;
            --install-ghproxy=*)  GH_PROXY=${_pa_a#*=} ;;
            --install-no-mirror)  NO_GH_PROXY=1 ;;
            --install-dir)        need_val "$_pa_a" "${2:-}"; KOMARI_DIR=$2; shift ;;
            --install-dir=*)      KOMARI_DIR=${_pa_a#*=} ;;
            --install-service-name)
                need_val "$_pa_a" "${2:-}"; KOMARI_SERVICE=$2; shift ;;
            --install-service-name=*) KOMARI_SERVICE=${_pa_a#*=} ;;
            --log)                need_val "$_pa_a" "${2:-}"; LOG_FILE=$2; shift ;;
            --log=*)              LOG_FILE=${_pa_a#*=} ;;

            -e|--komari-endpoint|--endpoint)
                need_val "$_pa_a" "${2:-}"; KOMARI_ENDPOINT=$2; shift ;;
            --komari-endpoint=*|--endpoint=*)
                KOMARI_ENDPOINT=${_pa_a#*=} ;;
            -t|--komari-token|--token)
                need_val "$_pa_a" "${2:-}"; KOMARI_TOKEN=$2; shift ;;
            --komari-token=*|--token=*)
                KOMARI_TOKEN=${_pa_a#*=} ;;
            --komari-ad-key|--auto-discovery)
                need_val "$_pa_a" "${2:-}"; KOMARI_AD_KEY=$2; shift ;;
            --komari-ad-key=*|--auto-discovery=*)
                KOMARI_AD_KEY=${_pa_a#*=} ;;
            --komari-interval)
                need_val "$_pa_a" "${2:-}"; KOMARI_INTERVAL=$2; shift ;;
            --komari-interval=*)  KOMARI_INTERVAL=${_pa_a#*=} ;;
            --komari-info-interval)
                need_val "$_pa_a" "${2:-}"; KOMARI_INFO_INTERVAL=$2; shift ;;
            --komari-info-interval=*) KOMARI_INFO_INTERVAL=${_pa_a#*=} ;;
            --komari-version)     need_val "$_pa_a" "${2:-}"; KOMARI_VERSION=$2; shift ;;
            --komari-version=*)   KOMARI_VERSION=${_pa_a#*=} ;;
            --komari-force-register) KOMARI_FORCE_REGISTER=1 ;;
            --komari-no-web-ssh)  KOMARI_DISABLE_WEB_SSH=1 ;;
            --komari-web-ssh)     KOMARI_DISABLE_WEB_SSH=0 ;;
            --komari-insecure)    KOMARI_INSECURE=1 ;;
            --komari-no-autoupdate) KOMARI_DISABLE_AUTOUPDATE=1 ;;
            --komari-extra)
                need_val "$_pa_a" "${2:-}"; KOMARI_EXTRA=$2; shift ;;
            --komari-extra=*)     KOMARI_EXTRA=${_pa_a#*=} ;;

            --et-mode)            need_val "$_pa_a" "${2:-}"; ET_MODE=$2; shift ;;
            --et-mode=*)          ET_MODE=${_pa_a#*=} ;;
            --et-config-server|-w)
                need_val "$_pa_a" "${2:-}"; ET_CONFIG_SERVER=$2; shift ;;
            --et-config-server=*) ET_CONFIG_SERVER=${_pa_a#*=} ;;
            --et-machine-id)
                need_val "$_pa_a" "${2:-}"; ET_MACHINE_ID=$2; shift ;;
            --et-machine-id=*)    ET_MACHINE_ID=${_pa_a#*=} ;;
            --et-network-name)
                need_val "$_pa_a" "${2:-}"; ET_NETWORK_NAME=$2; shift ;;
            --et-network-name=*)  ET_NETWORK_NAME=${_pa_a#*=} ;;
            --et-network-secret)
                need_val "$_pa_a" "${2:-}"; ET_NETWORK_SECRET=$2; shift ;;
            --et-network-secret=*) ET_NETWORK_SECRET=${_pa_a#*=} ;;
            --et-peers|-p)
                need_val "$_pa_a" "${2:-}"; ET_PEERS=$2; shift ;;
            --et-peers=*)         ET_PEERS=${_pa_a#*=} ;;
            --et-ip|--et-ipv4)
                need_val "$_pa_a" "${2:-}"; ET_IPV4=$2; ET_DHCP=0; shift ;;
            --et-ip=*|--et-ipv4=*)
                ET_IPV4=${_pa_a#*=}; ET_DHCP=0 ;;
            --et-no-dhcp)         ET_DHCP=0 ;;
            --et-dhcp)            ET_DHCP=1; ET_IPV4='' ;;
            --et-hostname)
                need_val "$_pa_a" "${2:-}"; ET_HOSTNAME=$2; shift ;;
            --et-hostname=*)      ET_HOSTNAME=${_pa_a#*=} ;;
            --et-version)
                need_val "$_pa_a" "${2:-}"; ET_VERSION=$2; shift ;;
            --et-version=*)       ET_VERSION=${_pa_a#*=} ;;
            --et-extra)
                need_val "$_pa_a" "${2:-}"; ET_EXTRA=$2; shift ;;
            --et-extra=*)         ET_EXTRA=${_pa_a#*=} ;;

            --web-deploy)         need_val "$_pa_a" "${2:-}"; WEB_DEPLOY=$2; shift ;;
            --web-deploy=*)       WEB_DEPLOY=${_pa_a#*=} ;;
            --web-port)           need_val "$_pa_a" "${2:-}"; WEB_PORT=$2; shift ;;
            --web-port=*)         WEB_PORT=${_pa_a#*=} ;;
            --web-cfg-port)       need_val "$_pa_a" "${2:-}"; WEB_CFG_PORT=$2; shift ;;
            --web-cfg-port=*)     WEB_CFG_PORT=${_pa_a#*=} ;;
            --web-cfg-proto)      need_val "$_pa_a" "${2:-}"; WEB_CFG_PROTO=$2; shift ;;
            --web-cfg-proto=*)    WEB_CFG_PROTO=${_pa_a#*=} ;;
            --web-api-host)       need_val "$_pa_a" "${2:-}"; WEB_API_HOST=$2; shift ;;
            --web-api-host=*)     WEB_API_HOST=${_pa_a#*=} ;;

            --uninstall-target)   need_val "$_pa_a" "${2:-}"; UNINSTALL_TARGET=$2; shift ;;
            --uninstall-target=*) UNINSTALL_TARGET=${_pa_a#*=} ;;

            --) shift; break ;;
            -*) die "$T_UNKNOWN_OPT $_pa_a $T_SEE_HELP" ;;
            *)  die "$T_UNKNOWN_ARG $_pa_a $T_SEE_HELP" ;;
        esac
        shift
    done
}

#-------------------------------------------------------------------------------
# 9. 配置持久化（幂等重跑用；采用 KEY=VALUE，读取时不 eval，避免注入）
#-------------------------------------------------------------------------------
# 注意：KOMARI_AD_KEY / KOMARI_TOKEN 是密钥，故意不放进存档，
#       令牌由 agent 自己的 0600 配置文件保存。
CONF_KEYS='KOMARI_ENDPOINT KOMARI_VERSION KOMARI_INTERVAL KOMARI_INFO_INTERVAL
KOMARI_DISABLE_WEB_SSH KOMARI_INSECURE KOMARI_DISABLE_AUTOUPDATE KOMARI_EXTRA
ET_MODE ET_CONFIG_SERVER ET_MACHINE_ID ET_NETWORK_NAME ET_NETWORK_SECRET ET_PEERS
ET_IPV4 ET_DHCP ET_HOSTNAME ET_EXTRA ET_VERSION ET_LISTEN_PORT
WEB_DEPLOY WEB_PORT WEB_CFG_PORT WEB_CFG_PROTO WEB_API_HOST GH_PROXY NO_GH_PROXY FETCH_TOOL IP_FAMILY KOMARI_PREFER_IP
PROXY_URL PROXY_AUTH RESIN_URL RESIN_TOKEN RESIN_ACCOUNT'

conf_default_path() {
    if [ "$(id -u)" = 0 ]; then
        printf '%s' '/etc/cluster-join/cluster.env'
    else
        printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/cluster-join/cluster.env"
    fi
}

load_conf() {
    [ -n "$CONF_FILE" ] || CONF_FILE=$(conf_default_path)
    if [ "${RESET_CONF:-0}" = 1 ]; then
        rm -f "$CONF_FILE" 2>/dev/null || :
        return 0
    fi
    [ -f "$CONF_FILE" ] || return 0
    while IFS='=' read -r _lc_k _lc_v; do
        case "$_lc_k" in
            ''|\#*) continue ;;
        esac
        _lc_found=0
        for _lc_allowed in $CONF_KEYS; do
            if [ "$_lc_k" = "$_lc_allowed" ]; then _lc_found=1; break; fi
        done
        [ "$_lc_found" = 1 ] || continue
        # 命令行/环境变量优先：仅在该变量为空时采用配置文件的值
        eval "_lc_cur=\${$_lc_k:-}"
        if [ -z "$_lc_cur" ]; then
            eval "$_lc_k=\$_lc_v"
        fi
    done <"$CONF_FILE"
    return 0
}

save_conf() {
    [ -n "$CONF_FILE" ] || CONF_FILE=$(conf_default_path)
    _sc_dir=$(dirname "$CONF_FILE")
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s write config %s\n' "$c_ylw" "$c_rst" "$CONF_FILE"
        return 0
    fi
    ( umask 077; mkdir -p "$_sc_dir" 2>/dev/null ) || {
        warn "$T_SAVE_FAIL $_sc_dir"
        return 1
    }
    _sc_tmp="$CONF_FILE.tmp.$$"
    (
        umask 077
        : >"$_sc_tmp" || exit 1
        printf '# %s auto-generated\n' "$APP_NAME" >>"$_sc_tmp"
        printf '# generated at: %s\n' "$(_ts)" >>"$_sc_tmp"
        for _sc_k in $CONF_KEYS; do
            eval "_sc_v=\${$_sc_k:-}"
            # 值与键中的换行会破坏格式，直接剔除
            _sc_v=$(printf '%s' "$_sc_v" | tr -d '\n\r')
            printf '%s=%s\n' "$_sc_k" "$_sc_v" >>"$_sc_tmp"
        done
    ) || { warn "$T_SAVE_WRITE_FAIL $_sc_tmp"; return 1; }
    mv -f "$_sc_tmp" "$CONF_FILE" 2>/dev/null || return 1
    chmod 600 "$CONF_FILE" 2>/dev/null || :
    dim "$T_SAVED_CONF $CONF_FILE"
    return 0
}

#-------------------------------------------------------------------------------
# 10. 预检
#-------------------------------------------------------------------------------
preflight() {
    step "$T_STEP_PREFLIGHT"
    detect_os_arch
    apply_ip_family
    detect_init
    info "$T_OS_INFO $OS_NAME / $ARCH_RAW / $SERVICE_MODE"
    if [ "$SERVICE_MODE" = 'manual' ]; then
        warn "$T_INIT_MANUAL_1"
        warn "$T_INIT_MANUAL_2"
        warn "$T_INIT_MANUAL_3"
    fi
    if [ "$HAVE_TTY" = 1 ]; then
        info "$T_TTY_YES"
    elif [ "$INTERACTIVE" = 1 ]; then
        info "$T_TTY_STDIN"
    else
        info "$T_TTY_NO"
    fi
    # TUN 设备
    if [ -e /dev/net/tun ]; then
        dim "$T_TUN_OK"
    else
        warn "$T_TUN_MISSING"
        if have modprobe; then
            run_sh 'modprobe tun 2>/dev/null || true'
            if [ -e /dev/net/tun ]; then
                ok "$T_TUN_LOADED"
            else
                warn "$T_TUN_LOADFAIL"
            fi
        fi
        if [ ! -e /dev/net/tun ]; then
            dim "$T_TUN_HINT"
        fi
    fi
    # 下载工具（精简镜像可能一个都没有，尝试补装）
    if have curl || have wget; then
        dim "$T_DL_OK"
    elif ! ensure_downloader; then
        die "$T_NO_DOWNLOADER"
    fi
    ok "$T_PREFLIGHT_DONE"
}

#-------------------------------------------------------------------------------
# 11. Komari Agent
#
#  密钥处理原则（依据 komari-agent 真实实现）：
#    * --auto-discovery <AD Key> 只是「一次性引导」：首次启动时 agent 会
#      POST /api/clients/register 换取 {uuid, token}，并写进自己目录下的
#      auto-discovery.json；此后即使再传 AD Key 也不会重新注册。
#    * 不传 --auto-discovery 时 agent 根本不会读 auto-discovery.json。
#    * 因此本脚本：用 AD Key 跑一次注册 → 取出节点令牌 → 写进 0600 的
#      agent.json → 服务单元只引用 --config。AD Key 不落盘、不进单元。
#-------------------------------------------------------------------------------
# 从 agent.json / auto-discovery.json 取字符串字段（格式固定，无需完整 JSON 解析）
json_read_str() {
    _jr_file=$1
    _jr_key=$2
    [ -f "$_jr_file" ] || return 0
    sed -n "s/.*\"$_jr_key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$_jr_file" 2>/dev/null | head -n 1
}

# JSON 字符串最小转义
json_escape() {
    printf '%s' "$1" | tr -d '\r\n\t' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 本机是否已有可用节点令牌
komari_local_token() {
    _klt=''
    if [ -f "$KOMARI_AGENT_CFG" ]; then
        _klt=$(json_read_str "$KOMARI_AGENT_CFG" token)
    fi
    if [ -z "$_klt" ] && [ -f "$KOMARI_AD_FILE" ]; then
        _klt=$(json_read_str "$KOMARI_AD_FILE" token)
    fi
    printf '%s' "$_klt"
}

# 用 AD Key 跑一次 agent 完成注册；AD Key 只以环境变量传入，不出现在 ps 命令行里
komari_bootstrap() {
    _kb_log="${TMP_DIR}/komari-register.log"
    info "$T_KOMARI_REGISTERING"
    rm -f "$KOMARI_AD_FILE" 2>/dev/null || :
    AGENT_ENDPOINT="$KOMARI_ENDPOINT" \
    AGENT_AUTO_DISCOVERY_KEY="$KOMARI_AD_KEY" \
        "$KOMARI_BIN" --disable-auto-update >>"$_kb_log" 2>&1 &
    _kb_pid=$!
    _kb_n=0
    while [ "$_kb_n" -lt 20 ]; do
        [ -s "$KOMARI_AD_FILE" ] && break
        kill -0 "$_kb_pid" 2>/dev/null || break
        sleep 1
        _kb_n=$((_kb_n + 1))
    done
    kill "$_kb_pid" 2>/dev/null || :
    wait "$_kb_pid" 2>/dev/null || :
    if [ ! -s "$KOMARI_AD_FILE" ]; then
        err "$T_KOMARI_REGISTER_FAIL"
        if [ -f "$_kb_log" ]; then
            tail -n 3 "$_kb_log" 2>/dev/null | while IFS= read -r _kb_l; do
                [ -n "$_kb_l" ] && dim "$_kb_l"
            done
        fi
        return 1
    fi
    # 该文件由 agent 以 0644 写出且内含令牌，收紧权限
    chmod 600 "$KOMARI_AD_FILE" 2>/dev/null || :
    ok "$T_KOMARI_REGISTERED"
    return 0
}

# 生成 0600 的 agent 配置文件：服务单元只引用它，密钥不出现在单元里
komari_write_cfg() {
    _wc_token=$1
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s write %s (mode 600)\n' "$c_ylw" "$c_rst" "$KOMARI_AGENT_CFG"
        return 0
    fi
    _wc_tmp="$KOMARI_AGENT_CFG.tmp.$$"
    (
        umask 077
        : >"$_wc_tmp" || exit 1
        printf '{\n' >>"$_wc_tmp"
        printf '  "endpoint": "%s",\n' "$(json_escape "$KOMARI_ENDPOINT")" >>"$_wc_tmp"
        printf '  "token": "%s"' "$(json_escape "$_wc_token")" >>"$_wc_tmp"
        case "$KOMARI_INTERVAL" in
            ''|*[!0-9.]*) : ;;
            *) printf ',\n  "interval": %s' "$KOMARI_INTERVAL" >>"$_wc_tmp" ;;
        esac
        case "$KOMARI_INFO_INTERVAL" in
            ''|*[!0-9]*) : ;;
            *) printf ',\n  "info_report_interval": %s' "$KOMARI_INFO_INTERVAL" >>"$_wc_tmp" ;;
        esac
        [ "$KOMARI_DISABLE_WEB_SSH" = 1 ] && printf ',\n  "disable_web_ssh": true' >>"$_wc_tmp"
        [ "$KOMARI_INSECURE" = 1 ] && printf ',\n  "ignore_unsafe_cert": true' >>"$_wc_tmp"
        [ "$KOMARI_DISABLE_AUTOUPDATE" = 1 ] && printf ',\n  "disable_auto_update": true' >>"$_wc_tmp"
        case "$KOMARI_PREFER_IP" in
            4|6) printf ',\n  "prefer_ip_version": "%s"' "$KOMARI_PREFER_IP" >>"$_wc_tmp" ;;
        esac
        printf '\n}\n' >>"$_wc_tmp"
    ) || { err "$T_KOMARI_CFG_FAIL $_wc_tmp"; return 1; }
    mv -f "$_wc_tmp" "$KOMARI_AGENT_CFG" 2>/dev/null || return 1
    chmod 600 "$KOMARI_AGENT_CFG" 2>/dev/null || :
    dim "$T_KOMARI_CFG_WRITTEN $KOMARI_AGENT_CFG"
    return 0
}

collect_komari() {
    step "$T_STEP_KOMARI_CFG"
    if [ -n "$KOMARI_ENDPOINT" ]; then
        info "$T_KOMARI_PANEL_SET $KOMARI_ENDPOINT"
    fi
    ask_text "$T_KOMARI_PANEL" "$KOMARI_ENDPOINT"
    KOMARI_ENDPOINT=$ANS
    if [ -z "$KOMARI_ENDPOINT" ]; then
        warn "$T_KOMARI_SKIP_URL"
        return 1
    fi

    # 凭证：本机已有令牌就直接复用，不再索要 AD Key；否则默认用 AD Key 一次性注册
    if [ -z "$KOMARI_TOKEN" ] && [ -z "$KOMARI_AD_KEY" ] && [ "$KOMARI_FORCE_REGISTER" != 1 ]; then
        if [ -n "$(komari_local_token)" ]; then
            info "$T_KOMARI_REUSE"
        else
            ask_yesno "$T_KOMARI_USE_AD" 'y'
            if [ "$ANS" = y ]; then
                ask_text "$T_KOMARI_AD" "$KOMARI_AD_KEY" 1
                KOMARI_AD_KEY=$ANS
            else
                ask_text "$T_KOMARI_TOKEN" "$KOMARI_TOKEN" 1
                KOMARI_TOKEN=$ANS
            fi
        fi
    fi
    if [ -z "$KOMARI_TOKEN" ] && [ -z "$KOMARI_AD_KEY" ] && [ -z "$(komari_local_token)" ]; then
        warn "$T_KOMARI_NO_TOKEN"
        return 1
    fi

    ask_text "$T_KOMARI_INTERVAL" "$KOMARI_INTERVAL"
    KOMARI_INTERVAL=$ANS
    ask_yesno "$T_KOMARI_NOWEBSSH" "$([ "$KOMARI_DISABLE_WEB_SSH" = 1 ] && echo y || echo n)"
    if [ "$ANS" = y ]; then KOMARI_DISABLE_WEB_SSH=1; else KOMARI_DISABLE_WEB_SSH=0; fi
    return 0
}

# 解析要安装的 Komari Agent 版本：latest（默认）| snapshot | 具体标签
# snapshot 取 releases 里最大的 Snapshot-* 标签（与官方脚本同逻辑）
komari_resolve_version() {
    _kr_req=$1
    case "$_kr_req" in
        ''|latest)
            printf '%s' 'latest'
            return 0
            ;;
        snapshot)
            _kr_api="https://api.github.com/repos/$GH_KOMARI_REPO/releases?per_page=100"
            for _kr_u in $(url_candidates "$_kr_api"); do
                _kr_json=$(http_to_stdout "$_kr_u" || :)
                [ -n "$_kr_json" ] || continue
                _kr_v=$(printf '%s' "$_kr_json" \
                    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"Snapshot-[^"]*"' \
                    | sed 's/.*"\(Snapshot-[^"]*\)".*/\1/' \
                    | LC_ALL=C sort -r | head -n 1)
                if [ -n "$_kr_v" ]; then
                    printf '%s' "$_kr_v"
                    return 0
                fi
            done
            return 1
            ;;
        *)
            printf '%s' "$_kr_req"
            return 0
            ;;
    esac
}

build_komari_args() {
    # 端点/令牌/间隔等结构化配置都在 0600 的 agent.json 里（--config 优先级最高），
    # 服务单元与 ps 里都不出现任何密钥。
    _bk_args="--config $KOMARI_AGENT_CFG"
    [ -n "$KOMARI_EXTRA" ] && _bk_args="$_bk_args $KOMARI_EXTRA"
    KOMARI_ARGS=$_bk_args
}

install_komari() {
    step "$T_STEP_KOMARI_INSTALL"
    _ik_arch=$(komari_arch) || die "$T_KOMARI_BAD_ARCH $ARCH_RAW"
    _ik_os=$OS_NAME
    [ "$_ik_os" = linux ] || warn "$T_KOMARI_OS_WARN $_ik_os"

    _ik_name="komari-agent-${_ik_os}-${_ik_arch}"
    _ik_ver=$(komari_resolve_version "$KOMARI_VERSION") || {
        err "$T_KOMARI_VER_FAIL $KOMARI_VERSION"
        return 1
    }
    if [ "$_ik_ver" = latest ]; then
        _ik_url="https://github.com/$GH_KOMARI_REPO/releases/latest/download/$_ik_name"
    else
        _ik_url="https://github.com/$GH_KOMARI_REPO/releases/download/$_ik_ver/$_ik_name"
        dim "$T_KOMARI_VERSION_IS $_ik_ver"
    fi

    run mkdir -p "$KOMARI_DIR"
    # 直接覆盖正在运行的可执行文件会 ETXTBSY（Text file busy）。
    # 所以先下到同目录的暂存名，再用 mv（rename）原子替换——
    # rename 只改目录项，正在运行的进程继续持有旧 inode，不受影响。
    if [ "$NO_DOWNLOAD" = 1 ]; then
        if [ ! -x "$KOMARI_BIN" ]; then
            err "$T_NODL_MISSING $KOMARI_BIN"
            return 1
        fi
        info "$T_NODL_USING $KOMARI_BIN"
    else
        _ik_stage="$KOMARI_DIR/.agent.new.$$"
        if ! dl "$_ik_url" "$_ik_stage" 'Komari Agent' binary; then
            run rm -f "$_ik_stage"
            return 1
        fi
        if ! verify_executable "$_ik_stage" 'komari-agent'; then
            run rm -f "$_ik_stage"
            return 1
        fi
        run chmod +x "$_ik_stage"
        if [ "$DRY_RUN" != 1 ]; then
            if ! mv -f "$_ik_stage" "$KOMARI_BIN"; then
                err "$T_BIN_REPLACE_FAIL $KOMARI_BIN"
                rm -f "$_ik_stage"
                return 1
            fi
        fi
    fi
    ok "$T_BIN_READY $KOMARI_BIN"

    # 解析节点令牌：AD Key 只用于一次性注册，绝不写进服务单元或脚本存档
    _ik_token=''
    if [ "$DRY_RUN" = 1 ]; then
        _ik_token='<resolved-at-runtime>'
    else
        # 先确认这个二进制真能跑起来，再谈它支持哪些参数
        _ik_help=$("$KOMARI_BIN" --help 2>&1) || :
        if ! printf '%s' "$_ik_help" | grep -qi 'komari'; then
            err "$T_KOMARI_BIN_BROKEN $KOMARI_BIN"
            dim "$T_KOMARI_BIN_BROKEN_HINT"
            return 1
        fi
        if ! printf '%s' "$_ik_help" | grep -q -- '--config'; then
            err "$T_KOMARI_NO_CONFIG_FLAG"
            return 1
        fi
        # 1) 显式要求重新注册
        if [ "$KOMARI_FORCE_REGISTER" = 1 ] && [ -n "$KOMARI_AD_KEY" ]; then
            komari_bootstrap || return 1
            _ik_token=$(komari_local_token)
        fi
        # 2) 默认复用本机已注册令牌，避免重复注册产生重复节点
        if [ -z "$_ik_token" ] && [ "$KOMARI_FORCE_REGISTER" != 1 ]; then
            _ik_token=$(komari_local_token)
            if [ -n "$_ik_token" ]; then dim "$T_KOMARI_REUSE"; fi
        fi
        # 3) 首次注册
        if [ -z "$_ik_token" ] && [ -n "$KOMARI_AD_KEY" ]; then
            komari_bootstrap || return 1
            _ik_token=$(komari_local_token)
        fi
        # 4) 直接给定的单节点令牌
        if [ -z "$_ik_token" ] && [ -n "$KOMARI_TOKEN" ]; then
            _ik_token=$KOMARI_TOKEN
        fi
        if [ -z "$_ik_token" ]; then
            err "$T_KOMARI_NO_TOKEN"
            return 1
        fi
    fi

    komari_write_cfg "$_ik_token" || return 1

    build_komari_args
    dim "$T_CMDLINE $KOMARI_ARGS"

    write_komari_service
    start_service "$KOMARI_SERVICE" 'komari'
    # 至此安装 + 自启动注册完成，脚本不再介入运行期
    return 0
}

write_komari_service() {
    case "$SERVICE_MODE" in
        systemd)
            run_sh "cat > /etc/systemd/system/${KOMARI_SERVICE}.service <<'UNITEOF'
[Unit]
Description=Komari Agent Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${KOMARI_BIN} ${KOMARI_ARGS}
WorkingDirectory=${KOMARI_DIR}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNITEOF"
            run systemctl daemon-reload
            ;;
        openrc)
            run_sh "cat > /etc/init.d/${KOMARI_SERVICE} <<'UNITEOF'
#!/sbin/openrc-run
name=\"Komari Agent\"
command=\"${KOMARI_BIN}\"
command_args=\"${KOMARI_ARGS}\"
command_background=true
pidfile=\"/run/${KOMARI_SERVICE}.pid\"
output_log=\"/var/log/${KOMARI_SERVICE}.log\"
error_log=\"/var/log/${KOMARI_SERVICE}.log\"
depend() { need net; after network; }
UNITEOF"
            run chmod +x "/etc/init.d/${KOMARI_SERVICE}"
            ;;
        procd)
            run_sh "cat > /etc/init.d/${KOMARI_SERVICE} <<'UNITEOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command ${KOMARI_BIN} ${KOMARI_ARGS}
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
UNITEOF"
            run chmod +x "/etc/init.d/${KOMARI_SERVICE}"
            ;;
        *)
            run_sh "cat > ${KOMARI_DIR}/start.sh <<'UNITEOF'
#!/bin/sh
exec ${KOMARI_BIN} ${KOMARI_ARGS}
UNITEOF"
            run chmod +x "$KOMARI_DIR/start.sh"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# 12. EasyTier
#-------------------------------------------------------------------------------
collect_easytier() {
    step "$T_STEP_ET_CFG"
    # 先校验：非法模式必须在进入选择流程前报错，
    # 否则 choose 的默认分支会把 'bogus' 静默纠正成 web。
    case "$ET_MODE" in
        ''|web|peer|server|off) : ;;
        *) die "$T_ET_MODE_BAD $ET_MODE" ;;
    esac
    if [ -n "$ET_MODE" ]; then
        dim "$T_ET_CUR_MODE $ET_MODE"
    fi
    choose "$T_ET_CHOOSE_MODE" "$(case "$ET_MODE" in off) echo 4;; peer) echo 2;; server) echo 3;; *) echo 1;; esac)" \
        "$T_ET_MODE_WEB" \
        "$T_ET_MODE_PEER" \
        "$T_ET_MODE_SERVER" \
        "$T_ET_MODE_OFF"
    case "$ANS" in
        1) ET_MODE=web ;;
        2) ET_MODE=peer ;;
        3) ET_MODE=server ;;
        4) ET_MODE=off ;;
    esac

    # 选择「不启用并网」：本机只做监控，不接入虚拟网络
    if [ "$ET_MODE" = off ]; then
        warn "$T_ET_DISABLED"
        return 1
    fi

    case "$ET_MODE" in
        web)
            choose "$T_ET_CHOOSE_CONSOLE" 1 \
                "$T_ET_CONSOLE_SELF" \
                "$T_ET_CONSOLE_PUBLIC"
            if [ "$ANS" = 1 ]; then
                if [ -z "$ET_CONFIG_SERVER" ]; then
                    _ce_ip=$(local_ip)
                    ET_CONFIG_SERVER="udp://$_ce_ip:$WEB_CFG_PORT/admin"
                fi
                ask_text "$T_ET_CFG_SERVER" "$ET_CONFIG_SERVER"
                ET_CONFIG_SERVER=$ANS
            else
                _ce_user=''
                case "$ET_CONFIG_SERVER" in
                    *://*) : ;;
                    *) _ce_user=$ET_CONFIG_SERVER ;;
                esac
                ask_text "$T_ET_CONSOLE_USER" "$_ce_user"
                ET_CONFIG_SERVER=$ANS
            fi
            if [ -z "$ET_CONFIG_SERVER" ]; then
                warn "$T_ET_SKIP_CFG"
                return 1
            fi
            ask_text "$T_ET_MACHINE_ID" "$ET_MACHINE_ID"
            ET_MACHINE_ID=$ANS
            ask_text "$T_ET_HOSTNAME" "$ET_HOSTNAME"
            ET_HOSTNAME=$ANS
            ;;
        peer)
            ask_text "$T_ET_NETNAME" "$ET_NETWORK_NAME"
            ET_NETWORK_NAME=$ANS
            if [ -z "$ET_NETWORK_NAME" ]; then warn "$T_ET_NETNAME_EMPTY"; return 1; fi
            ask_text "$T_ET_NETSECRET" "$ET_NETWORK_SECRET" 1
            ET_NETWORK_SECRET=$ANS
            if [ -z "$ET_NETWORK_SECRET" ]; then warn "$T_ET_NETSECRET_EMPTY"; return 1; fi
            ask_text "$T_ET_PEERS" "$ET_PEERS"
            ET_PEERS=$ANS
            if [ -z "$ET_PEERS" ]; then warn "$T_ET_PEERS_EMPTY"; return 1; fi
            ask_text "$T_ET_IP" "$ET_IPV4"
            ET_IPV4=$ANS
            if [ -z "$ET_IPV4" ]; then ET_DHCP=1; else ET_DHCP=0; fi
            ;;
        server)
            ask_text "$T_ET_SERVER_IP" "${ET_IPV4:-10.126.126.1}"
            ET_IPV4=$ANS
            ET_DHCP=0
            ask_text "$T_ET_LISTEN_PORT" "$ET_LISTEN_PORT"
            ET_LISTEN_PORT=$ANS
            info "$T_ET_SERVER_NOTE"
            ;;
    esac

    ask_text "$T_ET_VERSION" "$ET_VERSION"
    ET_VERSION=$ANS
    return 0
}

# 生成 easytier-core 启动参数
build_et_args() {
    _be_args=''
    case "$ET_MODE" in
        off) : ;;
        web)
            _be_args="-w $ET_CONFIG_SERVER"
            [ -n "$ET_MACHINE_ID" ] && _be_args="$_be_args --machine-id $ET_MACHINE_ID"
            _be_args="$_be_args --config-dir $ET_CONF_DIR"
            [ -n "$ET_HOSTNAME" ] && _be_args="$_be_args --hostname $ET_HOSTNAME"
            ;;
        peer)
            _be_args="--network-name $ET_NETWORK_NAME --network-secret $ET_NETWORK_SECRET"
            if [ -n "$ET_IPV4" ]; then
                _be_args="$_be_args -i $ET_IPV4"
            elif [ "$ET_DHCP" = 1 ]; then
                _be_args="$_be_args -d"
            fi
            for _be_p in $ET_PEERS; do
                _be_args="$_be_args -p $_be_p"
            done
            [ -n "$ET_HOSTNAME" ] && _be_args="$_be_args --hostname $ET_HOSTNAME"
            ;;
        server)
            _be_args="-i $ET_IPV4 --relay-network-whitelist *"
            _be_args="$_be_args -l tcp://0.0.0.0:${ET_LISTEN_PORT:-11010}"
            _be_args="$_be_args -l udp://0.0.0.0:${ET_LISTEN_PORT:-11010}"
            [ -n "$ET_HOSTNAME" ] && _be_args="$_be_args --hostname $ET_HOSTNAME"
            ;;
    esac
    [ -n "$ET_EXTRA" ] && _be_args="$_be_args $ET_EXTRA"
    ET_ARGS=$_be_args
}

# 只下载并安装 EasyTier 二进制（幂等），不注册服务
# ensure_et_binaries [force]
ensure_et_binaries() {
    _eb_force=${1:-0}
    _eb_need_web=${2:-0}

    # 按用途决定要哪些二进制：普通节点只需 core+cli（10.2MB），
    # 只有部署 Web 控制台才要 web / web-embed（再多 14.2MB）。
    if [ "$_eb_need_web" = 1 ]; then
        _eb_files='easytier-core easytier-cli easytier-web easytier-web-embed'
    else
        _eb_files='easytier-core easytier-cli'
    fi

    if [ "$_eb_force" != 1 ] && [ "$DRY_RUN" != 1 ]; then
        _eb_have=1
        for _eb_f in $_eb_files; do
            [ -x "$ET_DIR/$_eb_f" ] || _eb_have=0
        done
        if [ "$_eb_have" = 1 ]; then
            dim "$T_ET_BIN_PRESENT $ET_DIR"
            return 0
        fi
    fi
    if [ "$NO_DOWNLOAD" = 1 ]; then
        err "$T_NODL_MISSING $ET_DIR ($_eb_files)"
        return 1
    fi
    if ! ensure_unzip; then return 1; fi

    _ie_ver=$ET_VERSION
    if [ -z "$_ie_ver" ]; then
        info "$T_ET_RESOLVING"
        _ie_ver=$(et_latest_version)
        [ -z "$_ie_ver" ] && die "$T_ET_VER_UNKNOWN"
    fi
    info "$T_ET_VERSION_IS $_ie_ver"

    _ie_archs=$(et_arch_candidates) || die "$T_ET_BAD_ARCH $ARCH_RAW"
    run mkdir -p "$ET_DIR" "$ET_CONF_DIR"

    # 下载、解压、替换全部只在目标文件系统内进行。
    # 小 VPS 的 /tmp 常是 tmpfs：把 25MB 压缩包 + 解压产物放那里会直接吃内存。
    _ie_stage="$ET_DIR/.stage.$$"
    _ie_zip="$_ie_stage/easytier.zip"
    run mkdir -p "$_ie_stage"   # 下载目标目录必须先存在
    _ie_ok=0
    for _ie_a in $_ie_archs; do
        _ie_url="https://github.com/$GH_EASYTIER_REPO/releases/download/${_ie_ver}/easytier-linux-${_ie_a}-${_ie_ver}.zip"
        dim "$T_ET_TRY_ARCH$_ie_a"
        if dl "$_ie_url" "$_ie_zip" "EasyTier($_ie_a)"; then
            _ie_ok=1; _ie_arch=$_ie_a; break
        fi
    done
    if [ "$_ie_ok" != 1 ]; then
        run rm -rf "$_ie_stage"
        err "$T_ET_DL_FAIL"
        return 1
    fi
    ok "$T_ET_DL_OK$_ie_arch"
    [ "$DRY_RUN" = 1 ] && return 0

    # 空间预检：宁可提前给出可读的报错，也别解压到一半 No space left on device
    _ie_zip_kb=$(du -k "$_ie_zip" 2>/dev/null | awk '{print $1}')
    case "$_ie_zip_kb" in ''|*[!0-9]*) _ie_zip_kb=0 ;; esac
    _ie_need_kb=$((_ie_zip_kb * 3))
    _ie_free_kb=$(free_space_kb "$ET_DIR")
    case "$_ie_free_kb" in ''|*[!0-9]*) _ie_free_kb='' ;; esac
    if [ -n "$_ie_free_kb" ] && [ "$_ie_free_kb" -lt "$_ie_need_kb" ]; then
        err "$T_ET_NOSPACE $ET_DIR ($T_ET_NEED $((_ie_need_kb / 1024))MB, $T_ET_FREE $((_ie_free_kb / 1024))MB)"
        run rm -rf "$_ie_stage"
        return 1
    fi

    # 只解压需要的条目
    _ie_x="$_ie_stage/x"
    _ie_pats=''
    for _eb_f in $_eb_files; do
        _ie_pats="$_ie_pats */$_eb_f"
    done
    # shellcheck disable=SC2086
    if ! unzip_entries "$_ie_zip" "$_ie_x" $_ie_pats >/dev/null 2>&1; then
        err "$T_ET_UNZIP_FAIL"
        run rm -rf "$_ie_stage"
        return 1
    fi
    run rm -f "$_ie_zip"   # 压缩包用完立刻删

    # 同目录 mv 即 rename：可安全覆盖正在运行的二进制，且省掉一次中间拷贝
    _ie_missing=''
    for _eb_f in $_eb_files; do
        _ie_src=$(find "$_ie_x" -name "$_eb_f" -type f 2>/dev/null | head -n 1)
        if [ -z "$_ie_src" ]; then
            _ie_missing="$_ie_missing $_eb_f"
            continue
        fi
        if ! verify_executable "$_ie_src" "$_eb_f"; then
            _ie_missing="$_ie_missing $_eb_f"
            continue
        fi
        chmod 0755 "$_ie_src" 2>/dev/null || :
        if ! mv -f "$_ie_src" "$ET_DIR/$_eb_f" 2>/dev/null; then
            warn "$T_BIN_REPLACE_FAIL $ET_DIR/$_eb_f"
        fi
    done
    run rm -rf "$_ie_stage"
    if [ -n "$_ie_missing" ]; then
        err "$T_ET_MISSING$_ie_missing"
        return 1
    fi
    ok "$T_ET_BIN_READY $ET_DIR"
    return 0
}

install_easytier() {
    if [ "$ET_MODE" = off ]; then
        warn "$T_ET_DISABLED"
        return 0
    fi
    step "$T_STEP_ET_INSTALL"
    ensure_et_binaries || return 1

    build_et_args
    dim "$T_CMDLINE $ET_ARGS"
    write_et_service
    start_service "$ET_SERVICE" 'easytier'
    # 至此安装 + 自启动注册完成，脚本不再介入运行期
    return 0
}

write_et_service() {
    # 优先使用官方 easytier-cli service install（自动适配 systemd/OpenRC/launchd/Windows）
    if [ "$SERVICE_MODE" = 'systemd' ] || [ "$SERVICE_MODE" = 'openrc' ]; then
        dim "$T_ET_SVC_OFFICIAL"
        # 参数以 - 开头，故必须用 -- 分隔
        # shellcheck disable=SC2086
        if run "$ET_CLI" service install --core-path "$ET_CORE" --service-work-dir "$ET_DIR" \
               --disable-restart-on-failure false -- $ET_ARGS; then
            return 0
        fi
        warn "$T_ET_SVC_FALLBACK"
    fi

    case "$SERVICE_MODE" in
        systemd)
            run_sh "cat > /etc/systemd/system/${ET_SERVICE}.service <<'UNITEOF'
[Unit]
Description=EasyTier Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${ET_CORE} ${ET_ARGS}
WorkingDirectory=${ET_DIR}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNITEOF"
            run systemctl daemon-reload
            ;;
        openrc)
            run_sh "cat > /etc/init.d/${ET_SERVICE} <<'UNITEOF'
#!/sbin/openrc-run
name=\"EasyTier\"
command=\"${ET_CORE}\"
command_args=\"${ET_ARGS}\"
command_background=true
pidfile=\"/run/${ET_SERVICE}.pid\"
depend() { need net; after network; }
UNITEOF"
            run chmod +x "/etc/init.d/${ET_SERVICE}"
            ;;
        *)
            run_sh "cat > ${ET_DIR}/start.sh <<'UNITEOF'
#!/bin/sh
exec ${ET_CORE} ${ET_ARGS}
UNITEOF"
            run chmod +x "$ET_DIR/start.sh"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# 13. EasyTier Web 控制台（服务端 / web 托管）
#-------------------------------------------------------------------------------
collect_web() {
    step "$T_STEP_WEB_CFG"
    choose "$T_WEB_CHOOSE" "$(case "$WEB_DEPLOY" in docker) echo 2;; none) echo 3;; *) echo 1;; esac)" \
        "$T_WEB_BINARY" \
        "$T_WEB_DOCKER" \
        "$T_WEB_NONE"
    case "$ANS" in
        1) WEB_DEPLOY=binary ;;
        2) WEB_DEPLOY=docker ;;
        3) WEB_DEPLOY=none ;;
    esac
    [ "$WEB_DEPLOY" = none ] && return 1

    ask_text "$T_WEB_PORT" "$WEB_PORT"; WEB_PORT=$ANS
    ask_text "$T_WEB_CFG_PORT" "$WEB_CFG_PORT"; WEB_CFG_PORT=$ANS
    ask_text "$T_WEB_CFG_PROTO" "$WEB_CFG_PROTO"; WEB_CFG_PROTO=$ANS

    _cw_ip=$(local_ip)
    ask_text "$T_WEB_API_HOST" "${WEB_API_HOST:-http://${_cw_ip}:${WEB_PORT}}"
    WEB_API_HOST=$ANS
    return 0
}

install_web() {
    step "$T_STEP_WEB_INSTALL"
    _iw_ip=$(local_ip)

    if [ "$WEB_DEPLOY" = docker ] && ! have docker; then
        warn "$T_WEB_NO_DOCKER"
        WEB_DEPLOY=binary
    fi

    if [ "$WEB_DEPLOY" = docker ]; then
        run mkdir -p "$ET_WEB_DIR"
        run docker run -d --name "$ET_WEB_SERVICE" --restart unless-stopped \
            -p "${WEB_PORT}:${WEB_PORT}" -p "${WEB_CFG_PORT}:${WEB_CFG_PORT}/${WEB_CFG_PROTO}" \
            -v "$ET_WEB_DIR:/app" \
            --entrypoint easytier-web-embed easytier/easytier:latest \
            --api-server-port "$WEB_PORT" --api-host "$WEB_API_HOST" \
            --config-server-port "$WEB_CFG_PORT" --config-server-protocol "$WEB_CFG_PROTO" \
            --db /app/et.db
        ok "$T_WEB_CONTAINER_OK"
    else
        if [ ! -x "$ET_WEB_BIN" ]; then
            info "$T_WEB_NEED_BIN"
            ensure_et_binaries 0 1 || return 1
        fi
        run mkdir -p "$ET_WEB_DIR"
        WEB_ARGS="--api-server-port $WEB_PORT --api-server-addr $WEB_BIND_ADDR"
        WEB_ARGS="$WEB_ARGS --api-host $WEB_API_HOST"
        WEB_ARGS="$WEB_ARGS --config-server-port $WEB_CFG_PORT"
        WEB_ARGS="$WEB_ARGS --config-server-protocol $WEB_CFG_PROTO"
        WEB_ARGS="$WEB_ARGS --db $ET_WEB_DIR/et.db"
        write_web_service
        start_service "$ET_WEB_SERVICE" 'web'
    fi

    hr
    ok "$T_WEB_URL http://${_iw_ip}:${WEB_PORT}"
    info "$T_WEB_REGISTER"
    return 0
}

write_web_service() {
    case "$SERVICE_MODE" in
        systemd)
            run_sh "cat > /etc/systemd/system/${ET_WEB_SERVICE}.service <<'UNITEOF'
[Unit]
Description=EasyTier Web Console
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${ET_WEB_BIN} ${WEB_ARGS}
WorkingDirectory=${ET_WEB_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF"
            run systemctl daemon-reload
            ;;
        openrc)
            run_sh "cat > /etc/init.d/${ET_WEB_SERVICE} <<'UNITEOF'
#!/sbin/openrc-run
name=\"EasyTier Web Console\"
command=\"${ET_WEB_BIN}\"
command_args=\"${WEB_ARGS}\"
command_background=true
pidfile=\"/run/${ET_WEB_SERVICE}.pid\"
depend() { need net; after network; }
UNITEOF"
            run chmod +x "/etc/init.d/${ET_WEB_SERVICE}"
            ;;
        *)
            run_sh "cat > ${ET_WEB_DIR}/start.sh <<'UNITEOF'
#!/bin/sh
exec ${ET_WEB_BIN} ${WEB_ARGS}
UNITEOF"
            run chmod +x "$ET_WEB_DIR/start.sh"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# 13b. 系统信息工具 fastfetch / neofetch
#
#  策略：系统包管理器优先（有发行版集成），拿不到再回退官方发布物。
#    fastfetch : GitHub Releases 的 fastfetch-linux-<arch>.tar.gz（静态二进制）
#    neofetch  : GitHub Archives 的 7.1.0 源码包里的单文件 bash 脚本（需 bash）
#-------------------------------------------------------------------------------
# uname -m -> fastfetch 发布物的架构名
fetch_fastfetch_arch() {
    case "$ARCH_RAW" in
        x86_64|amd64)            echo amd64 ;;
        aarch64|arm64)           echo aarch64 ;;
        armv7l|armv7)            echo armv7l ;;
        armv6l)                  echo armv7l ;;
        i386|i486|i586|i686)     echo i686 ;;
        loongarch64|loong64)     echo loongarch64 ;;
        ppc64le)                 echo ppc64le ;;
        riscv64)                 echo riscv64 ;;
        s390x)                   echo s390x ;;
        *) return 1 ;;
    esac
}

# 用系统包管理器装一个包（静默，失败返回 1；dry-run 只打印）
fetch_pkg_install() {
    _fp_pkg=$1
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s %s %s\n' "$c_ylw" "$c_rst" "$T_FETCH_PKG" "$_fp_pkg"
        return 0
    fi
    dim "$T_FETCH_PKG $_fp_pkg"
    if have apt-get; then apt-get install -y "$_fp_pkg" >/dev/null 2>&1 && return 0
    elif have dnf; then dnf install -y "$_fp_pkg" >/dev/null 2>&1 && return 0
    elif have yum; then yum install -y "$_fp_pkg" >/dev/null 2>&1 && return 0
    elif have zypper; then zypper --non-interactive install "$_fp_pkg" >/dev/null 2>&1 && return 0
    elif have pacman; then pacman -S --noconfirm "$_fp_pkg" >/dev/null 2>&1 && return 0
    elif have apk; then apk add "$_fp_pkg" >/dev/null 2>&1 && return 0
    elif have opkg; then opkg install "$_fp_pkg" >/dev/null 2>&1 && return 0
    elif have brew; then brew install "$_fp_pkg" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# 从官方发布物安装 fastfetch 静态二进制
fetch_fastfetch_bin() {
    _fb_arch=$(fetch_fastfetch_arch) || {
        warn "$T_FETCH_ARCH_UNSUPPORTED $ARCH_RAW"
        return 1
    }
    _fb_ver=$(github_latest_tag 'fastfetch-cli/fastfetch') || {
        err "$T_FETCH_TAG_FAIL fastfetch"
        return 1
    }
    _fb_url="https://github.com/fastfetch-cli/fastfetch/releases/download/${_fb_ver}/fastfetch-linux-${_fb_arch}.tar.gz"
    _fb_tar="${TMP_DIR}/fastfetch.tar.gz"
    dim "$T_FETCH_BIN fastfetch $_fb_ver ($_fb_arch)"
    dl "$_fb_url" "$_fb_tar" 'fastfetch' || return 1
    [ "$DRY_RUN" = 1 ] && return 0

    _fb_dir="${TMP_DIR}/fastfetch.x"
    rm -rf "$_fb_dir"; mkdir -p "$_fb_dir"
    if ! tar xzf "$_fb_tar" -C "$_fb_dir" >/dev/null 2>&1; then
        err "$T_FETCH_UNPACK_FAIL fastfetch"
        return 1
    fi
    _fb_bin=$(find "$_fb_dir" -path '*/usr/bin/fastfetch' -type f 2>/dev/null | head -n 1)
    if [ -z "$_fb_bin" ]; then
        err "$T_FETCH_NO_BIN fastfetch"
        return 1
    fi
    run mkdir -p "$FETCH_BIN_DIR"
    run cp -f "$_fb_bin" "$FETCH_BIN_DIR/fastfetch"
    run chmod 0755 "$FETCH_BIN_DIR/fastfetch"
    # presets/completions（可选）
    _fb_share=$(find "$_fb_dir" -path '*/usr/share/fastfetch' -type d 2>/dev/null | head -n 1)
    if [ -n "$_fb_share" ]; then
        run mkdir -p "$FETCH_SHARE_DIR/fastfetch"
        run cp -Rf "$_fb_share/." "$FETCH_SHARE_DIR/fastfetch/" 2>/dev/null || :
        # 显式放开读/进入权限：安装时的 umask 可能让普通用户读不到 presets
        run chmod -R a+rX "$FETCH_SHARE_DIR/fastfetch" 2>/dev/null || :
    fi
    [ -x "$FETCH_BIN_DIR/fastfetch" ]
}

install_fastfetch() {
    if have fastfetch; then
        info "$T_FETCH_ALREADY fastfetch $(fastfetch --version 2>/dev/null | head -n 1)"
        return 0
    fi
    if fetch_pkg_install fastfetch; then
        if have fastfetch; then return 0; fi
        [ "$DRY_RUN" = 1 ] && return 0
    fi
    fetch_fastfetch_bin
}

install_neofetch() {
    if have neofetch; then
        info "$T_FETCH_ALREADY neofetch"
        return 0
    fi
    if fetch_pkg_install neofetch; then
        if have neofetch; then return 0; fi
        [ "$DRY_RUN" = 1 ] && return 0
    fi
    # neofetch 是 bash 脚本，没有预编译二进制
    if ! have bash; then
        warn "$T_FETCH_NEED_BASH"
        return 1
    fi
    _nb_tar="${TMP_DIR}/neofetch.tar.gz"
    dim "$T_FETCH_BIN neofetch 7.1.0"
    dl "https://github.com/dylanaraps/neofetch/archive/refs/tags/7.1.0.tar.gz" "$_nb_tar" 'neofetch' || return 1
    [ "$DRY_RUN" = 1 ] && return 0

    _nb_dir="${TMP_DIR}/neofetch.x"
    rm -rf "$_nb_dir"; mkdir -p "$_nb_dir"
    if ! tar xzf "$_nb_tar" -C "$_nb_dir" >/dev/null 2>&1; then
        err "$T_FETCH_UNPACK_FAIL neofetch"
        return 1
    fi
    _nb_bin=$(find "$_nb_dir" -maxdepth 2 -name 'neofetch' -type f 2>/dev/null | head -n 1)
    if [ -z "$_nb_bin" ]; then
        err "$T_FETCH_NO_BIN neofetch"
        return 1
    fi
    run mkdir -p "$FETCH_BIN_DIR"
    run cp -f "$_nb_bin" "$FETCH_BIN_DIR/neofetch"
    run chmod 0755 "$FETCH_BIN_DIR/neofetch"
    [ -x "$FETCH_BIN_DIR/neofetch" ]
}

# 安装 MOTD 钩子。
# 依据 komari-agent/terminal/terminal_unix.go 的实现：agent 开远程终端时会先执行
#   for f in /etc/update-motd.d/*; do [ -e "$f" ] && [ -x "$f" ] && "$f"; done
#   [ -r /etc/motd ] && cat /etc/motd
#   exec "$shell"
# 因此把 fastfetch 挂进 /etc/update-motd.d/ 即可同时覆盖「探针 web 终端」与「SSH 登录」。
# 文件必须是可执行位（-x 才被执行）。
fetch_motd_hook() {
    _fm_file="$FETCH_MOTD_DIR/99-fastfetch"
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s write %s (mode 755)\n' "$c_ylw" "$c_rst" "$_fm_file"
        return 0
    fi
    run mkdir -p "$FETCH_MOTD_DIR"
    ( umask 022
      printf '#!/bin/sh\n'
      # 显式带上安装目录：pam_motd / agent 预执行时的 PATH 未必包含它
      printf 'PATH="%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"\n' "$FETCH_BIN_DIR"
      printf 'export PATH\n'
      cat <<'MOTDEOF'
# Installed by cluster-join.sh
# 交互式登录时显示系统信息：SSH 登录 与 Komari 探针 web 终端
# （komari-agent 启动 shell 前会执行 /etc/update-motd.d/ 下所有可执行文件）。
#
# 这里刻意不做 TTY 判断。MOTD 的三种生成路径：
#   1) 交互式登录（stdin/stdout 是终端）
#   2) pam_motd 把 update-motd.d 的输出重定向到管道（多数发行版）
#   3) Debian 由 /etc/init.d/motd 在开机时以 root 生成 /run/motd.dynamic
# 路径 2/3 都没有终端，任何 TTY 守卫都会让输出进不去，
# 表现为「root 在某些入口能看到、普通用户看不到」。
# MOTD 只在登录时被展示，非交互命令的输出会被丢弃，
# 所以这里默认无条件输出（与 fastfetch 官方推荐写法一致）。
#
# 若你希望只在交互式终端里执行（避免 scp / 'ssh host cmd' 也触发），
# 取消下面这行的注释即可：
# [ -t 0 ] || [ -t 1 ] || [ -n "${SSH_TTY:-}" ] || exit 0

for _c in fastfetch neofetch; do
    if command -v "$_c" >/dev/null 2>&1; then
        exec "$_c"
    fi
done
exit 0
MOTDEOF
    ) >"$_fm_file" || { err "$T_FETCH_MOTD_FAIL $_fm_file"; return 1; }
    if [ ! -s "$_fm_file" ]; then
        err "$T_FETCH_MOTD_FAIL $_fm_file"
        return 1
    fi
    run chmod 0755 "$_fm_file"
    if [ ! -x "$_fm_file" ]; then
        err "$T_FETCH_MOTD_FAIL $_fm_file"
        return 1
    fi
    ok "$T_FETCH_MOTD_OK $_fm_file"
    return 0
}

# 安装结果反馈：dry-run 下说「将安装」，避免谎报已装
fetch_report() {
    if [ "$DRY_RUN" = 1 ]; then
        dim "$T_FETCH_WOULD $1"
    else
        ok "$T_FETCH_DONE $1"
    fi
}

# shell rc 钩子：覆盖「非登录交互式 shell」。
# GNOME 终端新开窗口不创建 PAM 会话，pam_motd / update-motd.d 根本不会被执行，
# 所以那种场景只能靠 shell 自己的 rc 文件。
fetch_shellrc_hook() {
    _fs_snip=$FETCH_SHELLRC_SNIP
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s write %s\n' "$c_ylw" "$c_rst" "$_fs_snip"
        printf '%s[dry-run]%s append a source line to existing interactive rc files\n' "$c_ylw" "$c_rst"
        return 0
    fi
    run mkdir -p "$(dirname "$_fs_snip")"
    ( umask 022
      printf '#!/bin/sh\n'
      printf 'PATH="%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"\n' "$FETCH_BIN_DIR"
      printf 'export PATH\n'
      cat <<'RCEOF'
# Installed by cluster-join.sh (--fetch-shellrc)
# 交互式 shell 启动时显示系统信息。放在 rc 里是为了覆盖
# 「非登录交互式 shell」——GNOME 终端新窗口正是这种，
# 它不创建 PAM 会话，因此 pam_motd / update-motd.d 不会被执行。
# 仅交互式 shell 生效；每个会话只显示一次（FASTFETCH_SHOWN 去重）。
case "$-" in
    *i*) ;;
    *) return 0 2>/dev/null || true ;;
esac
if [ -n "${FASTFETCH_SHOWN:-}" ]; then
    return 0 2>/dev/null || true
fi
FASTFETCH_SHOWN=1
export FASTFETCH_SHOWN
for _c in fastfetch neofetch; do
    if command -v "$_c" >/dev/null 2>&1; then
        "$_c"
        break
    fi
done
RCEOF
    ) >"$_fs_snip" || { err "$T_FETCH_SHELLRC_FAIL $_fs_snip"; return 1; }
    [ -s "$_fs_snip" ] || { err "$T_FETCH_SHELLRC_FAIL $_fs_snip"; return 1; }
    run chmod 0644 "$_fs_snip"
    # 让非登录交互式 shell 也跑到：往已存在的 rc 文件追加一行 source
    for _fs_rc in $FETCH_SHELLRC_RCS; do
        [ -f "$_fs_rc" ] || continue
        if grep -q 'cluster-join fetch snippet' "$_fs_rc" 2>/dev/null; then
            dim "$T_FETCH_SHELLRC_PRESENT $_fs_rc"
            continue
        fi
        # 改系统文件前先备份一次
        if [ ! -f "$_fs_rc.cluster-join.bak" ]; then
            run cp -a "$_fs_rc" "$_fs_rc.cluster-join.bak" || :
        fi
        ( umask 022
          printf '\n# cluster-join fetch snippet\n'
          printf '[ -f %s ] && . %s\n' "$_fs_snip" "$_fs_snip"
        ) >>"$_fs_rc" || { warn "$T_FETCH_SHELLRC_FAIL $_fs_rc"; continue; }
        ok "$T_FETCH_SHELLRC_RC $_fs_rc"
    done
    ok "$T_FETCH_SHELLRC_OK $_fs_snip"
    return 0
}

# 卸载时清理两个登录钩子（原先完全没有清理，会留下悬空引用）
fetch_hooks_remove() {
    run rm -f "$FETCH_MOTD_DIR/99-fastfetch"
    run rm -f "$FETCH_SHELLRC_SNIP"
    for _fr_rc in $FETCH_SHELLRC_RCS; do
        [ -f "$_fr_rc" ] || continue
        grep -q 'cluster-join fetch snippet' "$_fr_rc" 2>/dev/null || continue
        # 删掉「# cluster-join fetch snippet」标记行与其后紧跟的 source 行
        if have sed; then
            sed -i.cluster-join.tmp '/# cluster-join fetch snippet/{N;d;}' "$_fr_rc" 2>/dev/null || :
            rm -f "$_fr_rc.cluster-join.tmp" 2>/dev/null || :
        fi
        ok "$T_FETCH_SHELLRC_REMOVED $_fr_rc"
    done
    return 0
}

install_fetch() {
    step "$T_STEP_FETCH"
    _if_tool=''
    case "$FETCH_TOOL" in
        ''|auto)
            if install_fastfetch; then
                _if_tool=fastfetch
            else
                warn "$T_FETCH_FALLBACK"
                if install_neofetch; then _if_tool=neofetch; fi
            fi
            ;;
        fastfetch)
            if install_fastfetch; then _if_tool=fastfetch; fi
            ;;
        neofetch)
            if install_neofetch; then _if_tool=neofetch; fi
            ;;
        *)
            die "$T_FETCH_TOOL_BAD $FETCH_TOOL"
            ;;
    esac
    if [ -z "$_if_tool" ]; then
        err "$T_FETCH_FAIL $FETCH_TOOL"
        return 1
    fi
    fetch_report "$_if_tool"
# 让它在登录时真正显示（探针 web 终端 + SSH），而不只是躺在 PATH 里
    if [ "$FETCH_MOTD" = 1 ]; then
        fetch_motd_hook || :
    fi
    if [ "$FETCH_SHELLRC" = 1 ]; then
        fetch_shellrc_hook || :
    fi
    return 0
}

#-------------------------------------------------------------------------------
# 14. 服务启停抽象
#-------------------------------------------------------------------------------
service_enable() {
    _se_name=$1
    case "$SERVICE_MODE" in
        systemd) run systemctl enable "$_se_name" >/dev/null 2>&1 ;;
        openrc)  run rc-update add "$_se_name" default >/dev/null 2>&1 ;;
        procd)   run_sh "/etc/init.d/$_se_name enable >/dev/null 2>&1 || true" ;;
        *)       : ;;
    esac
}

service_restart() {
    _sr_name=$1
    case "$SERVICE_MODE" in
        systemd) run systemctl restart "$_sr_name" ;;
        openrc)  run rc-service "$_sr_name" restart ;;
        procd)   run_sh "/etc/init.d/$_sr_name restart" ;;
        *)       service_manual_restart "$_sr_name" ;;
    esac
}

service_stop() {
    _ss_name=$1
    case "$SERVICE_MODE" in
        systemd) run systemctl stop "$_ss_name" >/dev/null 2>&1 || : ;;
        openrc)  run rc-service "$_ss_name" stop >/dev/null 2>&1 || : ;;
        procd)   run_sh "/etc/init.d/$_ss_name stop >/dev/null 2>&1 || true" ;;
        *)       service_manual_stop "$_ss_name" ;;
    esac
}

service_disable() {
    _sd_name=$1
    case "$SERVICE_MODE" in
        systemd) run systemctl disable "$_sd_name" >/dev/null 2>&1 || : ;;
        openrc)  run rc-update del "$_sd_name" default >/dev/null 2>&1 || : ;;
        procd)   run_sh "/etc/init.d/$_sd_name disable >/dev/null 2>&1 || true" ;;
        *)       : ;;
    esac
}

service_active() {
    _sa_name=$1
    case "$SERVICE_MODE" in
        systemd) systemctl is-active --quiet "$_sa_name" 2>/dev/null ;;
        openrc)  rc-service "$_sa_name" status >/dev/null 2>&1 ;;
        procd)   "/etc/init.d/$_sa_name" status >/dev/null 2>&1 ;;
        *)       service_manual_active "$_sa_name" ;;
    esac
}

# manual 模式：nohup 启动 + pid 文件
_manual_pidfile() {
    # 用真实写入测试挑目录：[ -w ] 在沙箱 / 只读文件系统下会误判
    for _mp_dir in /run /var/run /tmp; do
        if ( umask 077; : >"$_mp_dir/.${APP_NAME}.wtest.$$" ) 2>/dev/null; then
            rm -f "$_mp_dir/.${APP_NAME}.wtest.$$" 2>/dev/null || :
            printf '%s/%s.pid' "$_mp_dir" "$1"
            return 0
        fi
    done
    printf '%s/%s.pid' "${TMP_DIR:-/tmp}" "$1"
}

_manual_bin_for() {
    case "$1" in
        "$KOMARI_SERVICE") echo "$KOMARI_BIN|$KOMARI_ARGS" ;;
        "$ET_SERVICE")     echo "$ET_CORE|$ET_ARGS" ;;
        "$ET_WEB_SERVICE") echo "$ET_WEB_BIN|$WEB_ARGS" ;;
        *) echo '' ;;
    esac
}

service_manual_active() {
    _sma_pf=$(_manual_pidfile "$1")
    [ -f "$_sma_pf" ] || return 1
    _sma_pid=$(cat "$_sma_pf" 2>/dev/null)
    [ -n "$_sma_pid" ] || return 1
    kill -0 "$_sma_pid" 2>/dev/null
}

service_manual_stop() {
    _sms_pf=$(_manual_pidfile "$1")
    if [ -f "$_sms_pf" ]; then
        _sms_pid=$(cat "$_sms_pf" 2>/dev/null)
        if [ -n "$_sms_pid" ]; then kill "$_sms_pid" 2>/dev/null || :; fi
        rm -f "$_sms_pf"
    fi
}

service_manual_restart() {
    _smr_pair=$(_manual_bin_for "$1")
    if [ -z "$_smr_pair" ]; then
        warn "$T_SVC_UNKNOWN_MANUAL $1"
        return 1
    fi
    _smr_bin=${_smr_pair%%|*}
    _smr_args=${_smr_pair#*|}
    service_manual_stop "$1"
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s[dry-run]%s nohup %s %s &\n' "$c_ylw" "$c_rst" "$_smr_bin" "$_smr_args"
        return 0
    fi
    # shellcheck disable=SC2086
    nohup "$_smr_bin" $_smr_args >>"${LOG_FILE:-/var/log/cluster-join.log}" 2>&1 &
    _smr_pid=$!
    _smr_pf=$(_manual_pidfile "$1")
    if echo "$_smr_pid" >"$_smr_pf" 2>/dev/null; then
        dim "$T_SVC_NOHUP $1 ($T_SVC_PID $_smr_pid)"
    else
        dim "$T_SVC_NOHUP $1 ($T_SVC_PID $_smr_pid, $T_SVC_PIDFILE_FAIL $_smr_pf)"
    fi
}

start_service() {
    _st_name=$1
    _st_label=$2
    service_enable "$_st_name"
    service_restart "$_st_name"
    dim "$T_SVC_RESTARTED $(_svc_display "$_st_label")"
}

_svc_display() {
    case "$1" in
        komari)   echo 'Komari Agent' ;;
        easytier) echo 'EasyTier' ;;
        web)      echo 'EasyTier Web Console' ;;
        *)        echo "$1" ;;
    esac
}

#-------------------------------------------------------------------------------
# 15. 状态查看
#-------------------------------------------------------------------------------
do_status() {
    alt_screen_leave
    step "$T_STEP_STATUS"
    printf '%s%-18s %-22s %s%s\n' "$c_bold" "$T_ST_COMPONENT" "$T_ST_SERVICE" "$T_ST_STATUS" "$c_rst"
    hr
    _st_k=$T_ST_STOPPED
    service_active "$KOMARI_SERVICE" && _st_k=$T_ST_RUNNING
    printf '%-18s %-22s %s\n' 'Komari Agent' "$KOMARI_SERVICE" "$_st_k"
    _st_e=$T_ST_STOPPED
    service_active "$ET_SERVICE" && _st_e=$T_ST_RUNNING
    printf '%-18s %-22s %s\n' 'EasyTier' "$ET_SERVICE" "$_st_e"
    _st_w=$T_ST_STOPPED
    service_active "$ET_WEB_SERVICE" && _st_w=$T_ST_RUNNING
    printf '%-18s %-22s %s\n' 'EasyTier Web' "$ET_WEB_SERVICE" "$_st_w"
    hr

    if [ -x "$ET_CLI" ] && [ "$_st_e" = "$T_ST_RUNNING" ]; then
        printf '\n%s%s%s\n' "$c_bold" "$T_ST_ET_PEERS" "$c_rst"
        "$ET_CLI" peer 2>/dev/null || dim "$T_ST_NO_PEER"
        printf '\n%s%s%s\n' "$c_bold" "$T_ST_ET_NODE" "$c_rst"
        "$ET_CLI" node 2>/dev/null || :
    fi

    if have ip; then
        printf '\n%s%s%s\n' "$c_bold" "$T_ST_IFACES" "$c_rst"
        ip -o -4 addr show 2>/dev/null | grep -E 'tun|easytier|utun' || dim "$T_ST_NO_IFACE"
    fi

    printf '\n%s%s%s\n' "$c_bold" "$T_ST_PORTS" "$c_rst"
    if have ss; then
        ss -lntup 2>/dev/null | grep -E ':(11010|11011|11012|11013|11211|22020|25774)\b' || dim "$T_ST_NO_PORT"
    elif have netstat; then
        netstat -lntup 2>/dev/null | grep -E ':(11010|11011|11211|22020|25774)\b' || dim "$T_ST_NO_PORT"
    else
        dim "$T_ST_NO_SS"
    fi

    printf '\n%s%s%s\n' "$c_bold" "$T_ST_LOGS" "$c_rst"
    if [ "$SERVICE_MODE" = systemd ]; then
        systemctl --no-pager -n 8 status "$ET_SERVICE" 2>/dev/null | tail -n 8 || :
    else
        tail -n 8 "${LOG_FILE:-/var/log/cluster-join.log}" 2>/dev/null || dim "$T_ST_NO_LOG"
    fi
    hr
}

#-------------------------------------------------------------------------------
# 16. 卸载
#-------------------------------------------------------------------------------
do_uninstall() {
    alt_screen_leave
    step "$T_STEP_UNINSTALL $UNINSTALL_TARGET)"
    if ! confirm_or_die "$T_CONFIRM_UNINSTALL"; then
        return 1
    fi

    fetch_hooks_remove

    case "$UNINSTALL_TARGET" in
        all|komari)
            service_stop "$KOMARI_SERVICE"; service_disable "$KOMARI_SERVICE"
            run rm -f "/etc/systemd/system/${KOMARI_SERVICE}.service"
            run rm -f "/etc/init.d/${KOMARI_SERVICE}"
            run rm -f "$KOMARI_BIN"
            run rm -f "$KOMARI_DIR/start.sh"
            ok "$T_UNINSTALLED $T_LABEL_KOMARI"
            ;;
    esac
    case "$UNINSTALL_TARGET" in
        all|easytier)
            if [ -x "$ET_CLI" ]; then run "$ET_CLI" service uninstall >/dev/null 2>&1 || :; fi
            service_stop "$ET_SERVICE"; service_disable "$ET_SERVICE"
            run rm -f "/etc/systemd/system/${ET_SERVICE}.service"
            run rm -f "/etc/init.d/${ET_SERVICE}"
            ok "$T_UNINSTALLED EasyTier"
            ;;
    esac
    case "$UNINSTALL_TARGET" in
        all|web)
            service_stop "$ET_WEB_SERVICE"; service_disable "$ET_WEB_SERVICE"
            run rm -f "/etc/systemd/system/${ET_WEB_SERVICE}.service"
            run rm -f "/etc/init.d/${ET_WEB_SERVICE}"
            if have docker; then run docker rm -f "$ET_WEB_SERVICE" >/dev/null 2>&1 || :; fi
            ok "$T_UNINSTALLED EasyTier Web Console"
            ;;
    esac

    if [ "$SERVICE_MODE" = systemd ]; then run systemctl daemon-reload; fi

    if [ "$UNINSTALL_PURGE" = 1 ]; then
        case "$UNINSTALL_TARGET" in
            all|komari)   run rm -rf "$KOMARI_DIR" ;;
        esac
        case "$UNINSTALL_TARGET" in
            all|easytier) run rm -rf "$ET_DIR" ;;
        esac
        case "$UNINSTALL_TARGET" in
            all|web)      run rm -rf "$ET_WEB_DIR" ;;
        esac
        run rm -f "$CONF_FILE"
        ok "$T_PURGED"
    else
        info "$T_KEPT"
        dim "$T_PATHS Komari=$KOMARI_DIR  EasyTier=$ET_DIR  conf=$CONF_FILE"
    fi
    return 0
}

#-------------------------------------------------------------------------------
# 17. 输出标准下发命令（供 cluster-batch.sh / 人工复制）
#-------------------------------------------------------------------------------
emit_cmd() {
    alt_screen_leave
    _ec='sudo sh cluster-join.sh --all --yes'
    [ -n "$KOMARI_ENDPOINT" ] && _ec="$_ec --komari-endpoint '$KOMARI_ENDPOINT'"
    if [ -n "$KOMARI_AD_KEY" ]; then
        _ec="$_ec --komari-ad-key '$KOMARI_AD_KEY'"
    elif [ -n "$KOMARI_TOKEN" ]; then
        _ec="$_ec --komari-token '$KOMARI_TOKEN'"
    fi
    [ "$KOMARI_DISABLE_WEB_SSH" = 1 ] && _ec="$_ec --komari-no-web-ssh"
    [ -n "$KOMARI_INTERVAL" ] && _ec="$_ec --komari-interval $KOMARI_INTERVAL"
    _ec="$_ec --et-mode $ET_MODE"
    case "$ET_MODE" in
        off) : ;;
        web)
            [ -n "$ET_CONFIG_SERVER" ] && _ec="$_ec --et-config-server '$ET_CONFIG_SERVER'"
            [ -n "$ET_MACHINE_ID" ] && _ec="$_ec --et-machine-id '$ET_MACHINE_ID'"
            ;;
        peer)
            _ec="$_ec --et-network-name '$ET_NETWORK_NAME' --et-network-secret '$ET_NETWORK_SECRET'"
            [ -n "$ET_PEERS" ] && _ec="$_ec --et-peers '$ET_PEERS'"
            if [ -n "$ET_IPV4" ]; then
                _ec="$_ec --et-ip $ET_IPV4"
            else
                _ec="$_ec --et-dhcp"
            fi
            ;;
        server)
            [ -n "$ET_IPV4" ] && _ec="$_ec --et-ip $ET_IPV4"
            ;;
    esac
    [ -n "$GH_PROXY" ] && _ec="$_ec --gh-proxy '$GH_PROXY'"

    # 管道形式（配合 cluster-batch.sh 或 curl 下发）
    _ec_pipe=$(printf '%s' "$_ec" | sed "s#^sudo sh cluster-join.sh##")

    hr
    printf '%s%s%s\n' "$c_bold" "$T_EMIT_1" "$c_rst"
    printf '   %s\n' "$_ec"
    hr
    printf '%s%s%s\n' "$c_bold" "$T_EMIT_2" "$c_rst"
    printf '   curl -fsSL <script-url> | sudo sh -s --%s\n' "$_ec_pipe"
    hr
    return 0
}

#-------------------------------------------------------------------------------
# 18. 交互式菜单
#-------------------------------------------------------------------------------
# 让用户读完输出再回主菜单。
# 菜单在备用屏里，直接重绘会把刚打印在正常屏上的内容盖住——必须给一次暂停。
press_enter() {
    [ "$INTERACTIVE" = 1 ] || return 0
    printf '\n'
    _wr "$T_PRESS_ENTER"
    read_line || :
    printf '\n'
    return 0
}

# 显示当前值：空显示「未设置」，密钥只显示首尾
pm_show() {
    if [ -z "$1" ]; then
        printf '%s' "$T_PM_NONE"
    elif [ "$2" = 1 ]; then
        _mask_hint "$1" 1
    else
        printf '%s' "$1"
    fi
}

# 网络与代理设置（gh-proxy / 正向代理 / Resin 反向代理），改完立即生效并存档
proxy_menu() {
    while :; do
        printf '\n'
        hr
        printf '%s  %s%s\n' "$c_bold" "$T_PM_TITLE" "$c_rst"
        hr
        printf '  %s1)%s %s  %s[%s]%s\n' "$c_cyn" "$c_rst" "$T_PM_GH" "$c_dim" "$(pm_show "$GH_PROXY" 0)" "$c_rst"
        if [ "$NO_GH_PROXY" = 1 ]; then
            printf '  %s2)%s %s  %s[%s]%s\n' "$c_cyn" "$c_rst" "$T_PM_MIRROR" "$c_dim" "$T_PM_OFF" "$c_rst"
        else
            printf '  %s2)%s %s  %s[%s]%s\n' "$c_cyn" "$c_rst" "$T_PM_MIRROR" "$c_dim" "$T_PM_ON" "$c_rst"
        fi
        printf '  %s3)%s %s  %s[%s]%s\n' "$c_cyn" "$c_rst" "$T_PM_PROXY" "$c_dim" "$(pm_show "$PROXY_URL" 0)" "$c_rst"
        printf '  %s4)%s %s  %s[%s]%s\n' "$c_cyn" "$c_rst" "$T_PM_PROXY_AUTH" "$c_dim" "$(pm_show "$PROXY_AUTH" 1)" "$c_rst"
        printf '  %s5)%s %s  %s[%s]%s\n' "$c_cyn" "$c_rst" "$T_PM_RESIN" "$c_dim" "$(pm_show "$RESIN_URL" 0)" "$c_rst"
        printf '  %s6)%s %s  %s[%s]%s\n' "$c_cyn" "$c_rst" "$T_PM_RESIN_TOKEN" "$c_dim" "$(pm_show "$RESIN_TOKEN" 1)" "$c_rst"
        printf '  %s7)%s %s  %s[%s]%s\n' "$c_cyn" "$c_rst" "$T_PM_RESIN_ACCOUNT" "$c_dim" "$(pm_show "$RESIN_ACCOUNT" 0)" "$c_rst"
        printf '  %s8)%s %s\n' "$c_cyn" "$c_rst" "$T_PM_CLEAR"
        printf '  %s0)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_BACK"
        hr
        if ! ask_text "$T_SELECT" '0'; then
            return 0
        fi
        case "$ANS" in
            1) ask_text "$T_PM_GH" "$GH_PROXY"; GH_PROXY=$ANS ;;
            2) ask_yesno "$T_PM_MIRROR" "$([ "$NO_GH_PROXY" = 1 ] && echo n || echo y)"
               if [ "$ANS" = y ]; then NO_GH_PROXY=0; else NO_GH_PROXY=1; fi ;;
            3) ask_text "$T_PM_PROXY" "$PROXY_URL"; PROXY_URL=$ANS ;;
            4) ask_text "$T_PM_PROXY_AUTH" "$PROXY_AUTH" 1; PROXY_AUTH=$ANS ;;
            5) ask_text "$T_PM_RESIN" "$RESIN_URL"; RESIN_URL=$ANS ;;
            6) ask_text "$T_PM_RESIN_TOKEN" "$RESIN_TOKEN" 1; RESIN_TOKEN=$ANS ;;
            7) ask_text "$T_PM_RESIN_ACCOUNT" "$RESIN_ACCOUNT"; RESIN_ACCOUNT=$ANS ;;
            8) ask_yesno "$T_PM_CLEAR" 'n'
               if [ "$ANS" = y ]; then
                   GH_PROXY=''; NO_GH_PROXY=0
                   PROXY_URL=''; PROXY_AUTH=''
                   RESIN_URL=''; RESIN_TOKEN=''; RESIN_ACCOUNT=''
                   info "$T_PM_CLEARED"
               fi ;;
            0|q|Q) return 0 ;;
            *) warn "$T_PM_BAD" ;;
        esac
        build_proxy_args     # 立即生效，不必等下次运行
        save_conf || :
        dim "$T_PM_SAVED"
    done
}

# 手动切换消息语言。默认策略是「TTY 一律英文」，这里是给它的显式出口：
# 只影响本次运行，不写入参数存档，也就不会和自动策略打架。
lang_switch_menu() {
    if [ "$MSG_LANG" = zh ]; then
        choose "$T_LANG_CHOOSE" 2 'English' '中文'
    else
        choose "$T_LANG_CHOOSE" 1 'English' '中文'
    fi
    case "$ANS" in
        1) MSG_LANG=en ;;
        2) MSG_LANG=zh ;;
        *) return 0 ;;
    esac
    lang_load
    if [ "$MSG_LANG" = zh ]; then
        info "$T_LANG_SWITCHED 中文"
    else
        info "$T_LANG_SWITCHED English"
    fi
    dim "$T_LANG_SESSION_ONLY"
    return 0
}

interactive_loop() {
    while :; do
        alt_screen_enter
        printf '\n'
        hr
        printf '%s  %s%s\n' "$c_bold" "$T_HR_TITLE_MAIN" "$c_rst"
        hr
        printf '  %s1)%s %s  %s%s%s\n' "$c_cyn" "$c_rst" "$T_MENU_1" "$c_dim" "$T_MENU_RECOMMENDED" "$c_rst"
        printf '  %s2)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_2"
        printf '  %s3)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_3"
        printf '  %s4)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_4"
        printf '  %s5)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_5"
        printf '  %s6)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_6"
        printf '  %s7)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_7"
        printf '  %s8)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_8"
        printf '  %s9)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_9"
        printf '  %s10)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_10"
        printf '  %s0)%s %s\n' "$c_cyn" "$c_rst" "$T_MENU_0"
        hr
        if ! ask_text "$T_SELECT" '1'; then
            printf '\n'
            info "$T_EOF_MENU"
            return 0
        fi
        # 先退出备用屏再执行动作：这样安装日志、状态、汇总都留在正常屏上，
        # 退出脚本后仍可在 scrollback 里翻到；下一次循环再切回菜单面板。
        alt_screen_leave
        case "$ANS" in
            1) ACTION='all';        run_action; save_conf; press_enter ;;
            2) ACTION='komari';     run_action; save_conf; press_enter ;;
            3) ACTION='easytier';   run_action; save_conf; press_enter ;;
            4) ACTION='web';        run_action; save_conf; press_enter ;;
            5) do_status; press_enter ;;
            6) emit_cmd; press_enter ;;
            7) do_uninstall; press_enter ;;
            8) ACTION='fetch'; run_action; save_conf; press_enter ;;
            9) lang_switch_menu ;;
            10) proxy_menu ;;
            0|q|Q|quit|exit) info "$T_BYE"; return 0 ;;
            *) warn "$T_BAD_CHOICE" ;;
        esac
        ACTION='auto'
    done
}

#-------------------------------------------------------------------------------
# 19. 动作分发
#-------------------------------------------------------------------------------
run_action() {
    # 刻意不切备用屏：安装日志要留在正常屏的 scrollback 里。
    # 备用屏只用于「菜单面板」本身，否则动作输出会随退出备用屏一起消失。
    alt_screen_leave
    case "$ACTION" in
        all)
            preflight
            if [ "$NO_ET" != 1 ]; then
                collect_easytier && install_easytier
                # 组网先通，再上报监控（面板若在虚拟网内则需要此顺序）
            fi
            if [ "$NO_KOMARI" != 1 ]; then
                collect_komari && install_komari
            fi
            fetch_after_join
            print_summary
            ;;
        easytier)
            preflight
            collect_easytier && install_easytier
            fetch_after_join
            print_summary
            ;;
        komari)
            preflight
            collect_komari && install_komari
            fetch_after_join
            print_summary
            ;;
        web)
            preflight
            collect_web && install_web
            ;;
        fetch)
            preflight
            install_fetch
            ;;
        status)    do_status ;;
        uninstall) do_uninstall ;;
        emit)      emit_cmd ;;
        *)         usage ;;
    esac
}

# --with-fetch：并网动作成功后追加安装系统信息工具
fetch_after_join() {
    if [ "$WITH_FETCH" = 1 ]; then
        install_fetch
    fi
    return 0
}

print_summary() {
    # 汇总要留在 scrollback 里给用户看，先退出备用屏
    alt_screen_leave
    printf '\n'
    hr
    ok "$T_SUMMARY_DONE"
    if [ -n "$KOMARI_ENDPOINT" ]; then
        dim "$T_SUMMARY_PANEL $KOMARI_ENDPOINT"
        if [ "$KOMARI_DISABLE_WEB_SSH" != 1 ]; then
            dim "$T_SUMMARY_REMOTE_ON"
        fi
    fi
    case "$ET_MODE" in
        web)    dim "$T_SUMMARY_ET_WEB $ET_CONFIG_SERVER" ;;
        peer)   dim "$T_SUMMARY_ET_PEER $ET_NETWORK_NAME  $T_SUMMARY_ET_PEER2 $ET_PEERS" ;;
        server) dim "$T_SUMMARY_ET_SERVER $ET_IPV4  $T_SUMMARY_ET_SERVER2 ${ET_LISTEN_PORT:-11010}" ;;
        off)    dim "$T_SUMMARY_ET_OFF" ;;
    esac
    hr
}

#-------------------------------------------------------------------------------
# 20. 入口
#-------------------------------------------------------------------------------
cleanup() {
    _stty_echo_on
    alt_screen_leave
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" 2>/dev/null || :
    fi
}

main() {
    # 先探测终端与语言（均无输出），保证之后所有消息语言正确
    detect_tty
    lang_init

    parse_args "$@"

    if [ "${CLUSTER_JOIN_YES:-0}" = 1 ]; then
        ASSUME_YES=1
    fi

    # 交互判定：有终端 + 未强制 yes + 动作需要交互
    # CLUSTER_JOIN_FORCE_INTERACTIVE=1 可在无终端时改为从标准输入读取答案（便于 heredoc/expect 驱动）
    if [ "$HAVE_TTY" = 1 ] && [ "$ASSUME_YES" != 1 ]; then
        case "$ACTION" in
            status|uninstall|emit|help) INTERACTIVE=0 ;;
            *) INTERACTIVE=1 ;;
        esac
    elif [ "${CLUSTER_JOIN_FORCE_INTERACTIVE:-0}" = 1 ] && [ "$ASSUME_YES" != 1 ]; then
        case "$ACTION" in
            status|uninstall|emit|help) INTERACTIVE=0 ;;
            *) INTERACTIVE=1 ;;
        esac
    else
        INTERACTIVE=0
    fi

    TMP_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/${APP_NAME}.$$")
    [ -d "$TMP_DIR" ] || mkdir -p "$TMP_DIR" 2>/dev/null || TMP_DIR='/tmp'
    trap 'cleanup' EXIT
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM

    if [ "$LOG_TO_FILE" != 1 ]; then
        # 用真实写入测试代替权限位判断（沙箱/只读文件系统下 -w 可能不准）
        if ( umask 077; : >>"$LOG_FILE" ) 2>/dev/null; then
            LOG_TO_FILE=1
        fi
    fi

    banner
    load_conf
    apply_defaults

    case "$ACTION" in
        help) usage; return 0 ;;
    esac

    require_root "$@"
    detect_os_arch

    case "$ACTION" in
        auto)
            if [ "$INTERACTIVE" = 1 ]; then
                interactive_loop
            elif [ "$HAVE_TTY" != 1 ] && [ -z "$KOMARI_ENDPOINT" ] && [ -z "$ET_CONFIG_SERVER" ] && [ -z "$ET_NETWORK_NAME" ]; then
                err "$T_ERR_NO_CONF"
                printf '\n'
                usage
                return 1
            else
                ACTION='all'; run_action
                save_conf || :   # 存档写不了只警告，不影响退出码
            fi
            ;;
        menu)
            if [ "$INTERACTIVE" != 1 ]; then
                err "$T_ERR_MENU_TTY"
                return 1
            fi
            interactive_loop
            ;;
        status)    do_status ;;
        uninstall) do_uninstall ;;
        emit)      emit_cmd ;;
        *)
            run_action
            save_conf || :   # 存档写不了只警告，不影响退出码
            ;;
    esac
}

main "$@"
