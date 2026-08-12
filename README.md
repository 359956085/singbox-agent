# singbox-agent

仅用于快速安装 sing-box 无域名 Reality：

- 协议：VLESS + TCP + Reality + Vision
- 系统：Debian / Ubuntu，systemd
- 架构：amd64 / arm64
- 产物：VLESS 链接、本地二维码、PNG、Clash/Mihomo YAML 与 Base64 VLESS 在线订阅

## 一键安装

使用 root 用户执行：

```bash
apt-get update && apt-get install -y wget ca-certificates && wget -O /tmp/singbox-agent.sh https://raw.githubusercontent.com/359956085/singbox-agent/main/install.sh && chmod 700 /tmp/singbox-agent.sh && /tmp/singbox-agent.sh install
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
```

`sba` 打开交互式管理菜单：

1. 安装或重新配置。
2. 查看配置与二维码。
3. 更新 sing-box。
4. 卸载。
0. 退出。

兼容原有命令：`sba install`、`sba show`、`sba update`、`sba uninstall`。

## 在线订阅

- `http://服务器地址:订阅端口/sub/令牌`：Clash/Mihomo YAML，适用于 Clash Verge、Mihomo。
- `http://服务器地址:订阅端口/sub/令牌/vless`：Base64 VLESS，适用于支持 VLESS URI 订阅的客户端。
- 直接访问订阅端口根路径会返回 nginx `404 Not Found`。这是精确路径保护的预期行为，不代表端口不通。
- 更新旧安装后，执行 `sba install` 重新配置。原订阅 URL、UUID、Reality 密钥和令牌保持不变。

## 防火墙

脚本仅在 UFW 已启用时添加 Reality 和订阅 TCP 端口。云服务器安全组或云防火墙仍需手工放行这两个 TCP 端口。

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
/var/lib/singbox-agent/www/clash.yaml
/var/lib/singbox-agent/www/vless.txt
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
