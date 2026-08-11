# singbox-agent

仅用于快速安装 sing-box 无域名 Reality：

- 协议：VLESS + TCP + Reality + Vision
- 系统：Debian / Ubuntu，systemd
- 架构：amd64 / arm64
- 产物：VLESS 链接、本地二维码、PNG、Base64 在线订阅

## 一键安装

使用 root 用户执行：

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/359956085/singbox-agent/main/install.sh \
  -o /tmp/singbox-agent.sh \
  && chmod 700 /tmp/singbox-agent.sh \
  && sudo /tmp/singbox-agent.sh install
```

安装过程会询问：

1. 节点名称。
2. 公网 IPv4 或 IPv6。
3. Reality 端口。
4. HTTP 订阅端口。
5. Reality 目标域名与端口。

端口留空时随机选择。Reality 目标留空时，从内置候选中选择通过 DNS、TLS 1.3 和证书校验的站点。

## 管理

```bash
sba
sba show
sba update
sba uninstall
```

- `sba`：打开菜单。
- `sba install`：重新配置，保留 UUID、Reality 密钥和订阅令牌。
- `sba show`：显示链接、二维码、服务状态和订阅 URL。
- `sba update`：下载候选 DEB，预检配置后更新；失败时尝试回滚。
- `sba uninstall`：只清理本项目拥有的资源。

## 防火墙

脚本仅在 UFW 已启用时添加 Reality 和订阅 TCP 端口。云服务器安全组仍需手工放行对应端口。

## 安全说明

- Reality 私钥、VLESS 链接和二维码仅保存在 root 可读目录。
- 在线订阅使用随机 32 字节路径令牌，nginx 不记录该虚拟主机访问日志。
- 无域名订阅只能使用 HTTP。链路观察者可能看到订阅 URL。请把完整 URL 当作密码保存。
- 脚本不会覆盖已有 sing-box 安装或同名 nginx 配置。
- 不会调用第三方二维码服务。

## 主要文件

```text
/etc/sing-box/config.json
/etc/singbox-agent/state.conf
/etc/singbox-agent/vless-uri.txt
/etc/singbox-agent/vless.png
/var/lib/singbox-agent/www/subscription.txt
/etc/nginx/sites-available/singbox-agent-subscription
/usr/local/bin/sba
```

## 本地检查

```bash
bash -n install.sh
bash tests/test.sh
shellcheck -x install.sh tests/test.sh
```

集成验收需在全新 Debian 或 Ubuntu 虚拟机执行。不要在已有 sing-box 业务的机器上测试安装流程。

## 许可证

[AGPL-3.0](LICENSE)
