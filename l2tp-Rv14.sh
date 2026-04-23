#!/bin/bash

set -e

# 统一脚本入口：通过参数切换配置（CN/HK/17.30）
PROFILE="auto"
SELF_CHECK=0
REMAINING_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --profile=*)
            PROFILE="${1#*=}"
            shift
            ;;
        --dns-mode=cn)
            PROFILE="cn"
            shift
            ;;
        --dns-mode=global)
            PROFILE="hk"
            shift
            ;;
        --self-check)
            SELF_CHECK=1
            shift
            ;;
        *)
            REMAINING_ARGS+=("$1")
            shift
            ;;
    esac
done

# 恢复参数供原脚本菜单/命令解析继续使用
set -- "${REMAINING_ARGS[@]}"

detect_country_code_by_public_ip() {
    local ip="" country=""
    if command -v curl >/dev/null 2>&1; then
        ip="$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
        [ -n "$ip" ] || ip="$(curl -4fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
        if [ -n "$ip" ]; then
            country="$(curl -fsS --max-time 3 "https://ipapi.co/${ip}/country/" 2>/dev/null | tr -d '\r\n' || true)"
            [ -n "$country" ] || country="$(curl -fsS --max-time 3 "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '\r\n' || true)"
            [ -n "$country" ] || country="$(curl -fsS --max-time 3 https://ifconfig.co/country-iso 2>/dev/null | tr -d '\r\n' || true)"
        fi
    fi
    echo "$country"
}

resolve_auto_profile() {
    local cc=""
    cc="$(detect_country_code_by_public_ip)"
    case "$cc" in
        CN|cn)
            echo "cn"
            ;;
        '')
            # 无法探测时默认走国外 DNS，避免误用国内 DNS 导致解析异常
            echo "hk"
            ;;
        *)
            echo "hk"
            ;;
    esac
}

if [ "$PROFILE" = "auto" ]; then
    PROFILE="$(resolve_auto_profile)"
    echo "🌍 自动识别 profile 结果: $PROFILE"
fi

case "$PROFILE" in
    cn)
        PROFILE_LABEL="CN 增强"
        DNS_MODE_LABEL="国内"
        PPP_DNS_1="223.5.5.5"
        PPP_DNS_2="119.29.29.29"
        DPD_DELAY=15
        DPD_TIMEOUT=120
        CONNECT_DELAY=5000
        LCP_ECHO_ADAPTIVE=0
        LCP_ECHO_INTERVAL=10
        LCP_ECHO_FAILURE=30
        KEEPALIVE_MODE="active"
        ;;
    hk)
        PROFILE_LABEL="HK 增强"
        DNS_MODE_LABEL="国外"
        PPP_DNS_1="8.8.8.8"
        PPP_DNS_2="1.1.1.1"
        DPD_DELAY=15
        DPD_TIMEOUT=120
        CONNECT_DELAY=5000
        LCP_ECHO_ADAPTIVE=0
        LCP_ECHO_INTERVAL=10
        LCP_ECHO_FAILURE=30
        KEEPALIVE_MODE="active"
        ;;
    17.30)
        PROFILE_LABEL="17.30 稳定"
        DNS_MODE_LABEL="国外"
        PPP_DNS_1="8.8.8.8"
        PPP_DNS_2="1.1.1.1"
        DPD_DELAY=30
        DPD_TIMEOUT=300
        CONNECT_DELAY=10000
        LCP_ECHO_ADAPTIVE=1
        LCP_ECHO_INTERVAL=30
        LCP_ECHO_FAILURE=20
        KEEPALIVE_MODE="disabled"
        ;;
    *)
        echo "❌ 不支持的 profile: $PROFILE（支持: auto / cn / hk / 17.30）" >&2
        exit 1
        ;;
esac

if [ "$LCP_ECHO_ADAPTIVE" -eq 1 ]; then
    LCP_ADAPTIVE_LINE="lcp-echo-adaptive
"
else
    LCP_ADAPTIVE_LINE=""
fi

# 生效配置：${PROFILE_LABEL}（DNS: ${DNS_MODE_LABEL}）

# ===== 基础文件路径（沿用 l2tp10-2） =====
VPN_USER_FILE="/etc/ppp/chap-secrets"
IPSEC_SECRET_FILE="/etc/ipsec.secrets"
IPSEC_CONF_FILE="/etc/ipsec.conf"
XL2TPD_CONF_FILE="/etc/xl2tpd/xl2tpd.conf"
PPP_OPTIONS_FILE="/etc/ppp/options.xl2tpd"
SYSCTL_FILE="/etc/sysctl.d/99-vpn.conf"
KEEPALIVE_SCRIPT="/usr/local/sbin/l2tp-idle-keepalive.sh"
KEEPALIVE_SERVICE="/etc/systemd/system/l2tp-idle-keepalive.service"
KEEPALIVE_TIMER="/etc/systemd/system/l2tp-idle-keepalive.timer"
RATE_LIMIT_FILE="/etc/ppp/l2tp-user-limits.conf"
RATE_LIMIT_HOOK_UP="/etc/ppp/ip-up.d/99-l2tp-user-rate-limit"
RATE_LIMIT_HOOK_DOWN="/etc/ppp/ip-down.d/99-l2tp-user-rate-limit-clean"
SESSION_SPEED_CACHE="/tmp/l2tp-speed.cache"
REPORT_FILE="/root/vpn-report.txt"
PUBLIC_IP_MAP_FILE="/etc/ppp/l2tp-user-public-ip.conf"
PUBLIC_IP_HOOK_UP="/etc/ppp/ip-up.d/98-l2tp-user-public-ip-snat"
PUBLIC_IP_HOOK_DOWN="/etc/ppp/ip-down.d/98-l2tp-user-public-ip-snat-clean"
HOOK_LOCK_FILE="/run/l2tp-hook.lock"
IP_ALLOC_LOCK_FILE="/run/l2tp-ip-alloc.lock"
SESSION_STATE_FILE="/etc/ppp/l2tp-session-state.conf"
SESSION_HOOK_UP="/etc/ppp/ip-up.d/97-l2tp-session-state"
SESSION_HOOK_DOWN="/etc/ppp/ip-down.d/97-l2tp-session-state-clean"
VPN_IP_MAP_FILE="/etc/ppp/l2tp-user-vpn-ip.conf"
VPN_LOCAL_IP="10.50.60.1"
VPN_IP_POOL_START=10
VPN_IP_POOL_END=100

# ===== 基础环境检测 =====
WAN_IFACE="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)"
IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

get_ssh_port() {
    local port=""

    if command -v sshd >/dev/null 2>&1; then
        port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    fi

    if [ -z "$port" ] && [ -f /etc/ssh/sshd_config ]; then
        port="$(awk '
            BEGIN{IGNORECASE=1}
            /^[[:space:]]*#/ {next}
            tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}
        ' /etc/ssh/sshd_config 2>/dev/null)"
    fi

    if [ -z "$port" ] && command -v ss >/dev/null 2>&1; then
        port="$(ss -tnlp 2>/dev/null | awk '
            /sshd/ {
                for (i=1; i<=NF; i++) {
                    if ($i ~ /:[0-9]+$/) {
                        split($i, a, ":")
                        p=a[length(a)]
                        if (p ~ /^[0-9]+$/) {
                            print p
                            exit
                        }
                    }
                }
            }
        ')"
    fi

    if ! echo "$port" | grep -Eq '^[0-9]+$'; then
        port=22
    fi

    echo "$port"
}

SSH_PORT="$(get_ssh_port)"


get_iptables_cmd() {
    local cmd=""
    cmd="$(command -v iptables 2>/dev/null || true)"
    [ -n "$cmd" ] || [ ! -x /usr/sbin/iptables ] || cmd="/usr/sbin/iptables"
    [ -n "$cmd" ] || [ ! -x /sbin/iptables ] || cmd="/sbin/iptables"
    echo "$cmd"
}

require_iptables() {
    IPT="$(get_iptables_cmd)"
    if [ -z "$IPT" ]; then
        echo "❌ 未找到 iptables 命令，请先安装 iptables / iptables-nft" >&2
        return 1
    fi
    return 0
}



is_valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

ensure_firewall_port_open() {
    local port="$1"
    [ -n "$port" ] || return 0
    if ! is_valid_port "$port"; then
        echo "⚠️ 跳过非法端口: $port" >&2
        return 0
    fi

    case "$FIREWALL" in
        ufw)
            ufw allow ${port}/tcp >/dev/null 2>&1 || true
            ufw allow ${port}/udp >/dev/null 2>&1 || true
            ;;
        nftables)
            nft add rule inet filter input tcp dport $port accept 2>/dev/null || true
            nft add rule inet filter input udp dport $port accept 2>/dev/null || true
            ;;
        iptables)
            require_iptables || return 0
            "$IPT" -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || "$IPT" -I INPUT -p tcp --dport "$port" -j ACCEPT
            "$IPT" -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || "$IPT" -I INPUT -p udp --dport "$port" -j ACCEPT
            ;;
    esac
}

