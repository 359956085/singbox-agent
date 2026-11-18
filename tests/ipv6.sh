#!/usr/bin/env bash

# IPv6 输出、旧状态兼容与可选的真实本地双栈验收。
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SANDBOX="$(mktemp -d)"
export SBA_ROOT="${TEST_SANDBOX}/root"
nginx_pid=""
singbox_pid=""
cleanup() {
    if [[ -n "$nginx_pid" ]]; then kill "$nginx_pid" 2>/dev/null || true; wait "$nginx_pid" 2>/dev/null || true; fi
    if [[ -n "$singbox_pid" ]]; then kill "$singbox_pid" 2>/dev/null || true; wait "$singbox_pid" 2>/dev/null || true; fi
    rm -rf -- "$TEST_SANDBOX"
}
trap cleanup EXIT
# shellcheck source=install.sh
source "${PROJECT_DIR}/install.sh"
passed=0
check() {
    local description="$1"
    shift
    if ! "$@"; then printf '失败：%s\n' "$description" >&2; exit 1; fi
    passed=$((passed + 1))
    printf '通过：%s\n' "$description"
}

NODE_NAME=dual-node
PUBLIC_IP=203.0.113.10
PUBLIC_IPV6=2001:db8::10
LISTEN_ADDRESS=::
REALITY_PORT=23456
SUBSCRIPTION_PORT=45678
REALITY_HOST=example.com
REALITY_DEST_PORT=443
UUID=11111111-2222-3333-4444-555555555555
PRIVATE_KEY=abcdefghijklmnopqrstuvwxyzABCDE_1234567890-xyz
PUBLIC_KEY="$PRIVATE_KEY"
SHORT_ID=0123456789abcdef
SUBSCRIPTION_TOKEN="$(printf 'ab%.0s' {1..32})"
SINGBOX_INSTALLED_BY_SCRIPT=0
APT_KEY_CREATED=0
APT_SOURCE_CREATED=0
UFW_REALITY_RULE_CREATED=0
UFW_SUBSCRIPTION_RULE_CREATED=0
INSTALLED_VERSION=1.0.0

check '不接受链路本地附加 IPv6' test "$(validate_public_ipv6 fe80::1 && echo yes || echo no)" = no
check '不接受 ULA 附加 IPv6' test "$(validate_public_ipv6 fd00::1 && echo yes || echo no)" = no
detect_public_ipv6() { printf '2001:db8::10'; }
prompt_additional_ipv6 <<<''
check '探测 IPv6 供确认并启用双栈监听' test "$PUBLIC_IPV6/$LISTEN_ADDRESS" = '2001:db8::10/::'
prompt_additional_ipv6 "$PUBLIC_IPV6" <<<'-'
check '允许移除附加 IPv6' test "$PUBLIC_IPV6/$LISTEN_ADDRESS" = '/0.0.0.0'
prompt_additional_ipv6 <<<'[2001:db8::20]'
check '手工输入接受 IPv6 方括号' test "$PUBLIC_IPV6" = 2001:db8::20

write_state
load_state
check '双栈状态往返' test "$PUBLIC_IPV6" = 2001:db8::20
sed '/^PUBLIC_IPV6=/d' "$STATE_FILE" >"${STATE_FILE}.old"
mv "${STATE_FILE}.old" "$STATE_FILE"
load_state
check '旧状态缺少新字段时清空附加地址' test -z "$PUBLIC_IPV6"
check '状态版本保持为 1' test "$(state_get STATE_VERSION)" = 1

if [[ "${SBA_TEST_DUAL_STACK:-0}" == 1 ]] && ! command_exists jq; then
    printf '缺少验收工具：jq\n' >&2
    exit 1
