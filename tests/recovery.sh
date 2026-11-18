#!/usr/bin/env bash

# 安装恢复回归测试：所有系统命令均使用替身，不访问真实服务、APT 或网络。
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SANDBOX="$(mktemp -d)"
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
passed=0

check() {
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

harness="${TEST_SANDBOX}/harness.sh"
cat >"$harness" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source "${PROJECT_DIR:?}/install.sh"
action="$1"
mkdir -p "$SBA_ROOT/mock"
REALITY_PORT=23456
SUBSCRIPTION_PORT=45678
NODE_NAME=original-node
PUBLIC_IP=203.0.113.10
LISTEN_ADDRESS=0.0.0.0
REALITY_HOST=addons.mozilla.org
REALITY_DEST_PORT=443
UUID=11111111-2222-3333-4444-555555555555
PRIVATE_KEY=abcdefghijklmnopqrstuvwxyzABCDE_1234567890-xyz
PUBLIC_KEY=abcdefghijklmnopqrstuvwxyzABCDE_1234567890-xyz
SHORT_ID=0123456789abcdef
SUBSCRIPTION_TOKEN="$(printf 'ab%.0s' {1..32})"
SINGBOX_INSTALLED_BY_SCRIPT=0
APT_KEY_CREATED=0
APT_SOURCE_CREATED=0
UFW_REALITY_RULE_CREATED=0
UFW_SUBSCRIPTION_RULE_CREATED=0
INSTALLED_VERSION=1.0.0

require_root() { :; }
check_supported_system() { :; }
command_exists() {
    if [[ "$1" == sing-box ]]; then
        [[ -f "$SBA_ROOT/mock/package" ]]
    else
        command -v "$1" >/dev/null 2>&1
    fi
}
systemctl() {
    printf '%s ' "$@" >>"$SBA_ROOT/mock/systemctl.log"
    printf '\n' >>"$SBA_ROOT/mock/systemctl.log"
    case "$1" in
        is-active) [[ -f "$SBA_ROOT/mock/${!#}.active" ]] ;;
        is-enabled) [[ -f "$SBA_ROOT/mock/${!#}.enabled" ]] ;;
        cat) [[ "$2" == nginx.service || -f "$SBA_ROOT/mock/package" ]] ;;
        show)
            if [[ "$4" == DropInPaths && -f "$SBA_ROOT/mock/custom" ]]; then
                printf '/etc/systemd/system/sing-box.service.d/custom.conf\n'
            elif [[ "$4" == FragmentPath && -f "$SBA_ROOT/mock/unit" ]]; then
                printf '/etc/systemd/system/sing-box.service\n'
            fi ;;
        enable) touch "$SBA_ROOT/mock/$2.enabled" ;;
        disable) rm -f "$SBA_ROOT/mock/$2.enabled" ;;
        stop) rm -f "$SBA_ROOT/mock/$2.active" ;;
        restart|start|reload) touch "$SBA_ROOT/mock/$2.active" ;;
        *) return 1 ;;
    esac
}
dpkg-query() {
    [[ -f "$SBA_ROOT/mock/package" ]] || return 1
    printf 'install ok installed'
}
wait_for_test_signal() {
    # 由阻塞子进程报告就绪，避免 Ctrl+C 到达后 Bash 才启动 sleep。
    # 显式恢复默认信号处理，避免测试替身继承忽略 SIGINT 的状态。
    python3 - "$1" <<'PYWAIT'
import signal
import sys

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, signal.SIG_DFL)
print(sys.argv[1], flush=True)
signal.pause()
PYWAIT
}
apt-get() {
    local IFS=' '
    printf '%s\n' "$*" >>"$SBA_ROOT/mock/apt.log"
    case "$*" in
        *'purge -y sing-box')
            [[ ! -f "$SBA_ROOT/mock/fail-purge" ]] || return 42
            rm -f "$SBA_ROOT/mock/package" ;;
        'install -y sing-box')
            touch "$SBA_ROOT/mock/package"
            if [[ "${WAIT_PACKAGE:-0}" == 1 ]]; then
                wait_for_test_signal PACKAGE_READY
            fi ;;
        *) : ;;
    esac
}
sing-box() {
    case "$1" in
        version) printf 'sing-box version 1.0.0\n' ;;
        *) return 1 ;;
    esac
}
nginx() { :; }
curl() {
    # setup_official_repository 唯一的 curl 调用；用假密钥取代网络。
    printf 'test-key\n' >"${!#}"
}
gpg() { :; }
ufw() {
    local IFS=' '
    case "$*" in
        status)
            printf 'Status: active\n'
            if [[ -f "$SBA_ROOT/mock/ufw" ]]; then cat "$SBA_ROOT/mock/ufw"; fi ;;
        allow*) printf '%s\n' "$2" >>"$SBA_ROOT/mock/ufw" ;;
        '--force delete allow '*)
            [[ ! -f "$SBA_ROOT/mock/fail-ufw" ]] || return 1
            grep -Fvx "$4" "$SBA_ROOT/mock/ufw" >"$SBA_ROOT/mock/ufw.next" || true
            mv "$SBA_ROOT/mock/ufw.next" "$SBA_ROOT/mock/ufw" ;;
        *) return 1 ;;
    esac
}
# Git Bash 没有 flock；只用于串行隔离测试，锁竞争在 Linux 伪终端测试中验证。
if ! command -v flock >/dev/null 2>&1; then flock() { :; }; fi
install_base_dependencies() { touch "$SBA_ROOT/mock/dependencies"; }
generate_credentials() { touch "$SBA_ROOT/mock/generated"; }
if [[ "$action" != prompt ]]; then
    prompt_node_name() { NODE_NAME="${1:-original-node}"; }
