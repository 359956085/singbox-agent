#!/usr/bin/env bash

# sing-box 无域名 Reality 管理脚本
# 作者：fengshi
# 许可证：GNU Affero 通用公共许可证第 3 版或更高版本

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.1.0"
readonly STATE_VERSION="1"
readonly OFFICIAL_KEY_URL="https://sing-box.app/gpg.key"
readonly OFFICIAL_REPO_URL="https://deb.sagernet.org/"

ROOT_PREFIX="${SBA_ROOT:-}"
APP_DIR="${ROOT_PREFIX}/etc/singbox-agent"
STATE_FILE="${APP_DIR}/state.conf"
URI_FILE="${APP_DIR}/vless-uri.txt"
QR_FILE="${APP_DIR}/vless.png"
SINGBOX_DIR="${ROOT_PREFIX}/etc/sing-box"
SINGBOX_CONFIG="${SINGBOX_DIR}/config.json"
WEB_DIR="${ROOT_PREFIX}/var/lib/singbox-agent/www"
WEB_CLASH_SUBSCRIPTION="${WEB_DIR}/clash.yaml"
WEB_VLESS_SUBSCRIPTION="${WEB_DIR}/vless.txt"
LEGACY_WEB_SUBSCRIPTION="${WEB_DIR}/subscription.txt"
NGINX_SITE_AVAILABLE="${ROOT_PREFIX}/etc/nginx/sites-available/singbox-agent-subscription"
NGINX_SITE_ENABLED="${ROOT_PREFIX}/etc/nginx/sites-enabled/singbox-agent-subscription"
MANAGER_DIR="${ROOT_PREFIX}/usr/local/lib/singbox-agent"
MANAGER_FILE="${MANAGER_DIR}/install.sh"
COMMAND_LINK="${ROOT_PREFIX}/usr/local/bin/sba"
APT_KEY_FILE="${ROOT_PREFIX}/etc/apt/keyrings/sagernet.asc"
APT_SOURCE_FILE="${ROOT_PREFIX}/etc/apt/sources.list.d/sagernet.sources"
CACHE_DIR="${ROOT_PREFIX}/var/cache/singbox-agent"

ROLLBACK_ACTIVE=0
TX_DIR=""
TX_UFW_REALITY_ADDED=0
TX_UFW_SUBSCRIPTION_ADDED=0
TX_SINGBOX_INSTALLED=0
TX_APT_KEY_CREATED=0
TX_APT_SOURCE_CREATED=0
UPDATE_TEMP_DIR=""
TX_SINGBOX_WAS_ACTIVE=0
TX_NGINX_WAS_ACTIVE=0

color_red='\033[31m'
color_green='\033[32m'
color_yellow='\033[33m'
color_blue='\033[36m'
color_reset='\033[0m'

info() { printf "%b[信息]%b %s\n" "$color_blue" "$color_reset" "$*"; }
success() { printf "%b[成功]%b %s\n" "$color_green" "$color_reset" "$*"; }
warn() { printf "%b[警告]%b %s\n" "$color_yellow" "$color_reset" "$*" >&2; }
error() { printf "%b[错误]%b %s\n" "$color_red" "$color_reset" "$*" >&2; }

cleanup_transaction() {
    if [[ -n "$TX_DIR" && "$TX_DIR" == /tmp/singbox-agent.* && -d "$TX_DIR" ]]; then
        rm -rf -- "$TX_DIR"
    fi
    TX_DIR=""
}

cleanup_update_temp() {
    if [[ -n "$UPDATE_TEMP_DIR" && "$UPDATE_TEMP_DIR" == /tmp/singbox-agent.update.* && -d "$UPDATE_TEMP_DIR" ]]; then
        rm -rf -- "$UPDATE_TEMP_DIR"
    fi
    UPDATE_TEMP_DIR=""
}

backup_path() {
    local path="$1"
    local name="$2"
    if [[ -e "$path" || -L "$path" ]]; then
        : >"${TX_DIR}/${name}.exists"
        cp -a -- "$path" "${TX_DIR}/${name}"
    fi
}

restore_path() {
    local path="$1"
    local name="$2"
    rm -f -- "$path"
    if [[ -f "${TX_DIR}/${name}.exists" ]]; then
        mkdir -p -- "$(dirname "$path")"
        cp -a -- "${TX_DIR}/${name}" "$path"
    fi
}

