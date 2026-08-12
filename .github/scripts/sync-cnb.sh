#!/usr/bin/env bash

# GitHub Actions 检查通过后，将当前 main 提交安全同步到 CNB。
# 作者：fengshi

set -Eeuo pipefail

readonly DEFAULT_CNB_REPOSITORY_URL="https://cnb.cool/359956085/singbox-agent"
readonly CNB_REPOSITORY_URL="${CNB_REPOSITORY_URL:-$DEFAULT_CNB_REPOSITORY_URL}"
ASKPASS_FILE=""

cleanup() {
    if [[ -n "$ASKPASS_FILE" && -f "$ASKPASS_FILE" ]]; then
        rm -f -- "$ASKPASS_FILE"
    fi
}

fatal() {
    printf '[错误] %s\n' "$*" >&2
    exit 1
}

trap cleanup EXIT INT TERM

[[ -n "${CNB_TOKEN:-}" ]] || fatal "未配置 CNB_TOKEN。"
[[ "$CNB_REPOSITORY_URL" == https://cnb.cool/* ]] || fatal "CNB 仓库必须使用官方 HTTPS 地址。"

ASKPASS_FILE="$(mktemp "${RUNNER_TEMP:-/tmp}/cnb-askpass.XXXXXX")"
cat >"$ASKPASS_FILE" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    *Username*) printf '%s\n' 'cnb' ;;
    *Password*) printf '%s\n' "${CNB_TOKEN:?}" ;;
    *) exit 1 ;;
esac
EOF
chmod 700 "$ASKPASS_FILE"
export GIT_ASKPASS="$ASKPASS_FILE"
export GIT_TERMINAL_PROMPT=0

if git remote get-url cnb >/dev/null 2>&1; then
    git remote set-url cnb "$CNB_REPOSITORY_URL"
else
    git remote add cnb "$CNB_REPOSITORY_URL"
fi

if git fetch --no-tags cnb main; then
    if git merge-base --is-ancestor HEAD refs/remotes/cnb/main; then
        printf '[信息] 当前提交已包含在 CNB main，无需重复同步。\n'
        exit 0
    fi
fi

# 禁止强制推送；CNB 历史分叉时由 Git 拒绝，避免覆盖独立提交。
git push cnb HEAD:refs/heads/main
printf '[成功] 已同步当前提交到 CNB main。\n'