if grep -qi ubuntu /etc/os-release; then
    OS="ubuntu"
elif [ -f /etc/debian_version ]; then
    OS="debian"
elif grep -qi centos /etc/os-release; then
    OS="centos"
else
    echo "❌ 不支持的系统"
    exit 1
fi

# ===== 通用辅助函数 =====
service_name_ipsec() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^ipsec\.service'; then
        echo "ipsec"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^strongswan\.service'; then
        echo "strongswan"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^strongswan-starter\.service'; then
        echo "strongswan-starter"
    else
        echo "ipsec"
    fi
}

IPSEC_SERVICE="$(service_name_ipsec)"

safe_pause() {
    echo
    read -rp "按回车继续..." _
}

vpn_installed() {
    [ -f "$VPN_USER_FILE" ] && [ -f "$IPSEC_CONF_FILE" ] && [ -f "$XL2TPD_CONF_FILE" ]
}

validate_username() {
    [[ "$1" =~ ^[a-zA-Z0-9_.-]{3,32}$ ]]
}

gen_next_vpn_user() {
    local base="vpnuser"
    local max_num=0
    local user n

    if ! list_existing_users | grep -Fxq "$base"; then
        echo "$base"
        return 0
    fi

    while read -r user; do
        [ -n "$user" ] || continue
        if [ "$user" = "$base" ]; then
            continue
        fi
        if echo "$user" | grep -Eq "^${base}[0-9]+$"; then
            n="${user#$base}"
            if echo "$n" | grep -Eq '^[0-9]+$' && [ "$n" -gt "$max_num" ]; then
                max_num="$n"
            fi
        fi
    done < <(list_existing_users)

    echo "${base}$((max_num + 1))"
}

gen_random_pass() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12
}

list_existing_users() {
    [ -f "$VPN_USER_FILE" ] || return 0
    awk '!/^[[:space:]]*#/ && NF>=1 {print $1}' "$VPN_USER_FILE" 2>/dev/null | awk '!seen[$0]++'
}

ipv4_to_int() {
    local ip="$1" a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ipv4() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

get_user_vpn_ip() {
    local user="$1"
    [ -f "$VPN_IP_MAP_FILE" ] || return 0
    awk -F= -v u="$user" '$1==u{print $2; exit}' "$VPN_IP_MAP_FILE" 2>/dev/null || true
}

list_assigned_vpn_ips() {
    [ -f "$VPN_IP_MAP_FILE" ] || return 0
    awk -F= 'NF>=2 && $2!="" {print $2}' "$VPN_IP_MAP_FILE" 2>/dev/null | awk '!seen[$0]++'
}

next_available_vpn_ip() {
    local host candidate
    for host in $(seq "$VPN_IP_POOL_START" "$VPN_IP_POOL_END"); do
        candidate="10.50.60.${host}"
        if ! list_assigned_vpn_ips | grep -Fxq "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

create_user_with_auto_vpn_ip() {
    local user="$1" pass="$2" vpn_ip="" host candidate
    [ -n "$user" ] || return 1
    [ -n "$pass" ] || return 1
    mkdir -p /run
    touch "$IP_ALLOC_LOCK_FILE"
    exec 8>"$IP_ALLOC_LOCK_FILE"
    flock -x 8 || return 1
    for host in $(seq "$VPN_IP_POOL_START" "$VPN_IP_POOL_END"); do
        candidate="10.50.60.${host}"
        if ! list_assigned_vpn_ips | grep -Fxq "$candidate"; then
            vpn_ip="$candidate"
            break
        fi
    done
    [ -n "$vpn_ip" ] || return 1
    upsert_chap_user "$user" "$pass" "$vpn_ip"
    printf '%s\n' "$vpn_ip"
}

upsert_user_vpn_ip_mapping() {
    local user="$1" vpn_ip="$2"
    touch "$VPN_IP_MAP_FILE"
    awk -F= -v u="$user" -v ip="$vpn_ip" '
      BEGIN{done=0}
      $1==u { if(!done && ip!=""){print u"="ip; done=1} next }
      {print}
      END{ if(!done && ip!="") print u"="ip }
    ' "$VPN_IP_MAP_FILE" > "${VPN_IP_MAP_FILE}.tmp"
    mv -f "${VPN_IP_MAP_FILE}.tmp" "$VPN_IP_MAP_FILE"
    chmod 600 "$VPN_IP_MAP_FILE" || true
}

delete_user_vpn_ip_mapping() {
    local user="$1"
    [ -f "$VPN_IP_MAP_FILE" ] || return 0
    awk -F= -v u="$user" '$1!=u {print}' "$VPN_IP_MAP_FILE" > "${VPN_IP_MAP_FILE}.tmp"
    mv -f "${VPN_IP_MAP_FILE}.tmp" "$VPN_IP_MAP_FILE"
    chmod 600 "$VPN_IP_MAP_FILE" || true
}

upsert_chap_user() {
    local user="$1" pass="$2" vpn_ip="$3"
    touch "$VPN_USER_FILE"
    awk -v u="$user" -v p="$pass" -v ip="$vpn_ip" '
      BEGIN{done=0}
      /^[[:space:]]*#/ {print; next}
      NF >= 1 && $1 == u {
        if (!done) { printf "%s\t*\t%s\t%s\n", u, p, ip; done=1 }
        next
      }
      {print}
      END{ if (!done) printf "%s\t*\t%s\t%s\n", u, p, ip }
    ' "$VPN_USER_FILE" > "${VPN_USER_FILE}.tmp"
    mv -f "${VPN_USER_FILE}.tmp" "$VPN_USER_FILE"
    chmod 600 "$VPN_USER_FILE" || true
    upsert_user_vpn_ip_mapping "$user" "$vpn_ip"
}

select_existing_user_by_number() {
    local prompt="${1:-请选择用户编号: }"
    local users=() selected=""
    mapfile -t users < <(list_existing_users)
    if [ "${#users[@]}" -eq 0 ]; then
        echo "❌ 当前没有已建立的用户" >&2
        return 1
    fi

    echo "====================================" >&2
    echo "已建立的用户名列表" >&2
    echo "====================================" >&2
    for i in "${!users[@]}"; do
        echo "$((i+1))). ${users[$i]}" >&2
    done
    echo "------------------------------------" >&2
    read -rp "${prompt} [1-${#users[@]}]: " selected
    if ! echo "$selected" | grep -Eq '^[0-9]+$'; then
        echo "❌ 请输入有效编号" >&2
        return 1
    fi
    if [ "$selected" -lt 1 ] || [ "$selected" -gt "${#users[@]}" ]; then
        echo "❌ 编号超出范围" >&2
        return 1
    fi
    printf '%s\n' "${users[$((selected-1))]}"
}

show_public_ip_binding_table() {
    local user="${1:-}" entries idx=1 ip owner tag
    entries="$(list_public_ips_with_owner || true)"
    echo "===================================="
    if [ -n "$user" ]; then
        echo "用户 ${user} 的出口公网 IP 选择"
    else
        echo "出口公网 IP 分配状态"
    fi
    echo "===================================="
    if [ -z "$(printf '%s\n' "$entries" | sed '/^[[:space:]]*$/d')" ]; then
        echo "未检测到公网 IPv4"
        echo "===================================="
        return 0
    fi
    while IFS='|' read -r ip owner; do
        [ -n "$ip" ] || continue
        if [ -n "$owner" ]; then
            if [ -n "$user" ] && [ "$owner" = "$user" ]; then
                tag="当前绑定"
            else
                tag="已绑定给: ${owner}"
            fi
        else
            tag="空闲"
        fi
        echo "${idx}) ${ip}  [${tag}]"
        idx=$((idx+1))
    done <<< "$entries"
    echo "===================================="
}

is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^127\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    return 1
}

list_public_ipv4s() {
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | while read -r ip; do
        [ -n "$ip" ] || continue
        is_private_ipv4 "$ip" && continue
        printf '%s\n' "$ip"
    done | awk '!seen[$0]++'
}

get_public_ip_users() {
    local target_ip="$1"
    [ -f "$PUBLIC_IP_MAP_FILE" ] || return 0
    awk -F= -v ip="$target_ip" '$2==ip{print $1}' "$PUBLIC_IP_MAP_FILE" 2>/dev/null | paste -sd, - || true
}

get_public_ip_owner() {
    local target_ip="$1"
    get_public_ip_users "$target_ip"
}

list_public_ips_with_owner() {
    local ip owner
    while read -r ip; do
        [ -n "$ip" ] || continue
        owner="$(get_public_ip_owner "$ip")"
        printf "%s|%s\n" "$ip" "$owner"
    done < <(list_public_ipv4s)
}

show_public_ip_allocations() {
    local entries found=0 ip owner
    entries="$(list_public_ips_with_owner || true)"
    echo "===================================="
    echo "公网 IP 分配状态"
    echo "===================================="
    printf "%-6s %-24s %-20s
" "序号" "公网IP" "绑定用户"
    echo "------------------------------------"
    while IFS='|' read -r ip owner; do
        [ -n "$ip" ] || continue
        found=$((found+1))
        [ -n "$owner" ] || owner="空闲"
        printf "%-6s %-24s %-20s
" "$found" "$ip" "$owner"
    done <<< "$entries"
    if [ "$found" -eq 0 ]; then
        echo "未检测到公网 IP"
    fi
    echo "------------------------------------"
    echo "说明：空闲=未绑定；绑定用户=该公网 IP 当前已分配给对应用户名"
    echo "===================================="
}

get_user_public_ip() {
    local user="$1"
    [ -f "$PUBLIC_IP_MAP_FILE" ] || return 0
    awk -F= -v u="$user" '$1==u{print $2; exit}' "$PUBLIC_IP_MAP_FILE" 2>/dev/null || true
}

get_user_effective_exit_ip() {
    local user="$1" mapped_ip=""
    mapped_ip="$(get_user_public_ip "$user")"
    if [ -n "$mapped_ip" ]; then
        echo "$mapped_ip"
        return 0
    fi
    list_public_ipv4s | head -n1
}

upsert_public_ip_mapping() {
    local user="$1" public_ip="$2"
    touch "$PUBLIC_IP_MAP_FILE"
    awk -F= -v u="$user" -v ip="$public_ip" '
      BEGIN{done=0}
      $1==u { if(!done && ip!=""){print u"="ip; done=1} next }
      {print}
      END{ if(!done && ip!="") print u"="ip }
    ' "$PUBLIC_IP_MAP_FILE" > "${PUBLIC_IP_MAP_FILE}.tmp"
    mv -f "${PUBLIC_IP_MAP_FILE}.tmp" "$PUBLIC_IP_MAP_FILE"
    chmod 600 "$PUBLIC_IP_MAP_FILE" || true
}

delete_public_ip_mapping() {
    local user="$1"
    [ -f "$PUBLIC_IP_MAP_FILE" ] || return 0
    awk -F= -v u="$user" '$1!=u {print}' "$PUBLIC_IP_MAP_FILE" > "${PUBLIC_IP_MAP_FILE}.tmp"
    mv -f "${PUBLIC_IP_MAP_FILE}.tmp" "$PUBLIC_IP_MAP_FILE"
    chmod 600 "$PUBLIC_IP_MAP_FILE" || true
}

choose_public_ip_for_user() {
    local user="$1" entries chosen_line chosen_ip idx=0 selected first_public_ip="" owners
    entries="$(list_public_ips_with_owner || true)"
    first_public_ip="$(printf '%s
' "$entries" | sed '/^[[:space:]]*$/d' | head -n1 | cut -d'|' -f1)"
    if [ -z "${first_public_ip:-}" ]; then
        echo ""
        return 0
    fi

    echo >&2
    echo "====================================" >&2
    echo "服务器公网 IP 列表（为用户 ${user} 选择出口）" >&2
    echo "====================================" >&2
    while IFS='|' read -r ip owners; do
        [ -n "$ip" ] || continue
        idx=$((idx+1))
        echo "${idx}、${ip}" >&2
        if [ -n "$owners" ]; then
            echo "   已绑定用户: ${owners}" >&2
        else
            echo "   空闲" >&2
        fi
    done <<< "$entries"
    echo "------------------------------------" >&2
    echo "直接回车将默认绑定第 1 个公网 IP：${first_public_ip}" >&2
    read -rp "请选择要绑定的公网 IP 编号 [1-${idx}]: " selected

    if [ -z "${selected:-}" ]; then
        echo "$first_public_ip"
        return 0
    fi
    if ! echo "$selected" | grep -Eq '^[0-9]+$'; then
        echo "$first_public_ip"
        return 0
    fi
    if [ "$selected" -lt 1 ] || [ "$selected" -gt "$idx" ]; then
        echo "$first_public_ip"
        return 0
    fi

    chosen_line="$(printf '%s
' "$entries" | sed -n "${selected}p")"
    chosen_ip="${chosen_line%%|*}"
    [ -n "$chosen_ip" ] || chosen_ip="$first_public_ip"
    echo "$chosen_ip"
}

find_live_session_by_vpn_ip() {
    local target_ip="$1" ifname line peer_ip local_ip now_ts
    [ -n "$target_ip" ] || return 1
    while read -r ifname; do
        [ -n "$ifname" ] || continue
        line="$(ip -4 -o addr show dev "$ifname" 2>/dev/null | head -n1 || true)"
        [ -n "$line" ] || continue
        local_ip="$(printf '%s
' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="inet"){print $(i+1); exit}}' | cut -d/ -f1)"
        peer_ip="$(printf '%s
' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="peer"){print $(i+1); exit}}' | cut -d/ -f1)"
        if [ "$peer_ip" = "$target_ip" ] || [ "$local_ip" = "$target_ip" ]; then
            now_ts="$(get_iface_start_timestamp "$ifname")"
            printf '%s