fi
prompt_public_ip() { :; }
prompt_additional_ipv6() { :; }
check_ipv6_prerequisites() { :; }
diagnose_ipv6_firewall() { :; }
prompt_port() {
    if [[ "$1" == REALITY_PORT ]]; then REALITY_PORT=23456; else SUBSCRIPTION_PORT=45678; fi
}
prompt_reality_target() { :; }
if [[ "$action" == render-fail ]]; then
    render_singbox_config() { printf 'partial-config\n' >"$1"; return 63; }
else
    install_singbox_config() {
        mkdir -p "$SINGBOX_DIR"
        printf '%s\n' "$UUID" >"$SINGBOX_CONFIG"
    }
fi
if [[ "$action" != ipv6-artifact-fail ]]; then
    write_client_artifacts() {
        mkdir -p "$APP_DIR" "$WEB_DIR"
        printf '%s\n' "$UUID" >"$URI_FILE"
        touch "$QR_FILE" "$WEB_CLASH_SUBSCRIPTION" "$WEB_VLESS_SUBSCRIPTION"
        if has_additional_ipv6; then
            printf 'new-uri\n' >"$IPV6_URI_FILE"
            touch "$IPV6_QR_FILE" "$WEB_IPV6_CLASH_SUBSCRIPTION" "$WEB_IPV6_VLESS_SUBSCRIPTION"
        else
            rm -f -- "$IPV6_URI_FILE" "$IPV6_QR_FILE" "$WEB_IPV6_CLASH_SUBSCRIPTION" "$WEB_IPV6_VLESS_SUBSCRIPTION"
        fi
    }
fi
install_nginx_config() {
    mkdir -p "$(dirname "$NGINX_SITE_AVAILABLE")" "$(dirname "$NGINX_SITE_ENABLED")"
    touch "$NGINX_SITE_AVAILABLE"
    ln -s "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED"
}
start_services() {
    [[ ! -f "$SBA_ROOT/mock/fail-start" ]] || return 51
    systemctl enable sing-box.service
    systemctl restart sing-box.service
    systemctl enable nginx.service
    systemctl start nginx.service
}
show_configuration() { :; }