rollback_transaction() {
    [[ "$ROLLBACK_ACTIVE" == "1" ]] || return 0
    ROLLBACK_ACTIVE=0
    set +e
    warn "操作失败，正在恢复本项目修改。"
    restore_path "$SINGBOX_CONFIG" "singbox-config"
    restore_path "$NGINX_SITE_AVAILABLE" "nginx-site"
    restore_path "$NGINX_SITE_ENABLED" "nginx-link"
    restore_path "$WEB_CLASH_SUBSCRIPTION" "clash-subscription"
    restore_path "$WEB_VLESS_SUBSCRIPTION" "vless-subscription"
    restore_path "$LEGACY_WEB_SUBSCRIPTION" "legacy-subscription"
    restore_path "$URI_FILE" "uri"
    restore_path "$QR_FILE" "qr"
    restore_path "$STATE_FILE" "state"
    restore_path "$MANAGER_FILE" "manager"
    restore_path "$COMMAND_LINK" "command-link"
    rmdir "$WEB_DIR" "$(dirname "$WEB_DIR")" "$APP_DIR" "$MANAGER_DIR" 2>/dev/null
    if [[ "$TX_UFW_REALITY_ADDED" == "1" && -n "${REALITY_PORT:-}" ]]; then
        ufw --force delete allow "${REALITY_PORT}/tcp" >/dev/null 2>&1
    fi
    if [[ "$TX_UFW_SUBSCRIPTION_ADDED" == "1" && -n "${SUBSCRIPTION_PORT:-}" ]]; then
        ufw --force delete allow "${SUBSCRIPTION_PORT}/tcp" >/dev/null 2>&1
    fi
    if [[ "$TX_SINGBOX_INSTALLED" == "1" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y sing-box >/dev/null 2>&1
    fi
    [[ "$TX_APT_SOURCE_CREATED" == "1" ]] && rm -f -- "$APT_SOURCE_FILE"
    [[ "$TX_APT_KEY_CREATED" == "1" ]] && rm -f -- "$APT_KEY_FILE"
    if [[ "$TX_SINGBOX_WAS_ACTIVE" == "1" ]]; then
        systemctl restart sing-box.service >/dev/null 2>&1
    else
        systemctl stop sing-box.service >/dev/null 2>&1
    fi
    if [[ "$TX_NGINX_WAS_ACTIVE" == "1" ]]; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx.service >/dev/null 2>&1
    else
        systemctl stop nginx.service >/dev/null 2>&1
    fi
    cleanup_transaction
    set -e
}

fatal() {
    error "$*"
    rollback_transaction
    cleanup_update_temp
    exit 1
}

handle_error() {
    local code="$1"
    local line="$2"
    error "第 ${line} 行执行失败，退出码：${code}"
    rollback_transaction
    cleanup_update_temp
    exit "$code"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || fatal "请使用 root 用户运行。"
}

check_supported_system() {
    [[ -r /etc/os-release ]] || fatal "无法识别操作系统。"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) fatal "仅支持 Debian 或 Ubuntu。" ;;
    esac
    command_exists apt-get || fatal "未找到 apt-get。"
    command_exists systemctl || fatal "未找到 systemd。"
    [[ -d /run/systemd/system ]] || fatal "当前系统未运行 systemd。"
    case "$(dpkg --print-architecture 2>/dev/null)" in
        amd64|arm64) ;;
        *) fatal "仅支持 amd64 或 arm64。" ;;
    esac
}