%s
%s
%s
' "$ifname" "$peer_ip" "$local_ip" "$now_ts"
            return 0
        fi
    done < <(list_active_ppp_ifaces)
    return 1
}

install_public_ip_hooks() {
    mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d /run
    touch "$PUBLIC_IP_MAP_FILE" "$HOOK_LOCK_FILE"

    cat > "$PUBLIC_IP_HOOK_UP" <<'EOF2'
#!/bin/bash
set -e
MAP_FILE="/etc/ppp/l2tp-user-public-ip.conf"
HOOK_LOCK_FILE="/run/l2tp-hook.lock"
IP_ALLOC_LOCK_FILE="/run/l2tp-ip-alloc.lock"
SESSION_STATE_FILE="/etc/ppp/l2tp-session-state.conf"
SESSION_HOOK_UP="/etc/ppp/ip-up.d/97-l2tp-session-state"
SESSION_HOOK_DOWN="/etc/ppp/ip-down.d/97-l2tp-session-state-clean"
VPN_IP_MAP_FILE="/etc/ppp/l2tp-user-vpn-ip.conf"
VPN_LOCAL_IP="10.50.60.1"
VPN_IP_POOL_START=10
VPN_IP_POOL_END=100
IPT="$(command -v iptables 2>/dev/null || true)"
[ -n "$IPT" ] || IPT="/usr/sbin/iptables"
[ -n "$IPT" ] || IPT="/sbin/iptables"
[ -f "$MAP_FILE" ] || exit 0
[ -x "$IPT" ] || exit 0

USER_NAME="${PEERNAME:-}"
[ -n "$USER_NAME" ] || exit 0

PUBLIC_IP="$(awk -F= -v u="$USER_NAME" '$1==u{print $2; exit}' "$MAP_FILE")"
[ -n "$PUBLIC_IP" ] || exit 0

REMOTE_IP="${IPREMOTE:-}"
[ -n "$REMOTE_IP" ] || exit 0

mkdir -p /run
: > "$HOOK_LOCK_FILE"
exec 9>"$HOOK_LOCK_FILE"
flock -x 9 || exit 0

COMMENT="L2TP_PUBLIC_SNAT:${USER_NAME}"
while "$IPT" -t nat -D POSTROUTING -s "${REMOTE_IP}/32" -m comment --comment "$COMMENT" -j SNAT --to-source "$PUBLIC_IP" 2>/dev/null; do :; done
"$IPT" -t nat -I POSTROUTING 1 -s "${REMOTE_IP}/32" -m comment --comment "$COMMENT" -j SNAT --to-source "$PUBLIC_IP" 2>/dev/null || true
EOF2

    cat > "$PUBLIC_IP_HOOK_DOWN" <<'EOF2'
#!/bin/bash
set -e
MAP_FILE="/etc/ppp/l2tp-user-public-ip.conf"
HOOK_LOCK_FILE="/run/l2tp-hook.lock"
IP_ALLOC_LOCK_FILE="/run/l2tp-ip-alloc.lock"
SESSION_STATE_FILE="/etc/ppp/l2tp-session-state.conf"
SESSION_HOOK_UP="/etc/ppp/ip-up.d/97-l2tp-session-state"
SESSION_HOOK_DOWN="/etc/ppp/ip-down.d/97-l2tp-session-state-clean"
VPN_IP_MAP_FILE="/etc/ppp/l2tp-user-vpn-ip.conf"
VPN_LOCAL_IP="10.50.60.1"
VPN_IP_POOL_START=10
VPN_IP_POOL_END=100
IPT="$(command -v iptables 2>/dev/null || true)"
[ -n "$IPT" ] || IPT="/usr/sbin/iptables"
[ -n "$IPT" ] || IPT="/sbin/iptables"
[ -f "$MAP_FILE" ] || exit 0
[ -x "$IPT" ] || exit 0

USER_NAME="${PEERNAME:-}"
[ -n "$USER_NAME" ] || exit 0

PUBLIC_IP="$(awk -F= -v u="$USER_NAME" '$1==u{print $2; exit}' "$MAP_FILE")"
[ -n "$PUBLIC_IP" ] || exit 0

REMOTE_IP="${IPREMOTE:-}"
[ -n "$REMOTE_IP" ] || exit 0

mkdir -p /run
: > "$HOOK_LOCK_FILE"
exec 9>"$HOOK_LOCK_FILE"
flock -x 9 || exit 0

COMMENT="L2TP_PUBLIC_SNAT:${USER_NAME}"
while "$IPT" -t nat -D POSTROUTING -s "${REMOTE_IP}/32" -m comment --comment "$COMMENT" -j SNAT --to-source "$PUBLIC_IP" 2>/dev/null; do :; done
EOF2

    chmod +x "$PUBLIC_IP_HOOK_UP" "$PUBLIC_IP_HOOK_DOWN"
}