case "$action" in
    ipv6-add|ipv6-remove|ipv6-reconfigure-fail|ipv6-artifact-fail|ipv6-listener-fail)
        touch "$SBA_ROOT/mock/package"
        mkdir -p "$APP_DIR" "$WEB_DIR" "$SINGBOX_DIR"
        printf 'old-config\n' >"$SINGBOX_CONFIG"
        if [[ "$action" != ipv6-add ]]; then
            PUBLIC_IPV6=2001:db8::10
            LISTEN_ADDRESS=::
            for file in "$IPV6_URI_FILE" "$IPV6_QR_FILE" "$WEB_IPV6_CLASH_SUBSCRIPTION" "$WEB_IPV6_VLESS_SUBSCRIPTION"; do
                printf 'old-ipv6\n' >"$file"
            done
        fi
        write_state
        cp "$STATE_FILE" "$SBA_ROOT/mock/original-state"
        prompt_additional_ipv6() { PUBLIC_IPV6=2001:db8::20; LISTEN_ADDRESS=::; }
        if [[ "$action" == ipv6-remove ]]; then
            prompt_additional_ipv6() { PUBLIC_IPV6=""; LISTEN_ADDRESS=0.0.0.0; }
        elif [[ "$action" == ipv6-reconfigure-fail ]]; then
            touch "$SBA_ROOT/mock/fail-start"
        elif [[ "$action" == ipv6-artifact-fail ]]; then
            qrencode() {
                [[ "$2" != *qr-ipv6.tmp ]] || return 64
                printf 'PNG\n' >"$2"
            }
        elif [[ "$action" == ipv6-listener-fail ]]; then
            start_services() { verify_ipv6_listeners; }
            timeout() { return 1; }
            sleep() { :; }
        fi
        configure_installation 1
        [[ "$(state_get UUID)" == "$UUID" && "$(state_get PRIVATE_KEY)" == "$PRIVATE_KEY" && "$(state_get SUBSCRIPTION_TOKEN)" == "$SUBSCRIPTION_TOKEN" ]]
        if [[ "$action" == ipv6-remove ]]; then
            [[ -z "$(state_get PUBLIC_IPV6)" && ! -e "$IPV6_URI_FILE" && ! -e "$WEB_IPV6_VLESS_SUBSCRIPTION" ]]
        else
            [[ "$(state_get PUBLIC_IPV6)" == 2001:db8::20 ]]
            uninstall_command <<<'y'
            [[ ! -e "$IPV6_URI_FILE" && ! -e "$IPV6_QR_FILE" && ! -e "$WEB_IPV6_CLASH_SUBSCRIPTION" && ! -e "$WEB_IPV6_VLESS_SUBSCRIPTION" ]]
        fi ;;
    legacy-transaction|legacy-committed)
        mkdir -p "$SINGBOX_DIR" "$APP_DIR"
        printf 'old-config\n' >"$SINGBOX_CONFIG"
        # 新版额外资源不属于旧事务，恢复旧事务时不得擅自删除。
        printf 'unrelated\n' >"$IPV6_URI_FILE"
        begin_transaction
        sed 's/^VERSION=2$/VERSION=1/' "$TX_DIR/record.conf" >"$TX_DIR/old-record"
        mv "$TX_DIR/old-record" "$TX_DIR/record.conf"
        for name in uri-ipv6 qr-ipv6 clash-ipv6 vless-ipv6 temp-uri-ipv6 temp-qr-ipv6 temp-clash-ipv6 temp-vless-ipv6; do
            rm -f -- "$TX_DIR/$name" "$TX_DIR/$name.exists" "$TX_DIR/$name.absent"
        done
        printf 'changed-config\n' >"$SINGBOX_CONFIG"
        if [[ "$action" == legacy-committed ]]; then
            sed 's/^PHASE=pending$/PHASE=committed/' "$TX_DIR/record.conf" >"$TX_DIR/committed-record"
            mv "$TX_DIR/committed-record" "$TX_DIR/record.conf"
        fi
        ROLLBACK_ACTIVE=0
        recover_transaction
        [[ ! -e "$TRANSACTION_DIR" ]]
        grep -Fxq unrelated "$IPV6_URI_FILE"
        if [[ "$action" == legacy-committed ]]; then
            grep -Fxq changed-config "$SINGBOX_CONFIG"
        else
            grep -Fxq old-config "$SINGBOX_CONFIG"
        fi
        begin_transaction
        grep -Fxq VERSION=2 "$TX_DIR/record.conf"
        [[ -e "$TX_DIR/uri-ipv6.exists" ]]
        rollback_transaction ;;
    invalid-v2-record)
        begin_transaction
        rm "$TX_DIR/temp-qr-ipv6.absent"
        ROLLBACK_ACTIVE=0
        recover_transaction ;;
    legacy|legacy-rollback)
        touch "$SBA_ROOT/mock/package"
        check_unmanaged_conflicts
        begin_transaction
        install_singbox_package
        [[ "$SINGBOX_INSTALLED_BY_SCRIPT" == 0 && "$TX_SINGBOX_INSTALLED" == 0 ]]
        if [[ "$action" == legacy-rollback ]]; then
            rollback_transaction
        else
            configure_installation 0
            uninstall_command <<<'y'
        fi
        [[ -f "$SBA_ROOT/mock/package" ]] ;;
    conflict-*)
        touch "$SBA_ROOT/mock/package"
        case "$action" in
            conflict-config) mkdir -p "$SINGBOX_DIR"; touch "$SINGBOX_CONFIG" ;;
            conflict-extra) mkdir -p "$SINGBOX_DIR/conf.d"; touch "$SINGBOX_DIR/conf.d/node.json" ;;
            conflict-link) mkdir -p "$SINGBOX_DIR"; ln -s /nonexistent "$SINGBOX_DIR/other.json" ;;
            conflict-active) touch "$SBA_ROOT/mock/sing-box.service.active" ;;
            conflict-dropin) touch "$SBA_ROOT/mock/custom" ;;
            conflict-unit) touch "$SBA_ROOT/mock/unit" ;;
            conflict-unloaded) mkdir -p "$SBA_ROOT/etc/systemd/system/sing-box.service.d"; touch "$SBA_ROOT/etc/systemd/system/sing-box.service.d/custom.conf" ;;
            conflict-nginx) mkdir -p "$(dirname "$NGINX_SITE_AVAILABLE")"; touch "$NGINX_SITE_AVAILABLE" ;;
        esac
        check_unmanaged_conflicts ;;
    rollback-fail)
        begin_transaction
        TX_SINGBOX_INSTALLED=1
        TX_APT_KEY_CREATED=1
        TX_APT_SOURCE_CREATED=1
        write_transaction
        mkdir -p "$SINGBOX_DIR" "$(dirname "$APT_KEY_FILE")" "$(dirname "$APT_SOURCE_FILE")"
        touch "$SBA_ROOT/mock/package" "$SBA_ROOT/mock/fail-purge" "$APT_KEY_FILE" "$APT_SOURCE_FILE" "$SINGBOX_CONFIG"
        handle_error 130 "$LINENO" ;;
    recover)
        rm -f "$SBA_ROOT/mock/fail-purge" "$SBA_ROOT/mock/fail-start"
        acquire_install_lock
        install_traps
        recover_transaction
        [[ ! -e "$TRANSACTION_DIR" ]]
        check_unmanaged_conflicts
        configure_installation 0
        [[ -e "$STATE_FILE" && -e "$COMMAND_LINK" ]]
        [[ "$(state_get SINGBOX_INSTALLED_BY_SCRIPT)" == 1 ]] ;;
    reconfigure|reconfigure-fail|reconfigure-ufw-fail)
        touch "$SBA_ROOT/mock/package" "$SBA_ROOT/mock/sing-box.service.active" "$SBA_ROOT/mock/sing-box.service.enabled"
        mkdir -p "$SINGBOX_DIR"
        printf 'original-config\n' >"$SINGBOX_CONFIG"
        if [[ "$action" == reconfigure-ufw-fail ]]; then
            UFW_REALITY_RULE_CREATED=1
            UFW_SUBSCRIPTION_RULE_CREATED=1
            install_manager() { return 57; }
        fi
        write_state
        cp "$STATE_FILE" "$SBA_ROOT/mock/original-state"
        if [[ "$action" == reconfigure-fail ]]; then touch "$SBA_ROOT/mock/fail-start"; fi
        configure_installation 1
        [[ ! -e "$SBA_ROOT/mock/generated" ]]
        [[ "$(state_get UUID)" == "$UUID" && "$(state_get PRIVATE_KEY)" == "$PRIVATE_KEY" && "$(state_get SUBSCRIPTION_TOKEN)" == "$SUBSCRIPTION_TOKEN" ]] ;;
    exit-uncommitted) begin_transaction; exit 0 ;;
    signal-uninstalled) begin_transaction; kill -INT "$BASHPID" ;;
    kill-uncommitted) begin_transaction; wait_for_test_signal TRANSACTION_READY ;;
    commit|commit-signal|commit-cleanup-interrupted)
        begin_transaction
        mkdir -p "$APP_DIR" "$(dirname "$COMMAND_LINK")"
        touch "$STATE_FILE" "$COMMAND_LINK"
        TX_PHASE=committed
        write_transaction
        if [[ "$action" == commit-signal ]]; then kill -INT "$BASHPID"; fi
        if [[ "$action" == commit-cleanup-interrupted ]]; then mv "$TX_DIR" "${TRANSACTION_DIR}.cleanup"; fi
        # 模拟写提交标记后、清理前进程消失。
        ROLLBACK_ACTIVE=0 ;;
    cleanup-committed) recover_transaction; [[ -e "$STATE_FILE" && -e "$COMMAND_LINK" ]] ;;
    invalid-record)
        begin_transaction
        ROLLBACK_ACTIVE=0
        printf 'TX_SINGBOX_INSTALLED=$(touch %s/mock/injected)\n' "$SBA_ROOT" >>"$TX_DIR/record.conf"
        recover_transaction ;;
    rollback-file-fail)
        begin_transaction
        mkdir -p "$SINGBOX_CONFIG"
        rollback_transaction ;;
    recover-file)
        rmdir "$SINGBOX_CONFIG"
        recover_transaction
        [[ ! -e "$TRANSACTION_DIR" ]] ;;
    ufw-recover)
        begin_transaction
        add_ufw_rule "$REALITY_PORT" UFW_REALITY_RULE_CREATED
        [[ "$TX_UFW_REALITY_ADDED" == 1 ]]
        touch "$SBA_ROOT/mock/fail-ufw"
        if rollback_transaction; then exit 1; fi
        [[ -e "$TRANSACTION_DIR/record.conf" ]]
        rm "$SBA_ROOT/mock/fail-ufw"
        recover_transaction
        [[ ! -s "$SBA_ROOT/mock/ufw" ]] ;;
    render-fail)
        touch "$SBA_ROOT/mock/package"
        begin_transaction
        install_singbox_config ;;
    render-retry) check_unmanaged_conflicts ;;
    subshell-fail)
        mkdir -p "$SINGBOX_DIR"
        printf 'original-config\n' >"$SINGBOX_CONFIG"
        begin_transaction
        result="$(false)" ;;
    lock-wait) acquire_install_lock; wait_for_test_signal LOCK_READY ;;
    lock-once) acquire_install_lock ;;
    prompt|install)
        if [[ "${FAIL_PURGE:-0}" == 1 ]]; then
            touch "$SBA_ROOT/mock/fail-purge"
        else
            rm -f "$SBA_ROOT/mock/fail-purge"
        fi
        install_command ;;
    *) exit 99 ;;
