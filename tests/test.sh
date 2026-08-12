#!/usr/bin/env bash

# singbox-agent 纯函数与配置渲染测试
# 作者：fengshi

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
readonly PROJECT_DIR
TEST_SANDBOX="$(mktemp -d)"
readonly TEST_SANDBOX
export SBA_ROOT="${TEST_SANDBOX}/root"
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT

# shellcheck source=install.sh
source "${PROJECT_DIR}/install.sh"

passed=0

assert_true() {
    local description="$1"
    shift
    if "$@"; then
        printf '通过：%s\n' "$description"
        passed=$((passed + 1))
    else
        printf '失败：%s\n' "$description" >&2
        exit 1
    fi
}

assert_false() {
    local description="$1"
    shift
    if "$@"; then
        printf '失败：%s\n' "$description" >&2
        exit 1
    else
        printf '通过：%s\n' "$description"
        passed=$((passed + 1))
    fi
}

assert_equal() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '通过：%s\n' "$description"
        passed=$((passed + 1))
    else
        printf '失败：%s\n期望：%s\n实际：%s\n' "$description" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_true "IPv4 校验" validate_ipv4 "203.0.113.10"
assert_false "IPv4 越界" validate_ipv4 "256.0.0.1"
assert_true "IPv6 校验" validate_ipv6 "2001:db8::1"
assert_false "拒绝伪 IPv6" validate_ipv6 "not:ipv6"
assert_false "拒绝超长 IPv6" validate_ipv6 "1:2:3:4:5:6:7:8:9"
assert_true "端口下界" validate_port "1"
assert_true "端口上界" validate_port "65535"
assert_false "拒绝零端口" validate_port "0"
assert_false "拒绝命令注入端口" validate_port '443;id'
assert_true "域名校验" validate_hostname "addons.mozilla.org"
assert_false "拒绝域名注入" validate_hostname 'example.com;id'
assert_false "拒绝超长节点名" validate_node_name "$(printf 'a%.0s' {1..65})"
assert_false "拒绝终端转义字符" validate_node_name $'node\033[31m'
assert_equal "IPv6 URL 方括号" "[2001:db8::1]" "$(format_url_host '2001:db8::1')"