install_session_state_hooks() {
    mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d /run
    touch "$SESSION_STATE_FILE" "$HOOK_LOCK_FILE"

    cat > "$SESSION_HOOK_UP" <<'EOF2'
#!/bin/bash
set -e
STATE_FILE="/etc/ppp/l2tp-session-state.conf"
HOOK_LOCK_FILE="/run/l2tp-hook.lock"
mkdir -p /etc/ppp /run
touch "$STATE_FILE" "$HOOK_LOCK_FILE"

USER_NAME="${PEERNAME:-}"
IF_NAME="${IFNAME:-${PPP_IFACE:-}}"
REMOTE_IP="${IPREMOTE:-}"
LOCAL_IP="${IPLOCAL:-}"
CONNECT_TIME="$(date +%s)"

[ -n "$USER_NAME" ] || exit 0
[ -n "$IF_NAME" ] || exit 0

exec 9>"$HOOK_LOCK_FILE"
flock -x 9 || exit 0

awk -F'	' -v u="$USER_NAME" -v i="$IF_NAME" -v r="$REMOTE_IP" '
  BEGIN{OFS="\t"}
  $1==u {next}
  $2==i {next}
  (r!="" && $3==r) {next}
  {print $0}
' "$STATE_FILE" 2>/dev/null > "${STATE_FILE}.tmp" || true
{
  cat "${STATE_FILE}.tmp" 2>/dev/null || true
  printf "%s\t%s\t%s\t%s\t%s\n" "$USER_NAME" "$IF_NAME" "$REMOTE_IP" "$LOCAL_IP" "$CONNECT_TIME"
} > "$STATE_FILE"
rm -f "${STATE_FILE}.tmp"
chmod 600 "$STATE_FILE" || true
EOF2

    cat > "$SESSION_HOOK_DOWN" <<'EOF2'
#!/bin/bash
set -e
STATE_FILE="/etc/ppp/l2tp-session-state.conf"
HOOK_LOCK_FILE="/run/l2tp-hook.lock"
USER_NAME="${PEERNAME:-}"
IF_NAME="${IFNAME:-${PPP_IFACE:-}}"
REMOTE_IP="${IPREMOTE:-}"
[ -f "$STATE_FILE" ] || exit 0

mkdir -p /run
: > "$HOOK_LOCK_FILE"
exec 9>"$HOOK_LOCK_FILE"
flock -x 9 || exit 0

awk -F'	' -v u="$USER_NAME" -v i="$IF_NAME" -v r="$REMOTE_IP" '
  BEGIN{OFS="\t"}
  (i!="" && $2==i) {next}
  (r!="" && $3==r) {next}
  (i=="" && r=="" && u!="" && $1==u) {next}
  {print $0}
' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
chmod 600 "$STATE_FILE" || true
EOF2

    chmod +x "$SESSION_HOOK_UP" "$SESSION_HOOK_DOWN"
}

get_session_state_line() {
    local user="$1"
    [ -f "$SESSION_STATE_FILE" ] || return 0
    awk -F'	' -v u="$user" '$1==u{print; exit}' "$SESSION_STATE_FILE" 2>/dev/null || true
}

parse_session_state_line() {
    local line="$1"
    [ -n "$line" ] || return 1
    printf '%s
' "$line" | awk -F'	' 'NF>=5{print $1"
"$2"
"$3"
"$4"
"$5}'
}

list_active_ppp_ifaces() {
    ip -o link show 2>/dev/null | awk -F': ' '/ppp[0-9]+:/{print $2}' | awk '!seen[$0]++'
}

get_ppp_iface_ips() {
    local ifname="$1"
    local line local_ip remote_ip
    line="$(ip -4 -o addr show dev "$ifname" 2>/dev/null | head -n1 || true)"
    [ -n "$line" ] || return 1
    local_ip="$(printf '%s
' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="inet"){print $(i+1); exit}}' | cut -d/ -f1)"
    remote_ip="$(printf '%s
' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="peer"){print $(i+1); exit}}' | cut -d/ -f1)"
    [ -n "$remote_ip" ] || remote_ip="$local_ip"
    printf '%s
%s
' "$remote_ip" "$local_ip"
}

get_iface_start_timestamp() {
    local ifname="$1" pid="" elapsed="" now=""
    for pidfile in /var/run/ppp*.pid /run/ppp*.pid; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null || true)"
        [ -n "$pid" ] || continue
        [ -r "/proc/${pid}/cmdline" ] || continue
        if tr '' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -Eq "(^|[[:space:]])${ifname}([[:space:]]|$)"; then
            break
        else
            pid=""
        fi
    done
    if [ -n "$pid" ] && command -v ps >/dev/null 2>&1; then
        elapsed="$(ps -o etimes= -p "$pid" 2>/dev/null | awk '{print $1}' | head -n1)"
        if echo "$elapsed" | grep -Eq '^[0-9]+$'; then
            now="$(date +%s)"
            echo $((now - elapsed))
            return 0
        fi
    fi
    date +%s
}

guess_user_live_session() {
    local user="$1" state="" ifname="" remote_ip="" local_ip="" connect_ts=""
    local parsed=() iface_ips=()
    state="$(get_session_state_line "$user" 2>/dev/null || true)"
    if [ -n "$state" ]; then
        mapfile -t parsed < <(parse_session_state_line "$state" 2>/dev/null || true)
        ifname="${parsed[1]:-}"
        remote_ip="${parsed[2]:-}"
        local_ip="${parsed[3]:-}"
        connect_ts="${parsed[4]:-}"
        if [ -n "$ifname" ] && ip link show "$ifname" >/dev/null 2>&1; then
            printf '%s
%s
%s
%s
%s
' "$user" "$ifname" "$remote_ip" "$local_ip" "$connect_ts"
            return 0
        fi
    fi

    if command -v journalctl >/dev/null 2>&1; then
        ifname="$(journalctl -u xl2tpd -n 300 --no-pager 2>/dev/null | grep -F "$user" | grep -Eo 'ppp[0-9]+' | tail -n1 || true)"
    fi
    if [ -z "$ifname" ]; then
        ifname="$(list_active_ppp_ifaces | head -n1 || true)"
    fi
    [ -n "$ifname" ] || return 1
    ip link show "$ifname" >/dev/null 2>&1 || return 1
    mapfile -t iface_ips < <(get_ppp_iface_ips "$ifname" 2>/dev/null || true)
    remote_ip="${iface_ips[0]:-}"
    local_ip="${iface_ips[1]:-}"
    connect_ts="$(get_iface_start_timestamp "$ifname")"
    printf '%s
%s
%s
%s
%s
' "$user" "$ifname" "$remote_ip" "$local_ip" "$connect_ts"
}


human_bytes() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN{
      split("B KB MB GB TB",u," ");
      i=1;
      while (b>=1024 && i<5) {b/=1024; i++}
      if (i==1) printf "%.0f%s", b, u[i];
      else printf "%.1f%s", b, u[i];
    }'
}

human_duration() {
    local secs="${1:-0}"
    if [ "$secs" -lt 60 ] 2>/dev/null; then
        echo "${secs}s"
    elif [ "$secs" -lt 3600 ] 2>/dev/null; then
        echo "$((secs/60))m$((secs%60))s"
    elif [ "$secs" -lt 86400 ] 2>/dev/null; then
        echo "$((secs/3600))h$(((secs%3600)/60))m"
    else
        echo "$((secs/86400))d$(((secs%86400)/3600))h"
    fi
}

get_speed_cache_line() {
    local ifname="$1"
    [ -f "$SESSION_SPEED_CACHE" ] || return 0
    awk -F= -v k="$ifname" '$1==k{print $2; exit}' "$SESSION_SPEED_CACHE" 2>/dev/null || true
}