esac
SH

run_case() {
    local root="$1" action="$2" expected="$3" code=0
    PROJECT_DIR="$PROJECT_DIR" SBA_ROOT="$root" bash "$harness" "$action" >"${TEST_SANDBOX}/output" 2>&1 || code=$?
    if [[ "$code" != "$expected" ]]; then cat "${TEST_SANDBOX}/output"; fi
    check "$action 退出码为 $expected" test "$code" -eq "$expected"
}

run_case "$TEST_SANDBOX/legacy" legacy 0
check '复用的软件包在卸载后仍存在' test -f "$TEST_SANDBOX/legacy/mock/package"
run_case "$TEST_SANDBOX/legacy-rollback" legacy-rollback 0
for scenario in config extra link active dropin unit unloaded nginx; do
    run_case "$TEST_SANDBOX/conflict-$scenario" "conflict-$scenario" 1
    check "冲突 $scenario 不修改 APT" test ! -e "$TEST_SANDBOX/conflict-$scenario/mock/apt.log"
done

failure_root="$TEST_SANDBOX/failure"
run_case "$failure_root" rollback-fail 130
check '卸载失败保留恢复记录' test -f "$failure_root/var/lib/singbox-agent/transaction/record.conf"
check '卸载失败保留 APT 源' test -f "$failure_root/etc/apt/sources.list.d/sagernet.sources"
check '卸载失败保留 APT 密钥' test -f "$failure_root/etc/apt/keyrings/sagernet.asc"
if [[ "$(uname -s)" == Linux ]]; then
    check '恢复目录权限为 700' test "$(stat -c '%a' "$failure_root/var/lib/singbox-agent/transaction")" = 700
    check '恢复记录权限为 600' test "$(stat -c '%a' "$failure_root/var/lib/singbox-agent/transaction/record.conf")" = 600