if command -v jq >/dev/null 2>&1; then
    NODE_NAME='测试: "节点" #1'
    PUBLIC_IP="2001:db8::1"
    REALITY_PORT="23456"
    REALITY_HOST="addons.mozilla.org"
    PUBLIC_KEY="abcdefghijklmnopqrstuvwxyzABCDE_1234567890-xyz"
    SHORT_ID="0123456789abcdef"
    UUID="11111111-2222-3333-4444-555555555555"
    uri="$(build_vless_uri)"
    assert_true "URI 使用 IPv6 方括号" grep -Fq '@[2001:db8::1]:23456' <<<"$uri"
    assert_true "节点名已编码" grep -Fq '#%E6%B5%8B%E8%AF%95%3A%20%22%E8%8A%82%E7%82%B9%22%20%231' <<<"$uri"

    temp_dir="${TEST_SANDBOX}/render"
    mkdir -p "$temp_dir"
    LISTEN_ADDRESS="::"
    REALITY_DEST_PORT="443"
    PRIVATE_KEY="abcdefghijklmnopqrstuvwxyzABCDE_1234567890-xyz"
    render_singbox_config "${temp_dir}/config.json"
    assert_equal "配置协议为 VLESS" "vless" "$(jq -r '.inbounds[0].type' "${temp_dir}/config.json")"
    assert_equal "配置启用 Vision" "xtls-rprx-vision" "$(jq -r '.inbounds[0].users[0].flow' "${temp_dir}/config.json")"
    assert_equal "配置 short ID" "$SHORT_ID" "$(jq -r '.inbounds[0].tls.reality.short_id[0]' "${temp_dir}/config.json")"

    SUBSCRIPTION_PORT="45678"
    SUBSCRIPTION_TOKEN="$(printf 'ab%.0s' {1..32})"
    render_nginx_config "${temp_dir}/nginx.conf"
    assert_true "nginx 使用精确 Clash 订阅路径" grep -Fq "location = /sub/${SUBSCRIPTION_TOKEN} {" "${temp_dir}/nginx.conf"
    assert_true "nginx 使用精确 VLESS 订阅路径" grep -Fq "location = /sub/${SUBSCRIPTION_TOKEN}/vless {" "${temp_dir}/nginx.conf"
    assert_true "Clash 订阅使用 YAML 类型" grep -Fq 'default_type application/yaml;' "${temp_dir}/nginx.conf"
    assert_true "VLESS 订阅使用文本类型" grep -Fq 'default_type text/plain;' "${temp_dir}/nginx.conf"
    assert_equal "nginx 两个订阅仅允许 GET 和 HEAD" "2" "$(grep -Fc 'limit_except GET { deny all; }' "${temp_dir}/nginx.conf")"
    assert_true "nginx 关闭访问日志" grep -Fq 'access_log off;' "${temp_dir}/nginx.conf"
    assert_true "nginx 默认返回 404" grep -Fq 'return 404;' "${temp_dir}/nginx.conf"
    assert_true "IPv6 订阅仅监听 IPv6" grep -Fq 'listen [::]:45678 ipv6only=on default_server;' "${temp_dir}/nginx.conf"

    render_mihomo_subscription "${temp_dir}/clash.yaml"
    assert_true "Mihomo 包含 VLESS Reality" grep -Fq 'type: vless' "${temp_dir}/clash.yaml"
    assert_true "Mihomo 包含 Vision" grep -Fq 'flow: xtls-rprx-vision' "${temp_dir}/clash.yaml"
    assert_true "Mihomo 包含 XUDP" grep -Fq 'packet-encoding: xudp' "${temp_dir}/clash.yaml"
    assert_true "Mihomo 包含 Reality 公钥" grep -Fq 'public-key:' "${temp_dir}/clash.yaml"
    assert_true "Mihomo 包含代理组" grep -Fq 'proxy-groups:' "${temp_dir}/clash.yaml"
    assert_true "Mihomo 包含兜底规则" grep -Fq 'MATCH,节点选择' "${temp_dir}/clash.yaml"

    yaml_python=""
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        yaml_python="python3"
    elif command -v python >/dev/null 2>&1 && python -c 'import yaml' >/dev/null 2>&1; then
        yaml_python="python"
    fi
    if [[ -n "$yaml_python" ]]; then
        assert_true "Mihomo YAML 是有效顶层映射" "$yaml_python" - "${temp_dir}/clash.yaml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    data = yaml.safe_load(stream)