update_speed_cache_line() {
    local ifname="$1" rx="$2" tx="$3" ts="$4"
    touch "$SESSION_SPEED_CACHE"
    awk -F= -v k="$ifname" -v v="${rx}|${tx}|${ts}" '
      BEGIN{done=0}
      $1==k { if(!done){print k"="v; done=1} next }
      {print}
      END{ if(!done) print k"="v }
    ' "$SESSION_SPEED_CACHE" > "${SESSION_SPEED_CACHE}.tmp"
    mv -f "${SESSION_SPEED_CACHE}.tmp" "$SESSION_SPEED_CACHE"
}

calc_iface_rates() {
    local ifname="$1" rx="$2" tx="$3" now="$4"
    local prev prx ptx pts dt rx_delta tx_delta total_delta rx_speed tx_speed total_speed rest
    prev="$(get_speed_cache_line "$ifname")"
    update_speed_cache_line "$ifname" "$rx" "$tx" "$now"
    [ -n "$prev" ] || { printf '0B/s
0B/s
0B/s
'; return 0; }
    prx="${prev%%|*}"
    rest="${prev#*|}"
    ptx="${rest%%|*}"
    pts="${rest##*|}"
    dt=$((now - pts))
    [ "$dt" -gt 0 ] 2>/dev/null || dt=1
    rx_delta=$((rx - prx))
    tx_delta=$((tx - ptx))
    [ "$rx_delta" -lt 0 ] && rx_delta=0
    [ "$tx_delta" -lt 0 ] && tx_delta=0
    total_delta=$((rx_delta + tx_delta))
    rx_speed=$((rx_delta / dt))
    tx_speed=$((tx_delta / dt))
    total_speed=$((total_delta / dt))
    printf '%s/s
%s/s
%s/s
' "$(human_bytes "$rx_speed")" "$(human_bytes "$tx_speed")" "$(human_bytes "$total_speed")"
}

get_user_live_iface() {
    local user="$1" state ifname fixed_vpn_ip
    state="$(get_session_state_line "$user" || true)"
    if [ -n "$state" ]; then
        ifname="$(printf '%s
' "$state" | awk -F'	' 'NF>=2{print $2; exit}')"
        if [ -n "$ifname" ] && ip link show dev "$ifname" >/dev/null 2>&1; then
            printf '%s
' "$ifname"
            return 0
        fi
    fi
    fixed_vpn_ip="$(get_user_vpn_ip "$user")"
    if [ -n "$fixed_vpn_ip" ]; then
        mapfile -t _live_iface < <(find_live_session_by_vpn_ip "$fixed_vpn_ip" 2>/dev/null || true)
        if [ "${#_live_iface[@]}" -ge 1 ] && [ -n "${_live_iface[0]}" ]; then
            printf '%s
' "${_live_iface[0]}"
            return 0
        fi
    fi
    return 1
}

apply_tc_limit_for_iface() {
    local ifname="$1" rate="$2"
    [ -n "$ifname" ] || return 1
    [ -n "$rate" ] || return 1
    command -v tc >/dev/null 2>&1 || return 1
    ip link show dev "$ifname" >/dev/null 2>&1 || return 1

    tc qdisc del dev "$ifname" root 2>/dev/null || true
    tc qdisc del dev "$ifname" ingress 2>/dev/null || true

    tc qdisc add dev "$ifname" root handle 1: htb default 10 2>/dev/null || true
    tc class add dev "$ifname" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" burst 256k cburst 256k 2>/dev/null || true
    tc qdisc add dev "$ifname" parent 1:10 handle 10: fq_codel 2>/dev/null || true

    tc qdisc add dev "$ifname" handle ffff: ingress 2>/dev/null || true
    tc filter add dev "$ifname" parent ffff: protocol all prio 10 u32 \
        match u32 0 0 police rate "${rate}mbit" burst 256k mtu 64kb drop flowid :1 2>/dev/null || true
}

clear_tc_limit_for_iface() {
    local ifname="$1"
    [ -n "$ifname" ] || return 0
    command -v tc >/dev/null 2>&1 || return 0
    tc qdisc del dev "$ifname" root 2>/dev/null || true
    tc qdisc del dev "$ifname" ingress 2>/dev/null || true
}

show_rate_limit_rules() {
    local user rate iface
    if [ ! -s "$RATE_LIMIT_FILE" ]; then
        echo "暂无限速规则"
        return 0
    fi
    printf "%-16s %-12s %-12s %-10s
" "用户" "限速(Mbit)" "在线接口" "状态"
    printf "%-16s %-12s %-12s %-10s
" "----------------" "------------" "------------" "----------"
    while IFS='=' read -r user rate; do
        [ -n "$user" ] || continue
        iface="$(get_user_live_iface "$user" || true)"
        if [ -n "$iface" ]; then
            printf "%-16s %-12s %-12s %-10s
" "$user" "$rate" "$iface" "已应用"
        else
            printf "%-16s %-12s %-12s %-10s
" "$user" "$rate" "-" "待上线"
        fi
    done < "$RATE_LIMIT_FILE"
}

# ===== 增强功能：限速 =====
rate_limit_apply() {
    local user="$1" mbit="$2" live_iface=""
    mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d
    touch "$RATE_LIMIT_FILE"

    awk -F= -v u="$user" '!(NF>=1 && $1==u)' "$RATE_LIMIT_FILE" > "${RATE_LIMIT_FILE}.tmp" 2>/dev/null || true
    if [ "$mbit" -gt 0 ]; then
        echo "${user}=${mbit}" >> "${RATE_LIMIT_FILE}.tmp"
    fi
    mv -f "${RATE_LIMIT_FILE}.tmp" "$RATE_LIMIT_FILE"
    chmod 600 "$RATE_LIMIT_FILE" || true

    cat > "$RATE_LIMIT_HOOK_UP" <<'EOUP'
#!/bin/bash
set -e
LIMIT_FILE="/etc/ppp/l2tp-user-limits.conf"
[ -f "$LIMIT_FILE" ] || exit 0
USER_NAME="${PEERNAME:-${6:-}}"
[ -n "$USER_NAME" ] || exit 0
RATE="$(awk -F= -v u="$USER_NAME" '$1==u{print $2; exit}' "$LIMIT_FILE")"
[ -n "$RATE" ] || exit 0
IFACE="${PPP_IFACE:-${IFNAME:-${1:-}}}"
[ -n "$IFACE" ] || exit 0
command -v tc >/dev/null 2>&1 || exit 0
ip link show dev "$IFACE" >/dev/null 2>&1 || exit 0

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true

tc qdisc add dev "$IFACE" root handle 1: htb default 10 2>/dev/null || true
tc class add dev "$IFACE" parent 1: classid 1:10 htb rate "${RATE}mbit" ceil "${RATE}mbit" burst 256k cburst 256k 2>/dev/null || true
tc qdisc add dev "$IFACE" parent 1:10 handle 10: fq_codel 2>/dev/null || true

tc qdisc add dev "$IFACE" handle ffff: ingress 2>/dev/null || true
tc filter add dev "$IFACE" parent ffff: protocol all prio 10 u32     match u32 0 0 police rate "${RATE}mbit" burst 256k mtu 64kb drop flowid :1 2>/dev/null || true
EOUP

    cat > "$RATE_LIMIT_HOOK_DOWN" <<'EODOWN'
#!/bin/bash
set -e
IFACE="${PPP_IFACE:-${IFNAME:-${1:-}}}"
[ -n "$IFACE" ] || exit 0
command -v tc >/dev/null 2>&1 || exit 0
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
EODOWN

    chmod +x "$RATE_LIMIT_HOOK_UP" "$RATE_LIMIT_HOOK_DOWN"

    live_iface="$(get_user_live_iface "$user" || true)"
    if [ "$mbit" -gt 0 ]; then
        if [ -n "$live_iface" ]; then
            if apply_tc_limit_for_iface "$live_iface" "$mbit"; then
                echo "✅ 已设置用户 ${user} 限速 ${mbit} Mbit/s（已即时应用到 ${live_iface}）"
            else
                echo "⚠️ 已写入用户 ${user} 限速 ${mbit} Mbit/s，但即时应用失败；用户重连后会自动生效"
            fi
        else
            echo "✅ 已设置用户 ${user} 限速 ${mbit} Mbit/s（用户下次上线自动生效）"
        fi
    else
        [ -n "$live_iface" ] && clear_tc_limit_for_iface "$live_iface"
        echo "✅ 已取消用户 ${user} 限速"
    fi
}


select_existing_user() {
    local prompt="${1:-请选择用户编号: }"
    local users selected
    mapfile -t users < <(awk '!/^[[:space:]]*#/ && NF>=1 {print $1}' "$VPN_USER_FILE" 2>/dev/null | awk '!seen[$0]++')
    if [ "${#users[@]}" -eq 0 ]; then
        echo "❌ 当前没有可选用户" >&2
        return 1
    fi
    echo "===================================="
    echo "请选择用户"
    echo "===================================="
    for i in "${!users[@]}"; do
        echo "$((i+1)). ${users[$i]}"
    done
    read -rp "$prompt" selected
    if ! echo "$selected" | grep -Eq '^[0-9]+$'; then
        echo "❌ 请输入有效编号" >&2
        return 1
    fi
    if [ "$selected" -lt 1 ] || [ "$selected" -gt "${#users[@]}" ]; then
        echo "❌ 编号超出范围" >&2
        return 1
    fi
    printf '%s\n' "${users[$((selected-1))]}"
}

prompt_rate_limit() {
    local user mbit
    user="$(select_existing_user_by_number "请选择要设置限速的用户编号")" || return 1
    [ -n "$user" ] || return 1
    read -rp "请输入用户 ${user} 的限速值（Mbit/s，输入 0 取消）: " mbit
    echo "$mbit" | grep -Eq '^[0-9]+$' || { echo "❌ 请输入数字"; return 1; }
    rate_limit_apply "$user" "$mbit"
}

# ===== 增强功能：实时状态 =====
show_user_realtime_status_once() {
    local now users user state exit_ip fixed_vpn_ip
    local parsed=() live=() ifname="" vpn_ip="" local_ip="" connect_ts="" rx="" tx="" rx_speed="" tx_speed="" total_speed="" total_used="" up_secs="" uptime="" conns=""
    now="$(date +%s)"

    printf "%-16s %-7s %-8s %-15s %-15s %-12s %-12s %-12s %-12s %-6s %-10s
"         "用户" "在线" "接口" "VPN_IP" "出口IP" "下载速率" "上传速率" "总速率" "累计流量" "连接" "在线时长"
    printf "%-16s %-7s %-8s %-15s %-15s %-12s %-12s %-12s %-12s %-6s %-10s
"         "----------------" "-------" "--------" "---------------" "---------------" "------------" "------------" "------------" "------------" "------" "----------"

    users="$(list_existing_users)"
    [ -n "$users" ] || { echo "暂无用户"; return 0; }

    while read -r user; do
        [ -n "$user" ] || continue
        exit_ip="$(get_user_effective_exit_ip "$user")"
        [ -n "$exit_ip" ] || exit_ip="$IP"
        fixed_vpn_ip="$(get_user_vpn_ip "$user")"
        [ -n "$fixed_vpn_ip" ] || fixed_vpn_ip="-"

        ifname=""
        vpn_ip=""
        local_ip=""
        connect_ts=""

        state="$(get_session_state_line "$user" || true)"
        if [ -n "$state" ]; then
            mapfile -t parsed < <(parse_session_state_line "$state" 2>/dev/null || true)
            ifname="${parsed[1]:-}"
            vpn_ip="${parsed[2]:-}"
            local_ip="${parsed[3]:-}"
            connect_ts="${parsed[4]:-}"
        fi

        if [ -n "$fixed_vpn_ip" ] && [ "$fixed_vpn_ip" != "-" ]; then
            mapfile -t live < <(find_live_session_by_vpn_ip "$fixed_vpn_ip" 2>/dev/null || true)
            if [ "${#live[@]}" -ge 4 ]; then
                ifname="${live[0]}"
                vpn_ip="${live[1]}"
                local_ip="${live[2]}"
                connect_ts="${live[3]}"
                if ! echo "${connect_ts:-}" | grep -Eq '^[0-9]+$'; then
                    connect_ts="$(get_iface_start_timestamp "$ifname")"
                fi
                rx="$(cat "/sys/class/net/${ifname}/statistics/rx_bytes" 2>/dev/null || echo 0)"
                tx="$(cat "/sys/class/net/${ifname}/statistics/tx_bytes" 2>/dev/null || echo 0)"
                mapfile -t _rates < <(calc_iface_rates "$ifname" "$rx" "$tx" "$now")
                rx_speed="${_rates[0]:-0B/s}"
                tx_speed="${_rates[1]:-0B/s}"
                total_speed="${_rates[2]:-0B/s}"
                total_used="$(human_bytes "$((rx + tx))")"
                up_secs=$((now - connect_ts))
                [ "$up_secs" -lt 0 ] && up_secs=0
                uptime="$(human_duration "$up_secs")"
                if command -v conntrack >/dev/null 2>&1; then
                    conns="$(conntrack -L 2>/dev/null | grep -F "$fixed_vpn_ip" | wc -l | awk '{print $1}')"
                else
                    conns="0"
                fi
                printf "%-16s %-7s %-8s %-15s %-15s %-12s %-12s %-12s %-12s %-6s %-10s
"                     "$user" "yes" "$ifname" "$fixed_vpn_ip" "$exit_ip" "$rx_speed" "$tx_speed" "$total_speed" "$total_used" "$conns" "$uptime"
                continue
            fi
        fi

        printf "%-16s %-7s %-8s %-15s %-15s %-12s %-12s %-12s %-12s %-6s %-10s
"             "$user" "no" "-" "$fixed_vpn_ip" "$exit_ip" "-" "-" "-" "-" "0" "-"
    done <<< "$users"
}

show_user_realtime_status() {
    trap 'echo; return 0' INT
    while true; do
        clear 2>/dev/null || true
        echo "==============================================="
        echo "用户实时状态（Ctrl+C 返回）"
        echo "==============================================="
        show_user_realtime_status_once
        sleep 2
    done
}

# ===== 增强功能：诊断 / 修复 / 报告 =====
install_idle_keepalive() {
    mkdir -p /usr/local/sbin /etc/systemd/system

    if [ "$KEEPALIVE_MODE" = "disabled" ]; then
        cat > "$KEEPALIVE_SCRIPT" <<'EOF2'
#!/bin/bash
# 稳定优先：禁用外部 keepalive，避免状态文件不同步时误清会话
exit 0
EOF2
        chmod +x "$KEEPALIVE_SCRIPT"

        cat > "$KEEPALIVE_SERVICE" <<EOF2
[Unit]
Description=L2TP idle keepalive (disabled for stability-first mode)
After=network-online.target xl2tpd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$KEEPALIVE_SCRIPT
EOF2

        cat > "$KEEPALIVE_TIMER" <<'EOF2'
[Unit]
Description=L2TP idle keepalive timer (disabled by default)

[Timer]
OnBootSec=1h
OnUnitActiveSec=1h
AccuracySec=1min
Unit=l2tp-idle-keepalive.service

[Install]
WantedBy=timers.target
EOF2

        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl disable --now l2tp-idle-keepalive.timer >/dev/null 2>&1 || true
        systemctl disable --now l2tp-idle-keepalive.service >/dev/null 2>&1 || true
        return 0
    fi

    cat > "$KEEPALIVE_SCRIPT" <<'EOF2'
#!/bin/bash
set -e

SESSION_STATE_FILE="/etc/ppp/l2tp-session-state.conf"
FAIL_DIR="/run/l2tp-keepalive-fails"
mkdir -p "$FAIL_DIR"
[ -f "$SESSION_STATE_FILE" ] || exit 0

while IFS=$'	' read -r user ifname vpn_ip local_ip connect_ts; do
    [ -n "${user:-}" ] || continue
    [ -n "${vpn_ip:-}" ] || continue
    echo "$vpn_ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || continue

    fail_file="$FAIL_DIR/${user}.fail"
    fails=0
    [ -f "$fail_file" ] && fails="$(cat "$fail_file" 2>/dev/null || echo 0)"
    echo "$fails" | grep -Eq '^[0-9]+$' || fails=0

    iface_ok=0
    if [ -n "${ifname:-}" ] && ip link show "$ifname" >/dev/null 2>&1; then
        iface_ok=1
    fi

    if ping -c 1 -W 1 "$vpn_ip" >/dev/null 2>&1; then
        echo 0 > "$fail_file"
        continue
    fi

    fails=$((fails + 1))
    echo "$fails" > "$fail_file"

    if [ "$iface_ok" -eq 0 ] && [ "$fails" -ge 3 ]; then
        tmpf="$(mktemp)"
        awk -F'	' -v u="$user" 'BEGIN{OFS="	"} $1!=u {print $0}' "$SESSION_STATE_FILE" > "$tmpf" 2>/dev/null || true
        cat "$tmpf" > "$SESSION_STATE_FILE" 2>/dev/null || true
        rm -f "$tmpf"
        echo 0 > "$fail_file"
    fi
done < "$SESSION_STATE_FILE"
EOF2
    chmod +x "$KEEPALIVE_SCRIPT"

    cat > "$KEEPALIVE_SERVICE" <<EOF2
[Unit]
Description=L2TP idle keepalive
After=network-online.target xl2tpd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$KEEPALIVE_SCRIPT
EOF2

    cat > "$KEEPALIVE_TIMER" <<'EOF2'
[Unit]
Description=Run L2TP idle keepalive every 10 seconds

[Timer]
OnBootSec=10s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=l2tp-idle-keepalive.service

[Install]
WantedBy=timers.target
EOF2

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now l2tp-idle-keepalive.timer >/dev/null 2>&1 || true
}

apply_nat_rules() {
    [ -n "$WAN_IFACE" ] || WAN_IFACE="$(ip route | awk '/default/ {print $5; exit}')"
    require_iptables || return 1

    "$IPT" -t nat -C POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || "$IPT" -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    "$IPT" -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || "$IPT" -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    "$IPT" -C FORWARD -s 10.50.60.0/24 -j ACCEPT 2>/dev/null || "$IPT" -A FORWARD -s 10.50.60.0/24 -j ACCEPT

    # 修正 L2TP/IPsec 场景下的 TCP 分片与 PMTU 问题，避免大包卡顿/异常
    "$IPT" -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -s 10.50.60.0/24 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || "$IPT" -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -s 10.50.60.0/24 -j TCPMSS --clamp-mss-to-pmtu
    "$IPT" -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -d 10.50.60.0/24 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || "$IPT" -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -d 10.50.60.0/24 -j TCPMSS --clamp-mss-to-pmtu

    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    command -v service >/dev/null 2>&1 && service iptables save >/dev/null 2>&1 || true
}

diag() {
    echo "===================================="
    echo "### 自动诊断（只读）###"
    echo "时间: $(date '+%F %T')"
    echo "系统: $OS"
    echo "服务器IP: $IP"
    echo "默认网卡: ${WAN_IFACE:-unknown}"
    echo "SSH端口: $SSH_PORT"
    echo "===================================="

    echo "[1] 监听端口"
    ss -lunp 2>/dev/null | egrep ':(500|4500|1701)\b' || true

    echo
    echo "[2] 服务状态"
    systemctl is-active "$IPSEC_SERVICE" >/dev/null 2>&1 && echo "OK: $IPSEC_SERVICE" || echo "WARN: $IPSEC_SERVICE 未运行"
    systemctl is-active xl2tpd >/dev/null 2>&1 && echo "OK: xl2tpd" || echo "WARN: xl2tpd 未运行"

    echo
    echo "[3] 内核转发"
    sysctl net.ipv4.ip_forward 2>/dev/null || true

    echo
    echo "[4] 关键配置文件"
    ls -l "$VPN_USER_FILE" "$IPSEC_SECRET_FILE" "$IPSEC_CONF_FILE" "$XL2TPD_CONF_FILE" "$PPP_OPTIONS_FILE" 2>/dev/null || true

    echo
    echo "[5] NAT / FORWARD 规则"
    require_iptables && "$IPT" -t nat -S 2>/dev/null || true
    echo
    require_iptables && "$IPT" -S FORWARD 2>/dev/null || true

    echo
    echo "[6] 最近日志"
    journalctl -u "$IPSEC_SERVICE" -n 30 --no-pager 2>/dev/null || true
    echo
    journalctl -u xl2tpd -n 30 --no-pager 2>/dev/null || true
    echo "===================================="
}

repair() {
    echo "### 一键修复 ###"
    echo "1) 重新开启内核转发"
    echo "net.ipv4.ip_forward = 1" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

    echo "2) 重新应用 NAT/转发规则"
    apply_nat_rules

    echo "3) 重启 VPN 服务"
    systemctl restart "$IPSEC_SERVICE" >/dev/null 2>&1 || true
    systemctl restart xl2tpd >/dev/null 2>&1 || true

    echo "4) 确保开机启动"
    systemctl enable "$IPSEC_SERVICE" >/dev/null 2>&1 || true
    systemctl enable xl2tpd >/dev/null 2>&1 || true

    echo "✅ 修复步骤已执行"
}


enhanced_menu() {
    while true; do
        echo "============== 增强功能菜单 =============="
        echo "1. 设置单用户限速"
        echo "2. 查看限速规则"
        echo "3. 删除限速规则"
        echo "4. 智能修复"
        echo "5. 服务状态检查"
        echo "6. 网络端口检查"
        echo "7. 用户实时状态"
        echo "0. 返回上级菜单"
        read -rp "请选择操作: " opt
        case "$opt" in
            1) prompt_rate_limit ;;
            2) show_rate_limit_rules ;;
            3)
                u="$(select_existing_user_by_number "请选择要删除限速规则的用户编号")" || true
                [ -n "$u" ] && rate_limit_apply "$u" 0 || echo "❌ 未选择有效用户"
                ;;
            4) repair ;;
            5)
                systemctl status "$IPSEC_SERVICE" --no-pager -l 2>/dev/null || true
                systemctl status xl2tpd --no-pager -l 2>/dev/null || true
                ;;
            6) ss -lunp 2>/dev/null | grep -E ':(500|4500|1701)\b' || true ;;
            7) show_user_realtime_status ;;
            0) return 0 ;;
            *) echo "❌ 无效选项" ;;
        esac
        safe_pause
    done
}