fi
run_case "$failure_root" recover 0
check '恢复再安装后清理事务' test ! -e "$failure_root/var/lib/singbox-agent/transaction"
run_case "$TEST_SANDBOX/reconfigure" reconfigure 0
run_case "$TEST_SANDBOX/ipv6-add" ipv6-add 0
check '添加 IPv6 后卸载清理全部产物' test ! -d "$TEST_SANDBOX/ipv6-add/etc/singbox-agent"
run_case "$TEST_SANDBOX/ipv6-remove" ipv6-remove 0
run_case "$TEST_SANDBOX/ipv6-reconfigure-fail" ipv6-reconfigure-fail 51
check '双栈配置失败恢复旧状态' cmp "$TEST_SANDBOX/ipv6-reconfigure-fail/etc/singbox-agent/state.conf" "$TEST_SANDBOX/ipv6-reconfigure-fail/mock/original-state"
run_case "$TEST_SANDBOX/ipv6-listener-fail" ipv6-listener-fail 1
check 'IPv6 监听失败恢复旧状态' cmp "$TEST_SANDBOX/ipv6-listener-fail/etc/singbox-agent/state.conf" "$TEST_SANDBOX/ipv6-listener-fail/mock/original-state"
for file in etc/singbox-agent/vless-ipv6-uri.txt etc/singbox-agent/vless-ipv6.png var/lib/singbox-agent/www/clash-ipv6.yaml var/lib/singbox-agent/www/vless-ipv6.txt; do
    check "双栈回滚恢复 $file" grep -Fxq old-ipv6 "$TEST_SANDBOX/ipv6-reconfigure-fail/$file"
