#!/bin/sh
set -eu
set -o pipefail
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

PORT=54321
DIR=/etc/hysteria
CONFIG=$DIR/config.yaml
CERT=$DIR/server.crt
KEY=$DIR/server.key
INFO=$DIR/connection.txt
BIN=/usr/local/bin/hysteria
SERVICE=/etc/init.d/hysteria
MANAGER=/usr/local/bin/hy2
STAGED=

RESET= BOLD= BLUE= GREEN= YELLOW= RED=
if [ -t 2 ] && [ "${TERM:-dumb}" != dumb ] && [ "${NO_COLOR+x}" != x ]; then
    RESET=$(printf '\033[0m')
    BOLD=$(printf '\033[1m')
    BLUE=$(printf '\033[36m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    RED=$(printf '\033[31m')
fi

step() {
    printf '\n%s[%s/5]%s %s\n' "$BLUE" "$1" "$RESET" "$2" >&2
}

success() {
    printf '%s[完成]%s %s\n' "$GREEN" "$RESET" "$*" >&2
}

warn() {
    printf '%s[提示]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

fail() {
    printf '\n%s[错误]%s %s\n' "$RED" "$RESET" "$*" >&2
    exit 1
}

cleanup() {
    [ -z "$STAGED" ] || rm -f "$STAGED"
}

trap cleanup 0
trap 'exit 1' HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail '请使用 root 运行'
[ -f /etc/alpine-release ] || fail '仅支持 Alpine Linux'

PID1=$(cat /proc/1/comm 2>/dev/null || true)

case "$PID1" in
    sh|ash|bash|dash)
        fail "PID 1 为 ${PID1}，请使用具有子进程回收能力的 init"
        ;;
esac

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) fail "不支持的 CPU 架构：$(uname -m)" ;;
esac

printf '\n%sHysteria 2 · Alpine 安装%s\n' "$BOLD" "$RESET" >&2
printf '%s\n' '----------------------------------------' >&2
printf '  系统架构  %s\n  监听端口  %s / UDP\n' "$ARCH" "$PORT" >&2

step 1 '安装依赖并准备运行环境'
apk add --no-cache openrc wget openssl ca-certificates >/dev/null 2>&1 || fail '依赖安装失败'
command -v rc-service >/dev/null 2>&1 || fail 'OpenRC 安装失败'
command -v supervise-daemon >/dev/null 2>&1 || fail '找不到 supervise-daemon'

# 兼容 cgroup 不可写的容器
if [ ! -w /sys/fs/cgroup ]; then
    [ -f /etc/rc.conf ] || : > /etc/rc.conf

    if grep -q '^[[:space:]]*rc_cgroup_mode=' /etc/rc.conf; then
        sed -i 's/^[[:space:]]*rc_cgroup_mode=.*/rc_cgroup_mode="none"/' /etc/rc.conf
    else
        printf '\nrc_cgroup_mode="none"\n' >> /etc/rc.conf
    fi
fi

# 兼容运行中才安装 OpenRC 的环境
mkdir -p /run/openrc

if [ ! -s /run/openrc/softlevel ]; then
    printf 'default\n' > /run/openrc/softlevel
fi

EXISTING=0

if [ -e "$CONFIG" ] || [ -e "$CERT" ] ||
   [ -e "$KEY" ] || [ -e "$INFO" ]; then

    [ -f "$CONFIG" ] &&
    [ -f "$CERT" ] &&
    [ -f "$KEY" ] &&
    [ -f "$INFO" ] \
        || fail "检测到不完整的安装：${DIR}"

    EXISTING=1
fi

success '运行环境已就绪'
step 2 '下载 Hysteria 2 内核，请稍候'
mkdir -p "$DIR" /usr/local/bin

STAGED="/usr/local/bin/.hysteria.new.$$"

wget -qO- -T 180 -t 3 \
    "https://github.com/HyNetworks/hysteria/releases/latest/download/hysteria-linux-${ARCH}" \
    | install -m 755 /dev/stdin "$STAGED" \
    || fail 'Hysteria 下载失败'

"$STAGED" version >/dev/null 2>&1 || fail 'Hysteria 二进制无法运行'
success '内核下载及运行检查通过'

step 3 '准备证书和连接配置'
if [ "$EXISTING" -eq 0 ]; then
    IP=${HY2_IP:-}

    if [ -z "$IP" ]; then
        IP=$(wget -qO- -T 10 -t 1 https://api.ipify.org 2>/dev/null | tr -d '\r\n' || true)
        [ -n "$IP" ] ||
            IP=$(wget -qO- -T 10 -t 1 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)
        [ -n "$IP" ] ||
            IP=$(wget -qO- -T 10 -t 1 https://api6.ipify.org 2>/dev/null | tr -d '\r\n' || true)
    fi

    [ -n "$IP" ] || fail '无法获取公网 IP，请使用 HY2_IP 指定'

    case "$IP" in
        *:*) HOST="[$IP]" ;;
        *[!0-9.]*|'') fail "公网 IP 格式无效：${IP}" ;;
        *) HOST="$IP" ;;
    esac

    openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:P-256 \
        -nodes -sha256 -days 3650 \
        -subj "/CN=${IP}" \
        -addext "subjectAltName=IP:${IP}" \
        -keyout "$KEY" \
        -out "$CERT" \
        >/dev/null 2>&1 \
        || fail '生成自签名证书失败'

    PASSWORD=$(openssl rand -hex 16)

    PIN=$(openssl x509 \
        -in "$CERT" \
        -noout -fingerprint -sha256 |
        sed 's/.*=//')

    [ -n "$PIN" ] || fail '读取证书指纹失败'

    cat > "$CONFIG" <<EOF