# ===== 主管理菜单（以 l2tp10-2 为主，增加增强菜单） =====
manage_menu() {
    while true; do
        echo "============== VPN 管理菜单 =============="
        echo "1. 添加用户"
        echo "2. 删除用户"
        echo "3. 查看所有用户和密码"
        echo "4. 卸载 VPN 服务"
        echo "5. 查看共享密钥"
        echo "6. 增强功能菜单"
        echo "7. 查看公网 IP 分配状态"
        echo "0. 退出"
        read -rp "请选择操作: " opt
        case "$opt" in
            1)
                u="$(gen_next_vpn_user)"
                p="$(gen_random_pass)"
                vpn_ip="$(create_user_with_auto_vpn_ip "$u" "$p")" || { echo "❌ VPN 地址池已用完"; safe_pause; continue; }
                echo "✅ 账号已自动创建"
                echo "👤 用户名：${u}"
                echo "🔑 密码：${p}"
                echo "🔒 固定 VPN 地址：${vpn_ip}"
                echo
                chosen_public_ip="$(choose_public_ip_for_user "$u")"
                if [ -n "$chosen_public_ip" ]; then
                    upsert_public_ip_mapping "$u" "$chosen_public_ip"
                    echo "🌐 已为用户 $u 绑定出口公网 IP: $chosen_public_ip"
                else
                    echo "⚠️ 未检测到公网 IP，用户 $u 将使用服务器默认出口"
                fi
                install_public_ip_hooks
                install_session_state_hooks
                echo "✅ 用户 $u 已添加"
                ;;
            2)
                echo "📋 当前用户:"
                mapfile -t user_list < <(awk '!/^[[:space:]]*#/ && NF>=1 {print $1}' "$VPN_USER_FILE" 2>/dev/null | awk '!seen[$0]++')
                if [ "${#user_list[@]}" -eq 0 ]; then
                    echo "❌ 当前没有用户"
                else
                    for i in "${!user_list[@]}"; do
                        echo "$((i+1)). ${user_list[$i]}"
                    done
                    echo -n "🔎 输入要删除的用户序号: "; read -r del_index
                    if [[ "$del_index" =~ ^[0-9]+$ ]] && [ "$del_index" -ge 1 ] && [ "$del_index" -le "${#user_list[@]}" ]; then
                        del_user="${user_list[$((del_index-1))]}"
                        awk -v u="$del_user" '!(NF>=1 && $1==u)' "$VPN_USER_FILE" > "${VPN_USER_FILE}.tmp" 2>/dev/null || true
                        mv -f "${VPN_USER_FILE}.tmp" "$VPN_USER_FILE"
                        if [ -f "$RATE_LIMIT_FILE" ]; then
                            awk -F= -v u="$del_user" '!(NF>=1 && $1==u)' "$RATE_LIMIT_FILE" > "${RATE_LIMIT_FILE}.tmp" 2>/dev/null || true
                            mv -f "${RATE_LIMIT_FILE}.tmp" "$RATE_LIMIT_FILE"
                        fi
                        delete_public_ip_mapping "$del_user"
                        delete_user_vpn_ip_mapping "$del_user"
                        echo "✅ 用户 $del_user 已删除，相关出口公网 IP 与固定 VPN 地址绑定也已释放"
                    else
                        echo "❌ 无效序号"
                    fi
                fi
                ;;
            3)
                echo "📃 当前 VPN 用户和密码:"
                awk '!/^[[:space:]]*#/ && NF>=3 {print $1 "\t" $3 "\t" $4}' "$VPN_USER_FILE" 2>/dev/null | \
                while IFS=$'\t' read -r user pass vpn_ip; do
                    [ -n "$user" ] || continue
                    public_ip="$(get_user_public_ip "$user")"
                    [ -n "$public_ip" ] || public_ip="未绑定"
                    echo "👤 用户: ${user}    🔑 密码: ${pass}    🧷 固定VPN地址: ${vpn_ip:-未分配}    🌐 绑定公网IP: ${public_ip}"
                done
                ;;
            4)
                echo "⚠️ 确认要卸载 VPN 服务？(y/n)"; read -r c
                if [[ "$c" =~ ^[Yy]$ ]]; then
                    systemctl stop "$IPSEC_SERVICE" xl2tpd 2>/dev/null || true
                    systemctl disable xl2tpd 2>/dev/null || true
                    systemctl disable "$IPSEC_SERVICE" 2>/dev/null || true
                    if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
                        apt remove --purge -y xl2tpd libreswan ppp 2>/dev/null || true
                    else
                        yum remove -y xl2tpd libreswan ppp 2>/dev/null || true
                    fi
                    systemctl disable --now l2tp-idle-keepalive.timer >/dev/null 2>&1 || true
                    rm -f "$VPN_USER_FILE" "$IPSEC_SECRET_FILE" "$IPSEC_CONF_FILE" "$XL2TPD_CONF_FILE" "$PPP_OPTIONS_FILE" "$SYSCTL_FILE" "$RATE_LIMIT_FILE" "$RATE_LIMIT_HOOK_UP" "$RATE_LIMIT_HOOK_DOWN" "$KEEPALIVE_SCRIPT" "$KEEPALIVE_SERVICE" "$KEEPALIVE_TIMER"
                    echo "✅ VPN 服务已卸载"
                    exit 0
                fi
                ;;
            5)
                echo "🔐 当前 PSK 共享密钥:"
                grep -oP 'PSK "\K[^"]+' "$IPSEC_SECRET_FILE" 2>/dev/null || echo "未找到 PSK"
                ;;
            6) enhanced_menu ;;
            7) show_public_ip_allocations ;;
            0) exit 0 ;;
            *) echo "❌ 无效选项" ;;
        esac
        safe_pause
    done
}