done
if command -v jq >/dev/null 2>&1; then
    run_case "$TEST_SANDBOX/ipv6-artifact-fail" ipv6-artifact-fail 64
    check 'IPv6 PNG 生成失败恢复旧 URI' grep -Fxq old-ipv6 "$TEST_SANDBOX/ipv6-artifact-fail/etc/singbox-agent/vless-ipv6-uri.txt"
    check 'IPv6 PNG 生成失败清理暂存文件' test ! -e "$TEST_SANDBOX/ipv6-artifact-fail/etc/singbox-agent/.singbox-agent-qr-ipv6.tmp"
fi
run_case "$TEST_SANDBOX/legacy-transaction" legacy-transaction 0
run_case "$TEST_SANDBOX/legacy-committed" legacy-committed 0
run_case "$TEST_SANDBOX/invalid-v2-record" invalid-v2-record 1
check '新版事务缺少备份时保留诊断记录' test -f "$TEST_SANDBOX/invalid-v2-record/var/lib/singbox-agent/transaction/record.conf"
run_case "$TEST_SANDBOX/reconfigure-fail" reconfigure-fail 51
check '重新配置失败恢复旧配置' grep -Fxq original-config "$TEST_SANDBOX/reconfigure-fail/etc/sing-box/config.json"
check '重新配置失败恢复旧状态和凭据' cmp "$TEST_SANDBOX/reconfigure-fail/etc/singbox-agent/state.conf" "$TEST_SANDBOX/reconfigure-fail/mock/original-state"
check '重新配置失败保留原服务运行状态' test -f "$TEST_SANDBOX/reconfigure-fail/mock/sing-box.service.active"
run_case "$TEST_SANDBOX/exit" exit-uncommitted 1
check '正常退出但未提交也执行回滚' test ! -e "$TEST_SANDBOX/exit/var/lib/singbox-agent/transaction"
run_case "$TEST_SANDBOX/signal-uninstalled" signal-uninstalled 130
check 'SIGINT 回滚时缺失的服务不会误报恢复失败' test ! -e "$TEST_SANDBOX/signal-uninstalled/var/lib/singbox-agent/transaction"
run_case "$TEST_SANDBOX/commit" commit 0
run_case "$TEST_SANDBOX/commit" cleanup-committed 0
check '提交后恢复只清理备份' test ! -e "$TEST_SANDBOX/commit/var/lib/singbox-agent/transaction"
run_case "$TEST_SANDBOX/commit-signal" commit-signal 130
check '提交标记落盘后收到信号保留安装状态' test -e "$TEST_SANDBOX/commit-signal/etc/singbox-agent/state.conf"
run_case "$TEST_SANDBOX/commit-cleanup" commit-cleanup-interrupted 0
run_case "$TEST_SANDBOX/commit-cleanup" cleanup-committed 0
check '清理备份中断后可再次清理' test ! -e "$TEST_SANDBOX/commit-cleanup/var/lib/singbox-agent/transaction.cleanup"
run_case "$TEST_SANDBOX/invalid" invalid-record 1
check '恢复记录不会执行命令' test ! -e "$TEST_SANDBOX/invalid/mock/injected"
check '无效记录保留现场' test -f "$TEST_SANDBOX/invalid/var/lib/singbox-agent/transaction/record.conf"
run_case "$TEST_SANDBOX/file" rollback-file-fail 1
check '文件恢复失败保留备份' test -d "$TEST_SANDBOX/file/var/lib/singbox-agent/transaction"
run_case "$TEST_SANDBOX/file" recover-file 0
run_case "$TEST_SANDBOX/ufw" ufw-recover 0
run_case "$TEST_SANDBOX/reconfigure-ufw" reconfigure-ufw-fail 57
check '重新配置失败移除本次补建的旧端口 UFW 规则' test ! -s "$TEST_SANDBOX/reconfigure-ufw/mock/ufw"
run_case "$TEST_SANDBOX/render" render-fail 63
check '配置渲染失败清理同目录暂存文件' test ! -e "$TEST_SANDBOX/render/etc/sing-box/.singbox-agent-config.tmp"
run_case "$TEST_SANDBOX/render" render-retry 0
run_case "$TEST_SANDBOX/subshell" subshell-fail 1
check '命令替换失败只回滚一次并保留旧配置' grep -Fxq original-config "$TEST_SANDBOX/subshell/etc/sing-box/config.json"