listen: :${PORT}

tls:
  cert: ${CERT}
  key: ${KEY}
  sniGuard: disable

auth:
  type: password
  password: "${PASSWORD}"

masquerade:
  type: proxy
  proxy:
    url: https://music.apple.com
    rewriteHost: true
EOF

    URI="hy2://${PASSWORD}@${HOST}:${PORT}/?insecure=1&pinSHA256=${PIN}#HY2-Alpine"
    success '已生成证书和连接配置'

else
    URI=$(head -n 1 "$INFO")

    case "$URI" in
        hy2://*@*/*|hysteria2://*@*/*) ;;
        *) fail '原连接地址无效' ;;
    esac

    REST=${URI#*@}
    ADDRESS=${REST%%/*}
    HOST=${ADDRESS%:*}

    [ "$HOST" != "$ADDRESS" ] ||
        fail '原连接地址缺少端口'

    URI="${URI%%@*}@${HOST}:${PORT}/${REST#*/}"

    grep -q '^listen:' "$CONFIG" ||
        fail '原配置缺少 listen 字段'

    sed -i "s/^listen:.*/listen: :${PORT}/" "$CONFIG"
    success '已更新配置，保留原有证书和密码'
fi

printf '%s\n' "$URI" > "$INFO"

chmod 700 "$DIR"
chmod 600 "$CONFIG" "$KEY" "$INFO"
chmod 644 "$CERT"

step 4 '安装内核和管理命令'
if [ -f "$SERVICE" ] &&
   rc-service hysteria status >/dev/null 2>&1; then

    rc-service hysteria stop >/dev/null 2>&1 ||
        fail '停止旧服务失败'
fi

if pidof hysteria >/dev/null 2>&1; then
    fail '检测到未停止的 Hysteria 进程，请检查后重新安装'
fi

mv -f "$STAGED" "$BIN"
STAGED=

install -m 755 /dev/stdin "$SERVICE" <<'EOF_SERVICE'
#!/sbin/openrc-run

name="hysteria"
description="Hysteria 2 Server"

supervisor="supervise-daemon"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"

directory="/etc/hysteria"
pidfile="/run/${RC_SVCNAME}.pid"

respawn_delay=3
respawn_max=0

output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.err.log"

depend() {
    after net
}
EOF_SERVICE

install -m 755 /dev/stdin "$MANAGER" <<'EOF_MANAGER'
#!/bin/sh
set -eu

case "${1:-help}" in
    start|stop|restart|status)
        exec rc-service hysteria "$1"
        ;;
    info|link)
        [ -r /etc/hysteria/connection.txt ] || {
            printf '[错误] 无法读取连接信息，请使用 root 执行 hy2 info\n' >&2
            exit 1
        }
        if [ "${1:-}" = info ] && [ -t 1 ]; then
            printf '\nHysteria 2 · 连接信息\n'
            printf '%s\n' '----------------------------------------'
            printf '分享链接（复制下面完整一行）：\n\n'
        fi
        cat /etc/hysteria/connection.txt
        if [ "${1:-}" = info ] && [ -t 1 ]; then
            printf '\n查看状态  hy2 status\n查看日志  hy2 log\n\n'
        fi
        ;;
    log|logs)
        found=0

        for file in /var/log/hysteria.log /var/log/hysteria.err.log; do
            if [ -f "$file" ]; then
                found=1
                printf '\n最近日志 · %s\n' "$file"
                printf '%s\n' '----------------------------------------'
                tail -n 60 "$file"
            fi
        done

        [ "$found" -eq 1 ] || printf '[提示] 暂无日志\n'
        ;;
    version)
        exec /usr/local/bin/hysteria version
        ;;
    help|-h|--help)
        cat <<'USAGE'