fi
if command_exists jq; then
    qrencode() {
        # 写入实际传给二维码编码器的内容，验证 URI 与订阅二维码没有混用。
        if [[ "$1" == -o ]]; then printf '%s\n' "${!#}" >"$2"; else printf 'QR=%s\n' "${!#}"; fi
    }
    PUBLIC_IPV6=2001:db8::20
    LISTEN_ADDRESS=::
    write_client_artifacts
    uri4="$(build_vless_uri)"
    uri6="$(build_vless_uri "$PUBLIC_IPV6" "${NODE_NAME}-IPv6")"
    check 'IPv4 原始链接保持不变' grep -Fxq "$uri4" "$URI_FILE"
    check 'IPv6 链接包含方括号和独立名称' grep -Fq '@[2001:db8::20]:23456?' "$IPV6_URI_FILE"
    check 'IPv6 链接节点名称带后缀' grep -Fq '#dual-node-IPv6' "$IPV6_URI_FILE"
    check 'IPv4 PNG 编码原始 IPv4 URI' grep -Fxq "$uri4" "$QR_FILE"
    check 'IPv6 PNG 编码原始 IPv6 URI' grep -Fxq "$uri6" "$IPV6_QR_FILE"
    check 'IPv4 Base64 订阅仅包含 IPv4' test "$(base64 -d "$WEB_VLESS_SUBSCRIPTION")" = "$uri4"
    check 'IPv6 Base64 订阅仅包含 IPv6' test "$(base64 -d "$WEB_IPV6_VLESS_SUBSCRIPTION")" = "$uri6"
    check 'IPv6 订阅使用 IPv6 下载' test "$(build_vless_subscription_url "$PUBLIC_IPV6")" = "http://[2001:db8::20]:45678/sub/${SUBSCRIPTION_TOKEN}/vless"
    if command_exists python3 && python3 -c 'import yaml' 2>/dev/null; then
        check '两套 YAML 地址、名称及密钥正确且各含一个节点' python3 - "$WEB_CLASH_SUBSCRIPTION" "$WEB_IPV6_CLASH_SUBSCRIPTION" <<'PY'
import sys, yaml
a, b = [yaml.safe_load(open(path, encoding="utf8")) for path in sys.argv[1:]]
assert len(a["proxies"]) == len(b["proxies"]) == 1
x, y = a["proxies"][0], b["proxies"][0]
assert x["server"] == "203.0.113.10" and y["server"] == "2001:db8::20"
assert x["name"] == "dual-node-Reality" and y["name"] == "dual-node-IPv6-Reality"
assert x["uuid"] == y["uuid"] and x["reality-opts"] == y["reality-opts"]
assert b["proxy-groups"][0]["proxies"][0] == y["name"]
PY
    fi
    render_singbox_config "$TEST_SANDBOX/singbox.json"
    check '双栈共用一个 :: 节点监听' test "$(jq -r '.inbounds | length' "$TEST_SANDBOX/singbox.json")/$(jq -r '.inbounds[0].listen' "$TEST_SANDBOX/singbox.json")" = '1/::'
    render_nginx_config "$TEST_SANDBOX/site.conf"
    check '双栈 nginx 使用独立 server 块' test "$(grep -c '^server {' "$TEST_SANDBOX/site.conf")" = 2
    check 'IPv4 nginx 明确监听 IPv4' grep -Fq 'listen 0.0.0.0:45678 default_server;' "$TEST_SANDBOX/site.conf"
    check 'IPv6 nginx 明确仅监听 IPv6' grep -Fq 'listen [::]:45678 ipv6only=on default_server;' "$TEST_SANDBOX/site.conf"
    check '各地址均配置精确订阅路径' test "$(grep -c 'location = /sub/' "$TEST_SANDBOX/site.conf")" = 4
    check 'IPv6 nginx 关联独立订阅文件' grep -Fq "alias ${WEB_IPV6_VLESS_SUBSCRIPTION};" "$TEST_SANDBOX/site.conf"
    if [[ "$(uname -s)" == Linux ]]; then
        check 'IPv6 私有产物权限为 600' test "$(stat -c '%a' "$IPV6_URI_FILE")/$(stat -c '%a' "$IPV6_QR_FILE")" = 600/600
    fi

    write_state
    cp "$STATE_FILE" "$TEST_SANDBOX/state-before-show"
    systemctl() { printf 'active\n'; }
    sing-box() { printf 'sing-box version 1.0.0\n'; }
    show_configuration >"$TEST_SANDBOX/show.txt" 2>&1
    check '分别显示 IPv4 与 IPv6 分组' test "$(grep -Ec '===== IPv[46] =====' "$TEST_SANDBOX/show.txt")" = 2
    check 'IPv6 终端二维码编码 IPv6 订阅' grep -Fxq "QR=$(build_vless_subscription_url "$PUBLIC_IPV6")" "$TEST_SANDBOX/show.txt"
    check '展示不修改状态' cmp "$STATE_FILE" "$TEST_SANDBOX/state-before-show"
    unset -f systemctl sing-box

    PUBLIC_IPV6=""
    LISTEN_ADDRESS=0.0.0.0
    write_client_artifacts
    check '移除 IPv6 后删除私有产物' test ! -e "$IPV6_URI_FILE"
    check '移除 IPv6 后删除 PNG' test ! -e "$IPV6_QR_FILE"
    check '移除 IPv6 后删除独立 YAML' test ! -e "$WEB_IPV6_CLASH_SUBSCRIPTION"
    check '移除 IPv6 后删除独立 Base64' test ! -e "$WEB_IPV6_VLESS_SUBSCRIPTION"
    render_nginx_config "$TEST_SANDBOX/site.conf"
    check '移除 IPv6 后 nginx 仅剩 IPv4' test "$(grep -c '^server {' "$TEST_SANDBOX/site.conf")" = 1

    PUBLIC_IP=2001:db8::30
    LISTEN_ADDRESS=::
    prompt_additional_ipv6
    write_client_artifacts
    check 'IPv6 单栈继续使用原始产物路径' grep -Fq '@[2001:db8::30]:23456?' "$URI_FILE"
    check 'IPv6 单栈不生成额外产物' test ! -e "$IPV6_URI_FILE"
    render_nginx_config "$TEST_SANDBOX/site.conf"
    check 'IPv6 单栈仅有一个 server 块' test "$(grep -c '^server {' "$TEST_SANDBOX/site.conf")" = 1

    # 需要真实二进制时，显式启用本地验收；所有服务仅在测试期间运行。
    if [[ "${SBA_TEST_DUAL_STACK:-0}" == 1 ]]; then
        for required in nginx sing-box python3 curl openssl; do command_exists "$required" || { echo "缺少验收工具：$required" >&2; exit 1; }; done
        PUBLIC_IP=203.0.113.10
        PUBLIC_IPV6=2001:db8::20
        LISTEN_ADDRESS=::
        REALITY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
        SUBSCRIPTION_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
        generate_credentials
        write_client_artifacts
        render_singbox_config "$TEST_SANDBOX/singbox.json"
        render_nginx_config "$TEST_SANDBOX/site.conf"
        mkdir -p "$TEST_SANDBOX/logs"
        cat >"$TEST_SANDBOX/nginx.conf" <<EOF