if [[ "$(uname -s)" == Linux ]]; then
    # forkpty 建立控制终端，通过终端的 VINTR 字符发送真实 Ctrl+C。
    check 'Linux 伪终端中断、重试与锁竞争' python3 - "$harness" "$PROJECT_DIR" "$TEST_SANDBOX" <<'PY'
import errno
import os
import pathlib
import pty
import select
import signal
import subprocess
import sys
import termios
import time

harness, project, sandbox = sys.argv[1:]

def launch(root, action, marker=None, sig=signal.SIGINT, **extra):
    env = dict(os.environ, PROJECT_DIR=project, SBA_ROOT=str(root), **extra)
    pid, fd = pty.fork()
    if pid == 0:
        # 非交互父进程可能忽略 SIGINT；exec 前恢复，保证 Bash 能安装 trap。
        for inherited_sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(inherited_sig, signal.SIG_DFL)
        os.execvpe("bash", ["bash", harness, action], env)
    output = b""
    sent = marker is None
    status = None
    try:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.05)[0]:
                try:
                    output += os.read(fd, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
            if not sent and marker in output:
                # 提示输出不代表 read/wait 已开始；在运行态发送 INT 可能被 Bash
                # 延后到下一次输入之后。等内核确认已阻塞，再发送终端信号。
                process_status = pathlib.Path(f"/proc/{pid}/status").read_text()
                sleeping = any(line.startswith("State:\tS") for line in process_status.splitlines())
                if sleeping:
                    if sig == signal.SIGINT:
                        os.write(fd, b"\x03")
                    else:
                        os.killpg(pid, sig)
                    sent = True
            waited, status_now = os.waitpid(pid, os.WNOHANG)
            if waited:
                status = status_now
                # waitpid 可能先于最后一批终端输出到达；保留回滚诊断。
                while select.select([fd], [], [], 0)[0]:
                    try:
                        tail = os.read(fd, 65536)
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
                        break
                    if not tail:
                        break
                    output += tail
                break
        if status is None:
            tty = termios.tcgetattr(fd)
            process_status = pathlib.Path(f"/proc/{pid}/status").read_text()
            signal_status = "\n".join(line for line in process_status.splitlines() if line.startswith("Sig"))
            raise AssertionError(
                f"{action}: signal={sig}, sent={sent}, foreground_pgid={os.tcgetpgrp(fd)}, "
                f"child_pid={pid}, ISIG={bool(tty[3] & termios.ISIG)}, VINTR={tty[6][termios.VINTR]!r}\n"
                f"{signal_status}\n{output.decode(errors='replace')}"
            )
        assert sent, f"{action}: missing marker {marker!r}\n{output.decode(errors='replace')}"
        return os.waitstatus_to_exitcode(status), output
    finally:
        if status is None:
            os.killpg(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)

root = pathlib.Path(sandbox) / "pty-prompt"
code, out = launch(root, "prompt", "节点名称".encode())
assert code == 130, (code, out)
assert not (root / "mock/dependencies").exists()
assert not (root / "var/lib/singbox-agent/transaction").exists()
assert launch(root, "install")[0] == 0
assert (root / "usr/local/bin/sba").exists()

for sig, expected in [(signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 129)]:
    root = pathlib.Path(sandbox) / f"pty-package-{sig}"
    code, out = launch(root, "install", b"PACKAGE_READY", sig, WAIT_PACKAGE="1")
    assert code == expected, (code, out)
    assert not (root / "mock/package").exists(), out.decode(errors="replace")
    assert not (root / "var/lib/singbox-agent/transaction").exists(), (
        out.decode(errors="replace"),
        (root / "var/lib/singbox-agent/transaction/record.conf").read_text(),
        (root / "mock/systemctl.log").read_text(),
    )
    assert launch(root, "install")[0] == 0
    assert (root / "usr/local/bin/sba").exists()

root = pathlib.Path(sandbox) / "pty-failed-purge"
code, out = launch(root, "install", b"PACKAGE_READY", WAIT_PACKAGE="1", FAIL_PURGE="1")
assert code == 130, (code, out)
assert (root / "var/lib/singbox-agent/transaction/record.conf").exists()
assert (root / "etc/apt/sources.list.d/sagernet.sources").exists()
assert launch(root, "install")[0] == 0
assert (root / "usr/local/bin/sba").exists()

root = pathlib.Path(sandbox) / "pty-kill"
code, out = launch(root, "kill-uncommitted", b"TRANSACTION_READY", signal.SIGKILL)
assert code == -signal.SIGKILL, (code, out)
assert launch(root, "install")[0] == 0

root = pathlib.Path(sandbox) / "pty-lock"
env = dict(os.environ, PROJECT_DIR=project, SBA_ROOT=str(root))
holder = subprocess.Popen(["bash", harness, "lock-wait"], env=env, stdout=subprocess.PIPE, start_new_session=True)
try:
    assert select.select([holder.stdout], [], [], 5)[0], "lock holder did not start"
    assert holder.stdout.readline() == b"LOCK_READY\n"
    result = subprocess.run(["bash", harness, "lock-once"], env=env, capture_output=True, timeout=5)
    assert result.returncode == 1, result
    assert "已有安装或恢复正在运行" in result.stderr.decode()
finally:
    os.killpg(holder.pid, signal.SIGKILL)
    holder.wait()
PY
else
    printf '跳过：真实 Ctrl+C、HUP、TERM、SIGKILL 与锁竞争需要 Linux 伪终端。\n'
fi
printf '安装恢复：%s 项测试通过。\n' "$passed"