assert isinstance(data, dict)
assert data["proxies"][0]["type"] == "vless"
assert data["proxies"][0]["reality-opts"]["short-id"] == "0123456789abcdef"
assert data["proxy-groups"][0]["name"] == "节点选择"
assert data["rules"] == ["MATCH,节点选择"]
PY
    else
        printf '跳过：未安装 PyYAML，无法解析 Mihomo YAML。\n'
    fi

    qrencode() {
        local output=""
        QRENCODE_ARGUMENTS="$(printf '%s ' "$@")"
        while (($#)); do
            if [[ "$1" == "-o" ]]; then
                output="$2"
                shift 2
            else
                shift
            fi
        done
        printf 'PNG\n' >"$output"
    }
    original_app_dir="$APP_DIR"
    original_web_dir="$WEB_DIR"
    original_uri_file="$URI_FILE"
    original_qr_file="$QR_FILE"
    original_clash_subscription="$WEB_CLASH_SUBSCRIPTION"
    original_vless_subscription="$WEB_VLESS_SUBSCRIPTION"
    APP_DIR="${temp_dir}/app"
    WEB_DIR="${temp_dir}/www"
    URI_FILE="${APP_DIR}/vless-uri.txt"
    QR_FILE="${APP_DIR}/vless.png"
    WEB_CLASH_SUBSCRIPTION="${WEB_DIR}/clash.yaml"
    WEB_VLESS_SUBSCRIPTION="${WEB_DIR}/vless.txt"
    write_client_artifacts
    decoded_uri="$(base64 -d "$WEB_VLESS_SUBSCRIPTION")"
    assert_equal "Base64 解码严格等于 VLESS URI" "$(build_vless_uri)" "$decoded_uri"
    assert_true "客户端二维码已生成" test -s "$QR_FILE"
    assert_true "PNG 二维码使用紧凑尺寸" grep -Fq -- '-s 4 -m 1' <<<"$QRENCODE_ARGUMENTS"
    assert_true "终端二维码使用紧凑边距" grep -Fq "qrencode -t ANSIUTF8 -m 1 \"\$uri\"" "${PROJECT_DIR}/install.sh"
    APP_DIR="$original_app_dir"
    WEB_DIR="$original_web_dir"
    URI_FILE="$original_uri_file"
    QR_FILE="$original_qr_file"
    WEB_CLASH_SUBSCRIPTION="$original_clash_subscription"
    WEB_VLESS_SUBSCRIPTION="$original_vless_subscription"

    PUBLIC_IP="203.0.113.10"
    render_nginx_config "${temp_dir}/nginx-ipv4.conf"
    assert_false "IPv4 订阅不强制监听 IPv6" grep -Fq 'listen [::]' "${temp_dir}/nginx-ipv4.conf"
else
    printf '跳过：未安装 jq，无法测试 URI 和配置渲染。\n'
fi

# 使用临时根目录和命令替身验证卸载边界。
require_root() { :; }
systemctl() { :; }
nginx() { :; }

NODE_NAME="测试节点"
PUBLIC_IP="203.0.113.10"
LISTEN_ADDRESS="0.0.0.0"
REALITY_PORT="23456"
SUBSCRIPTION_PORT="45678"
REALITY_HOST="addons.mozilla.org"
REALITY_DEST_PORT="443"
UUID="11111111-2222-3333-4444-555555555555"
PRIVATE_KEY="abcdefghijklmnopqrstuvwxyzABCDE_1234567890-xyz"
PUBLIC_KEY="abcdefghijklmnopqrstuvwxyzABCDE_1234567890-xyz"
SHORT_ID="0123456789abcdef"
SUBSCRIPTION_TOKEN="$(printf 'ab%.0s' {1..32})"
SINGBOX_INSTALLED_BY_SCRIPT=0
APT_KEY_CREATED=0
APT_SOURCE_CREATED=0
UFW_REALITY_RULE_CREATED=0
UFW_SUBSCRIPTION_RULE_CREATED=0
INSTALLED_VERSION="1.0.0"
write_state
mkdir -p "$SINGBOX_DIR" "$(dirname "$NGINX_SITE_AVAILABLE")" "$(dirname "$NGINX_SITE_ENABLED")" "$WEB_DIR" "$MANAGER_DIR" "$(dirname "$COMMAND_LINK")"
touch "$SINGBOX_CONFIG" "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED" "$WEB_CLASH_SUBSCRIPTION" \
    "$WEB_VLESS_SUBSCRIPTION" "$LEGACY_WEB_SUBSCRIPTION" "$URI_FILE" "$QR_FILE" "$MANAGER_FILE" "$COMMAND_LINK"
user_nginx_file="$(dirname "$NGINX_SITE_AVAILABLE")/user-site"
printf '用户配置\n' >"$user_nginx_file"
uninstall_command <<<'y'
assert_false "卸载删除项目配置" test -e "$SINGBOX_CONFIG"
assert_false "卸载删除项目 nginx 配置" test -e "$NGINX_SITE_AVAILABLE"
assert_false "卸载删除 Clash 订阅" test -e "$WEB_CLASH_SUBSCRIPTION"
assert_false "卸载删除 VLESS 订阅" test -e "$WEB_VLESS_SUBSCRIPTION"
assert_false "卸载删除旧订阅文件" test -e "$LEGACY_WEB_SUBSCRIPTION"
assert_false "卸载删除状态目录" test -e "$APP_DIR"
assert_true "卸载保留用户 nginx 配置" test -e "$user_nginx_file"

printf '完成：%s 项测试通过。\n' "$passed"