run_self_check() {
    local missing=0
    echo "===================================="
    echo "L2TP 脚本自检"
    echo "===================================="
    echo "当前 profile: ${PROFILE_LABEL} (${PROFILE})"
    echo "DNS: ${PPP_DNS_1}, ${PPP_DNS_2}"
    echo "DPD: delay=${DPD_DELAY}s timeout=${DPD_TIMEOUT}s"
    echo "PPP: connect-delay=${CONNECT_DELAY} lcp-echo-interval=${LCP_ECHO_INTERVAL} lcp-echo-failure=${LCP_ECHO_FAILURE}"
    echo "KEEPALIVE_MODE: ${KEEPALIVE_MODE}"
    echo

    for cmd in awk sed grep ip iptables systemctl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "✅ 依赖检查: ${cmd}"
        else
            echo "⚠️ 依赖缺失: ${cmd}"
            missing=1
        fi
    done

    if [ -f "$VPN_USER_FILE" ] && [ -f "$IPSEC_CONF_FILE" ] && [ -f "$XL2TPD_CONF_FILE" ]; then
        echo "✅ 检测到已安装配置文件（可进入管理菜单）"
    else
        echo "ℹ️ 未检测到完整安装配置（将走安装流程）"
    fi

    echo "===================================="
    [ "$missing" -eq 0 ] && echo "自检完成：核心依赖已满足" || echo "自检完成：存在缺失依赖，请先补齐"
    echo "===================================="
}