validate_ipv4() {
    local ip="$1"
    local part
    local -a parts
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a parts <<<"$ip"
    [[ "${#parts[@]}" -eq 4 ]] || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

validate_ipv6() {
    local ip="$1"
    local without_compression group
    local group_count=0
    local -a groups
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$ip" != *:::* ]] || return 1
    [[ "$ip" != :* || "$ip" == ::* ]] || return 1
    [[ "$ip" != *: || "$ip" == *:: ]] || return 1
    without_compression="${ip/::/}"
    [[ "$without_compression" != *::* ]] || return 1
    IFS=':' read -r -a groups <<<"$ip"
    for group in "${groups[@]}"; do
        [[ -z "$group" ]] && continue
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        group_count=$((group_count + 1))
    done
    if [[ "$ip" == *::* ]]; then
        ((group_count < 8))
    else
        ((group_count == 8))
    fi
}

validate_ip() {
    validate_ipv4 "$1" || validate_ipv6 "$1"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((10#$port >= 1 && 10#$port <= 65535))
}

validate_hostname() {
    local host="${1,,}"
    local label
    local -a labels
    [[ ${#host} -le 253 && "$host" == *.* ]] || return 1
    [[ "$host" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    IFS='.' read -r -a labels <<<"$host"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" != -* && "$label" != *- ]] || return 1
    done
}

validate_node_name() {
    local name="$1"
    [[ -n "$name" && ${#name} -le 64 ]] || return 1
    [[ ! "$name" =~ [[:cntrl:]] ]]
}

port_in_use() {
    local port="$1"
    ss -H -ltn 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" { found=1 } END { exit !found }'
}

random_free_port() {
    local start="$1"
    local end="$2"
    local attempt port range
    range=$((end - start + 1))
    for ((attempt = 1; attempt <= 200; attempt++)); do
        port=$((start + (16#$(openssl rand -hex 2) % range)))
        if ! port_in_use "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done
    return 1
}

format_url_host() {
    if validate_ipv6 "$1"; then
        printf '[%s]' "$1"
    else
        printf '%s' "$1"
    fi
}

url_encode() {
    jq -nr --arg value "$1" '$value | @uri'
}

build_vless_uri() {
    local address node_encoded
    address="$(format_url_host "$PUBLIC_IP")"
    node_encoded="$(url_encode "$NODE_NAME")"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision#%s' \
        "$UUID" "$address" "$REALITY_PORT" "$REALITY_HOST" "$PUBLIC_KEY" "$SHORT_ID" "$node_encoded"
}

build_clash_subscription_url() {
    printf 'http://%s:%s/sub/%s' "$(format_url_host "$PUBLIC_IP")" "$SUBSCRIPTION_PORT" "$SUBSCRIPTION_TOKEN"
}

build_vless_subscription_url() {
    printf 'http://%s:%s/sub/%s/vless' "$(format_url_host "$PUBLIC_IP")" "$SUBSCRIPTION_PORT" "$SUBSCRIPTION_TOKEN"
}

detect_public_ip() {
    local ip
    ip="$(curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    ip="$(trim "$ip")"
    if validate_ipv4 "$ip"; then
        printf '%s' "$ip"
        return 0
    fi
    ip="$(curl -6fsS --connect-timeout 5 --max-time 8 https://api6.ipify.org 2>/dev/null || true)"
    ip="$(trim "$ip")"
    if validate_ipv6 "$ip"; then
        printf '%s' "$ip"
        return 0
    fi
    return 1
}

probe_reality_target() {
    local host="$1"
    local port="$2"
    local output
    output="$(timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" -tls1_3 \
        -verify_hostname "$host" -verify_return_error </dev/null 2>&1)" || return 1
    grep -Eq 'Verification: OK|Verify return code: 0 \(ok\)' <<<"$output"
}

choose_random_reality_target() {
    local candidate
    local -a candidates=(
        "addons.mozilla.org:443"
        "www.python.org:443"
        "www.oracle.com:443"
        "www.samsung.com:443"
        "www.amd.com:443"
        "www.swift.com:443"
    )
    while IFS= read -r candidate; do
        REALITY_HOST="${candidate%:*}"
        REALITY_DEST_PORT="${candidate##*:}"
        info "检测 Reality 目标：${REALITY_HOST}:${REALITY_DEST_PORT}"
        if probe_reality_target "$REALITY_HOST" "$REALITY_DEST_PORT"; then
            return 0
        fi
    done < <(printf '%s\n' "${candidates[@]}" | shuf)
    return 1
}

prompt_node_name() {
    local default_value="${1:-sing-box-reality}"
    local input
    while true; do
        read -r -p "节点名称 [${default_value}]：" input
        input="${input:-$default_value}"
        input="$(trim "$input")"
        if validate_node_name "$input"; then
            NODE_NAME="$input"
            return
        fi
        warn "节点名称必须为 1～64 个字符，且不能包含控制字符。"
    done
}

prompt_public_ip() {
    local default_value="${1:-}"
    local input
    if [[ -z "$default_value" ]]; then
        default_value="$(detect_public_ip || true)"
    fi
    while true; do
        read -r -p "公网 IP${default_value:+ [$default_value]}：" input
        input="${input:-$default_value}"
        input="$(trim "$input")"
        input="${input#[}"
        input="${input%]}"
        if validate_ip "$input"; then
            PUBLIC_IP="$input"
            if validate_ipv6 "$input"; then
                LISTEN_ADDRESS="::"
            else
                LISTEN_ADDRESS="0.0.0.0"
            fi
            return
        fi
        warn "请输入合法 IPv4 或 IPv6 地址。"
    done
}

prompt_port() {
    local variable_name="$1"
    local label="$2"
    local start="$3"
    local end="$4"
    local default_value="${5:-}"
    local allowed_current="${6:-}"
    local input selected
    while true; do
        if [[ -n "$default_value" ]]; then
            read -r -p "${label} [${default_value}]：" input
            selected="${input:-$default_value}"
        else
            read -r -p "${label} [回车随机]：" input
            selected="${input:-$(random_free_port "$start" "$end" || true)}"
        fi
        if ! validate_port "$selected"; then
            warn "端口必须在 1～65535。"
            continue
        fi
        if [[ "$selected" != "$allowed_current" ]] && port_in_use "$selected"; then
            warn "端口 ${selected} 已被占用。"
            continue
        fi
        printf -v "$variable_name" '%s' "$selected"
        return
    done
}

prompt_reality_target() {
    local default_host="${1:-}"
    local default_port="${2:-443}"
    local input host port
    while true; do
        if [[ -n "$default_host" ]]; then
            read -r -p "Reality 目标 SNI:端口 [${default_host}:${default_port}]：" input
            input="${input:-${default_host}:${default_port}}"
        else
            read -r -p "Reality 目标 SNI:端口 [回车自动选择]：" input
            if [[ -z "$input" ]]; then
                choose_random_reality_target && return
                warn "候选目标均不可用，请手工输入。"
                continue
            fi
        fi
        host="${input%:*}"
        port="${input##*:}"
        if [[ "$host" == "$input" ]]; then
            host="$input"
            port="443"
        fi
        host="${host,,}"
        if ! validate_hostname "$host" || ! validate_port "$port"; then
            warn "请输入合法域名和端口，例如 addons.mozilla.org:443。"
            continue
        fi
        info "验证 ${host}:${port} 的 TLS 1.3 和证书。"
        if probe_reality_target "$host" "$port"; then
            REALITY_HOST="$host"
            REALITY_DEST_PORT="$port"
            return
        fi
        warn "目标未通过 DNS、TLS 1.3 或证书校验。"
    done
}

state_get() {
    local key="$1"
    awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$STATE_FILE"
}

load_state() {
    [[ -f "$STATE_FILE" ]] || fatal "尚未安装。"
    [[ "$(state_get STATE_VERSION)" == "$STATE_VERSION" ]] || fatal "状态文件版本不受支持。"
    NODE_NAME="$(printf '%s' "$(state_get NODE_NAME_B64)" | base64 -d)"
    PUBLIC_IP="$(state_get PUBLIC_IP)"
    LISTEN_ADDRESS="$(state_get LISTEN_ADDRESS)"
    REALITY_PORT="$(state_get REALITY_PORT)"
    SUBSCRIPTION_PORT="$(state_get SUBSCRIPTION_PORT)"
    REALITY_HOST="$(state_get REALITY_HOST)"
    REALITY_DEST_PORT="$(state_get REALITY_DEST_PORT)"
    UUID="$(state_get UUID)"
    PRIVATE_KEY="$(state_get PRIVATE_KEY)"
    PUBLIC_KEY="$(state_get PUBLIC_KEY)"
    SHORT_ID="$(state_get SHORT_ID)"
    SUBSCRIPTION_TOKEN="$(state_get SUBSCRIPTION_TOKEN)"
    SINGBOX_INSTALLED_BY_SCRIPT="$(state_get SINGBOX_INSTALLED_BY_SCRIPT)"
    APT_KEY_CREATED="$(state_get APT_KEY_CREATED)"
    APT_SOURCE_CREATED="$(state_get APT_SOURCE_CREATED)"
    UFW_REALITY_RULE_CREATED="$(state_get UFW_REALITY_RULE_CREATED)"
    UFW_SUBSCRIPTION_RULE_CREATED="$(state_get UFW_SUBSCRIPTION_RULE_CREATED)"
    INSTALLED_VERSION="$(state_get INSTALLED_VERSION)"
}

write_state() {
    local temp node_b64
    mkdir -p -- "$APP_DIR"
    chmod 700 "$APP_DIR"
    node_b64="$(printf '%s' "$NODE_NAME" | base64 -w 0)"
    temp="$(mktemp "${APP_DIR}/.state.XXXXXX")"
    umask 077
    {
        printf 'STATE_VERSION=%s\n' "$STATE_VERSION"
        printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
        printf 'NODE_NAME_B64=%s\n' "$node_b64"
        printf 'PUBLIC_IP=%s\n' "$PUBLIC_IP"
        printf 'LISTEN_ADDRESS=%s\n' "$LISTEN_ADDRESS"
        printf 'REALITY_PORT=%s\n' "$REALITY_PORT"
        printf 'SUBSCRIPTION_PORT=%s\n' "$SUBSCRIPTION_PORT"
        printf 'REALITY_HOST=%s\n' "$REALITY_HOST"
        printf 'REALITY_DEST_PORT=%s\n' "$REALITY_DEST_PORT"
        printf 'UUID=%s\n' "$UUID"
        printf 'PRIVATE_KEY=%s\n' "$PRIVATE_KEY"
        printf 'PUBLIC_KEY=%s\n' "$PUBLIC_KEY"
        printf 'SHORT_ID=%s\n' "$SHORT_ID"
        printf 'SUBSCRIPTION_TOKEN=%s\n' "$SUBSCRIPTION_TOKEN"
        printf 'SINGBOX_INSTALLED_BY_SCRIPT=%s\n' "$SINGBOX_INSTALLED_BY_SCRIPT"
        printf 'APT_KEY_CREATED=%s\n' "$APT_KEY_CREATED"
        printf 'APT_SOURCE_CREATED=%s\n' "$APT_SOURCE_CREATED"
        printf 'UFW_REALITY_RULE_CREATED=%s\n' "$UFW_REALITY_RULE_CREATED"
        printf 'UFW_SUBSCRIPTION_RULE_CREATED=%s\n' "$UFW_SUBSCRIPTION_RULE_CREATED"
        printf 'INSTALLED_VERSION=%s\n' "$INSTALLED_VERSION"
    } >"$temp"
    chmod 600 "$temp"
    mv -f -- "$temp" "$STATE_FILE"
}

check_unmanaged_conflicts() {
    if [[ -e "$SINGBOX_CONFIG" || -e "$STATE_FILE" ]]; then
        fatal "发现现有 sing-box 或 singbox-agent 配置，拒绝接管。"
    fi
    if dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -q 'install ok installed'; then
        fatal "系统已安装 sing-box，拒绝接管。"
    fi
    if [[ -e "$NGINX_SITE_AVAILABLE" || -L "$NGINX_SITE_ENABLED" ]]; then
        fatal "发现同名 nginx 配置，拒绝覆盖。"
    fi
}

install_base_dependencies() {
    info "安装基础依赖。"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg openssl jq iproute2 nginx qrencode
    nginx -t
}

setup_official_repository() {
    local key_existed=0 source_existed=0
    [[ -e "$APT_KEY_FILE" ]] && key_existed=1
    [[ -e "$APT_SOURCE_FILE" ]] && source_existed=1
    if [[ "$key_existed" != "$source_existed" ]]; then
        fatal "sing-box APT 源状态不完整，请先人工处理。"
    fi
    if [[ "$source_existed" == "1" ]]; then
        grep -Fq "$OFFICIAL_REPO_URL" "$APT_SOURCE_FILE" || fatal "现有 sing-box APT 源不是官方地址。"
        grep -Fq "$APT_KEY_FILE" "$APT_SOURCE_FILE" || fatal "现有 sing-box APT 源未绑定预期密钥。"
        APT_KEY_CREATED=0
        APT_SOURCE_CREATED=0
        return
    fi
    info "添加 sing-box 官方 APT 源。"
    install -d -m 755 "$(dirname "$APT_KEY_FILE")" "$(dirname "$APT_SOURCE_FILE")"
    local key_temp source_temp
    key_temp="$(mktemp /tmp/singbox-agent.key.XXXXXX)"
    source_temp="$(mktemp /tmp/singbox-agent.source.XXXXXX)"
    curl --proto '=https' --tlsv1.2 -fsSL "$OFFICIAL_KEY_URL" -o "$key_temp"
    gpg --show-keys "$key_temp" >/dev/null 2>&1 || fatal "官方仓库密钥格式无效。"
    cat >"$source_temp" <<EOF
Types: deb
URIs: ${OFFICIAL_REPO_URL}
Suites: *
Components: *
Enabled: yes
Signed-By: ${APT_KEY_FILE}
EOF
    install -m 644 "$key_temp" "$APT_KEY_FILE"
    TX_APT_KEY_CREATED=1
    install -m 644 "$source_temp" "$APT_SOURCE_FILE"
    TX_APT_SOURCE_CREATED=1
    rm -f -- "$key_temp" "$source_temp"
    APT_KEY_CREATED=1
    APT_SOURCE_CREATED=1
}

install_singbox_package() {
    info "安装 sing-box 稳定版。"
    apt-get update
    TX_SINGBOX_INSTALLED=1
    DEBIAN_FRONTEND=noninteractive apt-get install -y sing-box
    SINGBOX_INSTALLED_BY_SCRIPT=1
    command_exists sing-box || fatal "sing-box 安装后不可执行。"
    systemctl cat sing-box.service >/dev/null 2>&1 || fatal "官方 sing-box.service 不存在。"
}

generate_credentials() {
    local key_output
    UUID="$(sing-box generate uuid | tr -d '\r\n')"
    key_output="$(sing-box generate reality-keypair)"
    PRIVATE_KEY="$(awk 'tolower($1) ~ /private/ { print $NF; exit }' <<<"$key_output")"
    PUBLIC_KEY="$(awk 'tolower($1) ~ /public/ { print $NF; exit }' <<<"$key_output")"
    SHORT_ID="$(openssl rand -hex 8)"
    SUBSCRIPTION_TOKEN="$(openssl rand -hex 32)"
    [[ "$UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || fatal "UUID 生成失败。"
    [[ "$PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || fatal "Reality 私钥解析失败。"
    [[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || fatal "Reality 公钥解析失败。"
    [[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || fatal "short ID 生成失败。"
}

render_singbox_config() {
    local output="$1"
    jq -n \
        --arg listen "$LISTEN_ADDRESS" \
        --argjson listen_port "$REALITY_PORT" \
        --arg name "$NODE_NAME" \
        --arg uuid "$UUID" \
        --arg server_name "$REALITY_HOST" \
        --arg handshake_server "$REALITY_HOST" \
        --argjson handshake_port "$REALITY_DEST_PORT" \
        --arg private_key "$PRIVATE_KEY" \
        --arg short_id "$SHORT_ID" \
        '{
            log: {level: "info", timestamp: true},
            inbounds: [{
                type: "vless",
                tag: "vless-reality-in",
                listen: $listen,
                listen_port: $listen_port,
                users: [{name: $name, uuid: $uuid, flow: "xtls-rprx-vision"}],
                tls: {
                    enabled: true,
                    server_name: $server_name,
                    reality: {
                        enabled: true,
                        handshake: {server: $handshake_server, server_port: $handshake_port},
                        private_key: $private_key,
                        short_id: [$short_id]
                    }
                }
            }],
            outbounds: [{type: "direct", tag: "direct"}]
        }' >"$output"
}

get_service_group() {
    local service_user service_group
    service_user="$(systemctl show sing-box.service -p User --value 2>/dev/null || true)"
    service_user="${service_user:-root}"
    if ! id "$service_user" >/dev/null 2>&1 && command_exists systemd-sysusers; then
        systemd-sysusers >/dev/null 2>&1 || true
    fi
    id "$service_user" >/dev/null 2>&1 || fatal "sing-box 服务用户 ${service_user} 不存在。"
    service_group="$(systemctl show sing-box.service -p Group --value 2>/dev/null || true)"
    service_group="${service_group:-$(id -gn "$service_user")}"
    getent group "$service_group" >/dev/null 2>&1 || fatal "sing-box 服务组 ${service_group} 不存在。"
    printf '%s' "$service_group"
}

install_singbox_config() {
    local temp service_group
    mkdir -p -- "$SINGBOX_DIR"
    temp="$(mktemp "${SINGBOX_DIR}/.config.json.XXXXXX")"
    render_singbox_config "$temp"
    sing-box check -c "$temp"
    service_group="$(get_service_group)"
    chown "root:${service_group}" "$temp"
    chmod 640 "$temp"
    mv -f -- "$temp" "$SINGBOX_CONFIG"
}

render_nginx_config() {
    local output="$1"
    local listen_directive
    if validate_ipv6 "$PUBLIC_IP"; then
        listen_directive="listen [::]:${SUBSCRIPTION_PORT} ipv6only=on default_server;"
    else
        listen_directive="listen ${SUBSCRIPTION_PORT} default_server;"
    fi
    cat >"$output" <<EOF
# 此文件由 singbox-agent 管理，请勿手工修改。
server {
    ${listen_directive}
    server_name _;
    server_tokens off;
    access_log off;

    location = /sub/${SUBSCRIPTION_TOKEN} {
        limit_except GET { deny all; }
        alias ${WEB_CLASH_SUBSCRIPTION};
        default_type application/yaml;
        add_header Cache-Control "no-store" always;
    }

    location = /sub/${SUBSCRIPTION_TOKEN}/vless {
        limit_except GET { deny all; }
        alias ${WEB_VLESS_SUBSCRIPTION};
        default_type text/plain;
        add_header Cache-Control "no-store" always;
    }

    location / {
        return 404;
    }
}
EOF
}

yaml_quote() {
    jq -Rn --arg value "$1" '$value'
}

render_mihomo_subscription() {
    local output="$1"
    local clash_node_name node_quoted server_quoted uuid_quoted sni_quoted public_key_quoted short_id_quoted
    clash_node_name="${NODE_NAME}-Reality"
    node_quoted="$(yaml_quote "$clash_node_name")"
    server_quoted="$(yaml_quote "$PUBLIC_IP")"
    uuid_quoted="$(yaml_quote "$UUID")"
    sni_quoted="$(yaml_quote "$REALITY_HOST")"
    public_key_quoted="$(yaml_quote "$PUBLIC_KEY")"
    short_id_quoted="$(yaml_quote "$SHORT_ID")"
    cat >"$output" <<EOF
proxies:
  - name: ${node_quoted}
    type: vless
    server: ${server_quoted}
    port: ${REALITY_PORT}
    uuid: ${uuid_quoted}
    network: tcp
    udp: true
    tls: true
    servername: ${sni_quoted}
    flow: xtls-rprx-vision
    packet-encoding: xudp
    client-fingerprint: chrome
    encryption: ""
    reality-opts:
      public-key: ${public_key_quoted}
      short-id: ${short_id_quoted}

proxy-groups:
  - name: "节点选择"
    type: select
    proxies:
      - ${node_quoted}
      - DIRECT

rules:
  - "MATCH,节点选择"
EOF
}

write_client_artifacts() {
    local uri clash_temp vless_temp uri_temp qr_temp
    uri="$(build_vless_uri)"
    mkdir -p -- "$APP_DIR" "$WEB_DIR"
    chmod 700 "$APP_DIR"
    chmod 711 "$(dirname "$WEB_DIR")" "$WEB_DIR"
    uri_temp="$(mktemp "${APP_DIR}/.uri.XXXXXX")"
    printf '%s\n' "$uri" >"$uri_temp"
    chmod 600 "$uri_temp"
    mv -f -- "$uri_temp" "$URI_FILE"
    qr_temp="$(mktemp "${APP_DIR}/.qr.XXXXXX")"
    qrencode -o "$qr_temp" -s 4 -m 1 "$uri"
    chmod 600 "$qr_temp"
    mv -f -- "$qr_temp" "$QR_FILE"
    clash_temp="$(mktemp "${WEB_DIR}/.clash.XXXXXX")"
    render_mihomo_subscription "$clash_temp"
    chmod 644 "$clash_temp"
    mv -f -- "$clash_temp" "$WEB_CLASH_SUBSCRIPTION"
    vless_temp="$(mktemp "${WEB_DIR}/.vless.XXXXXX")"
    printf '%s\n' "$uri" | base64 -w 0 >"$vless_temp"
    printf '\n' >>"$vless_temp"
    chmod 644 "$vless_temp"
    mv -f -- "$vless_temp" "$WEB_VLESS_SUBSCRIPTION"
}

install_nginx_config() {
    local temp nginx_dump
    mkdir -p -- "$(dirname "$NGINX_SITE_AVAILABLE")" "$(dirname "$NGINX_SITE_ENABLED")"
    temp="$(mktemp "$(dirname "$NGINX_SITE_AVAILABLE")/.singbox-agent.XXXXXX")"
    render_nginx_config "$temp"
    chmod 644 "$temp"
    mv -f -- "$temp" "$NGINX_SITE_AVAILABLE"
    ln -sfn "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED"
    nginx -t
    nginx_dump="$(nginx -T 2>&1)"
    grep -Fq "location = /sub/${SUBSCRIPTION_TOKEN}" <<<"$nginx_dump" || fatal "nginx 未加载 sites-enabled 配置。"
    grep -Fq "location = /sub/${SUBSCRIPTION_TOKEN}/vless" <<<"$nginx_dump" || fatal "nginx 未加载 Base64 VLESS 订阅配置。"
}

ufw_is_active() {
    command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'
}

ufw_has_rule() {
    local port="$1"
    ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)"
}

add_ufw_rule() {
    local port="$1"
    local flag_name="$2"
    if ! ufw_is_active || ufw_has_rule "$port"; then
        printf -v "$flag_name" '%s' "0"
        return
    fi
    if ufw allow "${port}/tcp" comment 'singbox-agent' >/dev/null; then
        printf -v "$flag_name" '%s' "1"
    else
        warn "UFW 规则添加失败：${port}/tcp。"
        printf -v "$flag_name" '%s' "0"
    fi
}

remove_owned_ufw_rule() {
    local port="$1"
    local owned="$2"
    if [[ "$owned" == "1" ]] && command_exists ufw; then
        ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true
    fi
}

install_manager() {
    local source_file
    source_file="$(readlink -f "${BASH_SOURCE[0]}")"
    mkdir -p -- "$MANAGER_DIR" "$(dirname "$COMMAND_LINK")"
    if [[ "$source_file" != "$MANAGER_FILE" ]]; then
        install -m 755 "$source_file" "$MANAGER_FILE"
    fi
    ln -sfn "$MANAGER_FILE" "$COMMAND_LINK"
}

start_services() {
    systemctl enable sing-box.service >/dev/null
    systemctl restart sing-box.service
    sleep 2
    systemctl is-active --quiet sing-box.service || fatal "sing-box 启动失败。"
    if systemctl is-active --quiet nginx.service; then
        systemctl reload nginx.service
    else
        systemctl enable --now nginx.service
    fi
    systemctl is-active --quiet nginx.service || fatal "nginx 启动失败。"
}

begin_transaction() {
    TX_DIR="$(mktemp -d /tmp/singbox-agent.XXXXXX)"
    systemctl is-active --quiet sing-box.service 2>/dev/null && TX_SINGBOX_WAS_ACTIVE=1
    systemctl is-active --quiet nginx.service 2>/dev/null && TX_NGINX_WAS_ACTIVE=1
    backup_path "$SINGBOX_CONFIG" "singbox-config"
    backup_path "$NGINX_SITE_AVAILABLE" "nginx-site"
    backup_path "$NGINX_SITE_ENABLED" "nginx-link"
    backup_path "$WEB_CLASH_SUBSCRIPTION" "clash-subscription"
    backup_path "$WEB_VLESS_SUBSCRIPTION" "vless-subscription"
    backup_path "$LEGACY_WEB_SUBSCRIPTION" "legacy-subscription"
    backup_path "$URI_FILE" "uri"
    backup_path "$QR_FILE" "qr"
    backup_path "$STATE_FILE" "state"
    backup_path "$MANAGER_FILE" "manager"
    backup_path "$COMMAND_LINK" "command-link"
    ROLLBACK_ACTIVE=1
    trap 'handle_error $? $LINENO' ERR
    trap 'handle_error 130 $LINENO' INT TERM
}

finish_transaction() {
    ROLLBACK_ACTIVE=0
    trap - ERR INT TERM
    cleanup_transaction
}

configure_installation() {
    local managed="$1"
    local old_reality_port=""
    local old_subscription_port=""
    local old_ufw_reality=0
    local old_ufw_subscription=0
    local default_node="sing-box-reality"
    local default_ip=""
    local default_reality_port=""
    local default_subscription_port=""
    local default_host=""
    local default_host_port="443"

    if [[ "$managed" == "1" ]]; then
        load_state
        default_node="$NODE_NAME"
        default_ip="$PUBLIC_IP"
        default_reality_port="$REALITY_PORT"
        default_subscription_port="$SUBSCRIPTION_PORT"
        default_host="$REALITY_HOST"
        default_host_port="$REALITY_DEST_PORT"
        old_reality_port="$REALITY_PORT"
        old_subscription_port="$SUBSCRIPTION_PORT"
        old_ufw_reality="$UFW_REALITY_RULE_CREATED"
        old_ufw_subscription="$UFW_SUBSCRIPTION_RULE_CREATED"
    fi

    prompt_node_name "$default_node"
    prompt_public_ip "$default_ip"
    prompt_port REALITY_PORT "Reality 端口" 20000 39999 "$default_reality_port" "$old_reality_port"
    while true; do
        prompt_port SUBSCRIPTION_PORT "订阅 HTTP 端口" 40000 59999 "$default_subscription_port" "$old_subscription_port"
        [[ "$REALITY_PORT" != "$SUBSCRIPTION_PORT" ]] && break
        warn "Reality 与订阅端口不能相同。"
        default_subscription_port=""
    done
    prompt_reality_target "$default_host" "$default_host_port"

    if [[ "$managed" != "1" ]]; then
        generate_credentials
    fi

    if [[ "$ROLLBACK_ACTIVE" != "1" ]]; then
        begin_transaction
    fi
    install_singbox_config
    write_client_artifacts
    install_nginx_config
    start_services
    rm -f -- "$LEGACY_WEB_SUBSCRIPTION"

    UFW_REALITY_RULE_CREATED=0
    UFW_SUBSCRIPTION_RULE_CREATED=0
    add_ufw_rule "$REALITY_PORT" UFW_REALITY_RULE_CREATED
    add_ufw_rule "$SUBSCRIPTION_PORT" UFW_SUBSCRIPTION_RULE_CREATED
    TX_UFW_REALITY_ADDED="$UFW_REALITY_RULE_CREATED"
    TX_UFW_SUBSCRIPTION_ADDED="$UFW_SUBSCRIPTION_RULE_CREATED"

    if [[ "$managed" == "1" ]]; then
        if [[ "$old_reality_port" == "$REALITY_PORT" && "$old_ufw_reality" == "1" ]]; then
            UFW_REALITY_RULE_CREATED=1
            TX_UFW_REALITY_ADDED=0
        fi
        if [[ "$old_subscription_port" == "$SUBSCRIPTION_PORT" && "$old_ufw_subscription" == "1" ]]; then
            UFW_SUBSCRIPTION_RULE_CREATED=1
            TX_UFW_SUBSCRIPTION_ADDED=0
        fi
    fi

    INSTALLED_VERSION="$(sing-box version | awk '/sing-box version/ {print $3; exit}')"
    install_manager
    write_state
    finish_transaction
    if [[ "$managed" == "1" ]]; then
        [[ "$old_reality_port" == "$REALITY_PORT" ]] || remove_owned_ufw_rule "$old_reality_port" "$old_ufw_reality"
        [[ "$old_subscription_port" == "$SUBSCRIPTION_PORT" ]] || remove_owned_ufw_rule "$old_subscription_port" "$old_ufw_subscription"
    fi
    success "配置完成。"
    show_configuration
}

install_command() {
    require_root
    check_supported_system
    [[ -t 0 ]] || fatal "安装需要交互式终端。"
    if [[ -f "$STATE_FILE" ]]; then
        info "检测到本项目安装，进入重新配置。现有 UUID、密钥和订阅令牌保持不变。"
        configure_installation 1
        return
    fi
    check_unmanaged_conflicts
    begin_transaction
    install_base_dependencies
    setup_official_repository
    install_singbox_package
    configure_installation 0
}

show_configuration() {
    local uri clash_subscription_url vless_subscription_url singbox_status nginx_status version
    load_state
    uri="$(build_vless_uri)"
    clash_subscription_url="$(build_clash_subscription_url)"
    vless_subscription_url="$(build_vless_subscription_url)"
    singbox_status="$(systemctl is-active sing-box.service 2>/dev/null || true)"
    nginx_status="$(systemctl is-active nginx.service 2>/dev/null || true)"
    version="$(sing-box version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')"
    printf '\n%b===== singbox-agent =====%b\n' "$color_blue" "$color_reset"
    printf 'sing-box：%s（%s）\n' "${singbox_status:-未知}" "${version:-未知版本}"
    printf 'nginx：%s\n' "${nginx_status:-未知}"
    printf '节点：%s\n' "$NODE_NAME"
    printf '地址：%s:%s\n' "$PUBLIC_IP" "$REALITY_PORT"
    printf 'Reality 目标：%s:%s\n' "$REALITY_HOST" "$REALITY_DEST_PORT"
    printf '公钥：%s\n' "$PUBLIC_KEY"
    printf 'short ID：%s\n' "$SHORT_ID"
    printf '\n%b===== VLESS / Shadowrocket =====%b\n' "$color_blue" "$color_reset"
    printf '原始 VLESS 单节点 URI：\n%s\n' "$uri"
    printf '\nBase64 VLESS 订阅 URL：\n%s\n' "$vless_subscription_url"
    printf '\n原始 VLESS 单节点二维码 PNG：%s\n' "$QR_FILE"
    printf '\nShadowrocket 订阅二维码：\n\n'
    if command_exists qrencode; then
        qrencode -t ANSIUTF8 -m 1 "$vless_subscription_url" || warn "终端二维码生成失败。"
    fi

    printf '\n%b===== Clash / Mihomo =====%b\n' "$color_blue" "$color_reset"
    printf 'YAML 订阅 URL：\n%s\n' "$clash_subscription_url"
    warn "在线订阅使用 HTTP。请把随机 URL 当作敏感凭据保存。"
}

show_command() {
    require_root
    show_configuration
}

find_deb_with_version() {
    local directory="$1"
    local wanted="$2"
    local file version
    while IFS= read -r -d '' file; do
        version="$(dpkg-deb -f "$file" Version 2>/dev/null || true)"
        if [[ "$version" == "$wanted" ]]; then
            printf '%s' "$file"
            return 0
        fi
    done < <(find "$directory" -maxdepth 1 -type f -name 'sing-box_*.deb' -print0)
    return 1
}

update_command() {
    local installed candidate temp candidate_deb candidate_binary old_deb=""
    require_root
    check_supported_system
    load_state
    info "刷新官方 APT 元数据。"
    apt-get update
    installed="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null)" || fatal "无法读取当前版本。"
    candidate="$(apt-cache policy sing-box | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]] || fatal "没有可用候选版本。"
    if [[ "$candidate" == "$installed" ]]; then
        success "已是最新版本：${installed}"
        return
    fi
    temp="$(mktemp -d /tmp/singbox-agent.update.XXXXXX)"
    UPDATE_TEMP_DIR="$temp"
    trap 'handle_error $? $LINENO' ERR
    info "下载候选版本 ${candidate} 并预检配置。"
    (cd "$temp" && apt-get download "sing-box=${candidate}")
    candidate_deb="$(find_deb_with_version "$temp" "$candidate")" || fatal "候选 DEB 下载失败。"
    mkdir -p "$temp/extract"
    dpkg-deb -x "$candidate_deb" "$temp/extract"
    candidate_binary="$(find "$temp/extract" -type f -path '*/bin/sing-box' -print -quit)"
    [[ -x "$candidate_binary" ]] || fatal "候选包不含可执行 sing-box。"
    "$candidate_binary" check -c "$SINGBOX_CONFIG" || fatal "新版本与当前配置不兼容，已取消更新。"

    mkdir -p "$CACHE_DIR"
    (cd "$CACHE_DIR" && apt-get download "sing-box=${installed}") >/dev/null 2>&1 || warn "旧版本 DEB 无法缓存，故障时可能不能自动回滚。"
    old_deb="$(find_deb_with_version "$CACHE_DIR" "$installed" || true)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "sing-box=${candidate}"; then
        error "候选版本安装失败。"
        if [[ -n "$old_deb" ]]; then
            warn "正在恢复 ${installed}。"
            dpkg -i "$old_deb"
            systemctl restart sing-box.service
        fi
        fatal "更新未完成。"
    fi
    if sing-box check -c "$SINGBOX_CONFIG" && systemctl restart sing-box.service && sleep 2 && systemctl is-active --quiet sing-box.service; then
        INSTALLED_VERSION="$candidate"
        write_state
        cleanup_update_temp
        trap - ERR
        success "sing-box 已更新：${installed} → ${candidate}"
        return
    fi
    error "新版本启动失败。"
    if [[ -n "$old_deb" ]]; then
        warn "正在回滚到 ${installed}。"
        dpkg -i "$old_deb"
        systemctl restart sing-box.service
        systemctl is-active --quiet sing-box.service || fatal "旧版本恢复后仍无法启动，请检查 journalctl -u sing-box。"
        cleanup_update_temp
        fatal "更新失败，已恢复旧版本。"
    fi
    cleanup_update_temp
    fatal "没有旧版 DEB，无法自动回滚。请检查 journalctl -u sing-box。"
}

uninstall_command() {
    local answer
    require_root
    load_state
    printf '将删除：\n'
    printf '  %s\n' "$APP_DIR" "$WEB_DIR" "$SINGBOX_CONFIG" "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED" "$MANAGER_FILE" "$COMMAND_LINK"
    printf '将按状态记录移除 sing-box 包、APT 源和 UFW 规则；保留 nginx、qrencode 和通用依赖。\n'
    read -r -p "确认卸载？请输入 y：" answer
    [[ "$answer" == "y" ]] || { info "已取消。"; return; }

    remove_owned_ufw_rule "$REALITY_PORT" "$UFW_REALITY_RULE_CREATED"
    remove_owned_ufw_rule "$SUBSCRIPTION_PORT" "$UFW_SUBSCRIPTION_RULE_CREATED"
    systemctl disable --now sing-box.service >/dev/null 2>&1 || true
    rm -f -- "$NGINX_SITE_ENABLED" "$NGINX_SITE_AVAILABLE"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx.service >/dev/null 2>&1 || true
    else
        warn "现有 nginx 配置检查失败，未重载 nginx。"
    fi
    if [[ "$SINGBOX_INSTALLED_BY_SCRIPT" == "1" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y sing-box || fatal "sing-box 包卸载失败；状态文件已保留，可重试。"
    fi
    [[ "$APT_SOURCE_CREATED" == "1" ]] && rm -f -- "$APT_SOURCE_FILE"
    [[ "$APT_KEY_CREATED" == "1" ]] && rm -f -- "$APT_KEY_FILE"
    rm -f -- "$SINGBOX_CONFIG" "$URI_FILE" "$QR_FILE" "$STATE_FILE" "$COMMAND_LINK" "$MANAGER_FILE" \
        "$WEB_CLASH_SUBSCRIPTION" "$WEB_VLESS_SUBSCRIPTION" "$LEGACY_WEB_SUBSCRIPTION"
    rmdir "$WEB_DIR" "$(dirname "$WEB_DIR")" "$APP_DIR" "$MANAGER_DIR" 2>/dev/null || true
    rm -rf -- "$CACHE_DIR"
    success "singbox-agent 已卸载。"
}

print_menu() {
    printf '\n%b===== singbox-agent %s =====%b\n' "$color_blue" "$SCRIPT_VERSION" "$color_reset"
    printf '1. 安装或重新配置\n'
    printf '2. 查看配置与二维码\n'
    printf '3. 更新 sing-box\n'
    printf '4. 卸载\n'
    printf '0. 退出\n'
}

pause_menu() {
    read -r -p "按回车返回主菜单：" || true
}

menu_command() {
    local choice
    while true; do
        print_menu
        if ! read -r -p "请选择：" choice; then
            printf '\n'
            return
        fi
        case "$choice" in
            1)
                install_command
                return
                ;;
            2)
                show_command
                pause_menu
                ;;
            3)
                update_command
                pause_menu
                ;;
            4)
                uninstall_command
                [[ -e "$STATE_FILE" ]] || return
                ;;
            0) return ;;
            *) warn "无效选项，请重新选择。" ;;
        esac
    done
}

usage() {
    cat <<EOF
用法：
  $0                 显示交互菜单
  $0 install         安装或重新配置
  $0 show            查看配置与二维码
  $0 update          更新 sing-box
  $0 uninstall       卸载
EOF
}

main() {
    case "${1:-menu}" in
        menu) menu_command ;;
        install) install_command ;;
        show) show_command ;;
        update) update_command ;;
        uninstall) uninstall_command ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