user root;
daemon off;
master_process off;
pid ${TEST_SANDBOX}/nginx.pid;
error_log ${TEST_SANDBOX}/nginx.log;
events {}
http {
    access_log off;
    client_body_temp_path ${TEST_SANDBOX}/body;
    proxy_temp_path ${TEST_SANDBOX}/proxy;
    fastcgi_temp_path ${TEST_SANDBOX}/fastcgi;
    uwsgi_temp_path ${TEST_SANDBOX}/uwsgi;
    scgi_temp_path ${TEST_SANDBOX}/scgi;
    include ${TEST_SANDBOX}/site.conf;
}
EOF
        sing-box check -c "$TEST_SANDBOX/singbox.json"
        nginx -t -p "$TEST_SANDBOX/" -c "$TEST_SANDBOX/nginx.conf"
        sing-box run -c "$TEST_SANDBOX/singbox.json" >"$TEST_SANDBOX/singbox.log" 2>&1 &
        singbox_pid=$!
        nginx -p "$TEST_SANDBOX/" -c "$TEST_SANDBOX/nginx.conf" &
        nginx_pid=$!
        # 节点无需外部 Reality 握手，直接验证真实监听与本地 HTTP 路由。
        check '真实 sing-box 双栈 TCP 及两套 nginx HTTP 内容' python3 - "$REALITY_PORT" "$SUBSCRIPTION_PORT" "$SUBSCRIPTION_TOKEN" "$WEB_VLESS_SUBSCRIPTION" "$WEB_IPV6_VLESS_SUBSCRIPTION" "$WEB_CLASH_SUBSCRIPTION" "$WEB_IPV6_CLASH_SUBSCRIPTION" <<'PY'
import http.client, pathlib, socket, sys, time
node, port = map(int, sys.argv[1:3])
token = sys.argv[3]
deadline = time.monotonic() + 10
while True:
    try:
        for host, vless, clash in [("127.0.0.1", sys.argv[4], sys.argv[6]), ("::1", sys.argv[5], sys.argv[7])]:
            with socket.create_connection((host, node), timeout=1): pass
            for path, expected in [(f"/sub/{token}/vless", pathlib.Path(vless).read_bytes()), (f"/sub/{token}", pathlib.Path(clash).read_bytes()), ("/", None), (f"/sub/{token}/vless/extra", None)]:
                conn = http.client.HTTPConnection(host, port, timeout=1)
                conn.request("GET", path)
                response = conn.getresponse()
                assert response.status == (404 if expected is None else 200), (host, path, response.status)
                if expected is not None: assert response.read() == expected, (host, path)
                conn.close()
        break
    except (OSError, AssertionError):
        if time.monotonic() >= deadline: raise
        time.sleep(0.1)
PY
        check '生产监听校验函数通过真实服务' verify_ipv6_listeners
    fi
else
    printf '跳过：IPv6 渲染测试需要 jq。\n'
fi
printf 'IPv6：%s 项测试通过。\n' "$passed"