# 已安装则进入管理菜单
if [ "$SELF_CHECK" -eq 1 ]; then
    run_self_check
    exit 0
fi

if vpn_installed; then
    install_public_ip_hooks
    install_session_state_hooks
    manage_menu
fi

# ===== 初始化安装部分（保留 l2tp10-2 为主） =====
if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
    apt update
    apt install -y xl2tpd libreswan ppp iptables-persistent net-tools iproute2 curl
elif [ "$OS" = "centos" ]; then
    yum install -y epel-release
    yum install -y xl2tpd libreswan ppp iptables iptables-services net-tools iproute curl
fi

VPN_PSK=$(openssl rand -hex 8)
VPN_USER="vpnuser"
VPN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 10)

cat > "$IPSEC_CONF_FILE" <<EOF2
config setup
#   nat_traversal=yes   一般情况下是注释掉，ipsec 协商不成功时，可以启用试试
#   ikev1-policy=accept   Ubuntu 22系统的时候需要注释掉，Debian 系统的时候需要启用。
    virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16
    protostack=netkey
    uniqueids=no

conn L2TP-PSK
    authby=secret
    pfs=no
    auto=add
    rekey=no
    keyingtries=%forever
    ikelifetime=8h
    keylife=1h
    type=transport
    left=$(hostname -I | awk '{print $1}')
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    ike=aes256-sha1;modp2048
    esp=aes256-sha1
    fragmentation=yes
    encapsulation=yes
    # DPD 调优：比旧版更积极探测，但仍保留一定容忍时间
    # 旧版是 clear/30/300；这里改成 hold/15/120，更接近“保活增强版”
    dpdaction=hold
    dpddelay=${DPD_DELAY}
    dpdtimeout=${DPD_TIMEOUT}
    ikev2=no
EOF2

echo "%any  %any  : PSK \"$VPN_PSK\"" > "$IPSEC_SECRET_FILE"

mkdir -p /etc/xl2tpd
cat > "$XL2TPD_CONF_FILE" <<EOF2
[global]
ipsec saref = yes
[lns default]
ip range = 10.50.60.10-10.50.60.100
local ip = 10.50.60.1
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TPVPN
ppp debug = yes
pppoptfile = $PPP_OPTIONS_FILE
length bit = yes
EOF2

mkdir -p /etc/ppp
cat > "$PPP_OPTIONS_FILE" <<EOF2
ipcp-accept-local
ipcp-accept-remote
ms-dns ${PPP_DNS_1}
ms-dns ${PPP_DNS_2}
noccp
auth
refuse-eap
refuse-pap
require-mschap-v2
noipdefault
# idle 0：禁止因“空闲”而主动断开
idle 0
# 与 pppol2tp / 常见 NAT-T 场景保持一致，避免协商时被覆盖造成不一致
mtu 1400
mru 1400
proxyarp
asyncmap 0
connect-delay ${CONNECT_DELAY}
novj
nopcomp
noaccomp
nobsdcomp
nodeflate
lock
hide-password
modem
debug
name l2tpd
# PPP 保活：统一按 profile 调整（增强版更积极；17.30 更稳）
${LCP_ADAPTIVE_LINE}lcp-echo-interval ${LCP_ECHO_INTERVAL}
lcp-echo-failure ${LCP_ECHO_FAILURE}
EOF2

DEFAULT_VPN_IP="10.50.60.10"
upsert_chap_user "$VPN_USER" "$VPN_PASS" "$DEFAULT_VPN_IP"
chmod 600 "$VPN_USER_FILE" "$IPSEC_SECRET_FILE" || true

install_public_ip_hooks
install_session_state_hooks
install_idle_keepalive
# 首次默认安装时，直接绑定第一个公网 IP；后续新增用户再交互选择
first_public_ip="$(list_public_ipv4s | head -n1)"
if [ -n "$first_public_ip" ]; then
    upsert_public_ip_mapping "$VPN_USER" "$first_public_ip"
    echo "默认初始账号已自动绑定第一个公网 IP：$first_public_ip"
else
    echo "未检测到公网 IP，默认初始账号将使用服务器默认出口"
fi

echo "net.ipv4.ip_forward = 1" > "$SYSCTL_FILE"
sysctl -p "$SYSCTL_FILE"

apply_nat_rules

if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw; then
    FIREWALL="ufw"
elif command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables; then
    FIREWALL="nftables"
elif [ -n "$(get_iptables_cmd)" ]; then
    FIREWALL="iptables"
else
    FIREWALL="none"
fi

echo "🔐 检测防火墙: $FIREWALL"

case "$FIREWALL" in
    ufw)
        for PORT in "$SSH_PORT" 500 4500 1701; do
            ensure_firewall_port_open "$PORT"
        done
        ;;
    nftables)
        nft add table inet filter 2>/dev/null || true
        nft add chain inet filter input '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || true
        for PORT in "$SSH_PORT" 500 4500 1701; do
            ensure_firewall_port_open "$PORT"
        done
        nft list ruleset > /etc/nftables.conf 2>/dev/null || true
        ;;
    iptables)
        for PORT in "$SSH_PORT" 500 4500 1701; do
            ensure_firewall_port_open "$PORT"
        done
        netfilter-persistent save 2>/dev/null || service iptables save 2>/dev/null || true
        ;;
    none)
        echo "⚠️ 未找到可用防火墙系统，请确保端口已在云端配置"
        ;;
esac

systemctl restart "$IPSEC_SERVICE" || true
systemctl restart xl2tpd || true
systemctl enable "$IPSEC_SERVICE" || true
systemctl enable xl2tpd || true

echo "=========================================="
echo "🎉 VPN 安装成功！"
echo "📍 服务器 IP: $IP"
echo "🔐 PSK 密钥 : $VPN_PSK"
echo "👤 用户名   : $VPN_USER"
echo "🔑 密码     : $VPN_PASS"
echo "🧷 固定VPN地址: 10.50.60.10"
echo "✅ 连接方式 : L2TP/IPsec PSK"
echo "📋 再次运行本脚本可进入管理菜单"
echo "🧩 已融合增强菜单：限速 / 报告 / 修复 / 实时状态 / 公网IP分配状态"
echo "=========================================="