Hysteria 2 · 管理命令
----------------------------------------
用法：hy2 <命令>

  info       查看连接信息和分享链接
  link       仅输出分享链接，方便复制或用于管道
  status     查看服务状态
  start      启动服务
  stop       停止服务
  restart    重启服务
  log        查看最近 60 行日志
  version    查看内核版本
  help       显示此帮助

USAGE
        ;;
    *)
        printf '[错误] 未知命令：%s\n执行 hy2 help 查看可用命令。\n' "$1" >&2
        exit 2
        ;;
esac
EOF_MANAGER

success '内核和 hy2 管理命令已安装'
step 5 '启动服务并检查运行状态'
rc-update add hysteria default >/dev/null 2>&1 || fail '设置开机自启失败'
rc-service hysteria zap >/dev/null 2>&1 || true
rc-service hysteria start >/dev/null 2>&1 || fail '启动 Hysteria 失败，请执行 hy2 log 查看日志'

sleep 1

rc-service hysteria status >/dev/null 2>&1 || fail 'Hysteria 服务未正常运行，请执行 hy2 log 查看日志'

pidof hysteria >/dev/null 2>&1 || fail 'Hysteria 进程未运行'
success 'Hysteria 服务正在运行'

if [ "$PID1" = init ] &&
   { [ ! -f /etc/inittab ] ||
     ! grep -Eq '^[^#]*:/sbin/openrc[[:space:]]+default([[:space:]]|$)' /etc/inittab; }; then

    warn '未检测到 OpenRC 默认运行级别启动入口，重启后自启尚不能保证。'
fi

printf '\n%sHysteria 2 安装完成%s\n' "$GREEN" "$RESET" >&2
printf '%s\n' '----------------------------------------' >&2
printf '  服务状态  运行中\n  监听端口  %s / UDP\n  配置文件  %s\n' "$PORT" "$CONFIG" >&2
printf '\n请在防火墙或安全组中放行 UDP %s。\n' "$PORT" >&2
printf '\n常用命令\n  hy2 info     查看连接信息\n  hy2 status   查看服务状态\n  hy2 log      查看运行日志\n' >&2
printf '\n分享链接（复制下面完整一行）：\n\n' >&2
printf '%s\n' "$URI"
