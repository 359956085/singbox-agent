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

主地址为 IPv4 时，还会询问附加公网 IPv6。脚本探测地址后供确认，也可手工输入；输入 `-` 跳过。重新配置时按回车保留已有 IPv6，输入 `-` 移除。主地址为 IPv6 的单栈安装保持原有行为，不重复生成另一套 IPv6 节点。

端口留空时随机选择。Reality 目标留空时，随机探测内置 AWS 新加坡候选，选择通过 DNS、TLS 1.3 和证书校验的站点；也可手工输入目标。已有节点的目标不会自动迁移。

内置候选端口均为 `443`：

| 域名 | 网站用途 |
| --- | --- |
| `hungrygowhere.com` | 新加坡美食资讯与餐厅推荐 |
| `www.janio.asia` | 跨境物流与供应链服务 |
| `servishero.com` | 家政与维修服务 |
| `mochajs.org` | Mocha JavaScript 测试框架 |
| `gohugo.io` | Hugo 静态网站生成器 |

2026-11-17 从 Ubuntu4 复核：上述域名当时解析出的 IPv4、IPv6 地址均匹配 [AWS 官方地址段](https://docs.aws.amazon.com/vpc/latest/userguide/aws-ip-ranges.html)的 `ap-southeast-1` 区域及同名网络边界组；所有 IPv4 地址通过 TLS 1.3、HTTP/2 和证书校验，各域名首页 HEAD 请求返回 `200`。IPv6 仅核对地址归属，未做连接验收。后四个域名共享区域前端，故障独立性有限。

这是实测后的静态名单，不保留原全球站点兜底。DNS 和部署区域可能变化；安装时仅沿用 DNS、TLS 和证书检测，不下载 AWS 地址段或保证接入区域仍为新加坡。候选均不可用时会提示手工输入目标。

节点参数在安装依赖和 sing-box 软件包之前询问。按 Ctrl+C 取消后，可再次执行同一条一键安装命令。脚本会先恢复未完成安装，再开始新的安装；SSH 断开或进程强制终止后也会在下次安装时检查恢复记录。

如果旧版中断后只留下已安装的 sing-box 软件包，新版会在配置目录没有配置文件或链接、服务未运行、没有自定义服务覆盖及同名 nginx 配置时自动复用它。复用的软件包在回滚和后续卸载时保留；已有业务配置仍会拒绝接管。

回滚失败时会显示具体失败项，并保留 `/var/lib/singbox-agent/transaction` 中的恢复记录和备份。卸载 sing-box 失败时同时保留 APT 源和密钥。处理提示中的问题（例如 APT 锁或软件包错误）后，重新执行安装即可重试恢复；不要手工删除恢复目录。并发安装会被拒绝。

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

查看配置时会分别显示 VLESS/Shadowrocket 与 Clash/Mihomo 订阅。终端二维码编码较短的 Base64 VLESS 订阅 URL；PNG 保留原始 VLESS 单节点二维码。

配置附加 IPv6 后，输出按 IPv4、IPv6 分组，每组提供直连链接、独立订阅、订阅终端二维码和单节点 PNG。IPv6 节点名称追加 `-IPv6`；两种地址使用同一端口、UUID、Reality 密钥、short ID 和订阅令牌。`sba show` 仅展示已保存的配置；修改地址需执行新版脚本的 `install` 或 `sba install` 重新配置。

## 在线订阅

- `http://服务器地址:订阅端口/sub/令牌`：Clash/Mihomo YAML，适用于 Clash Verge、Mihomo。
- `http://服务器地址:订阅端口/sub/令牌/vless`：Base64 VLESS，适用于支持 VLESS URI 订阅的客户端。
- 直接访问订阅端口根路径会返回 nginx `404 Not Found`。这是精确路径保护的预期行为，不代表端口不通。
- 更新旧安装后，执行 `sba install` 重新配置。原订阅 URL、UUID、Reality 密钥和令牌保持不变。

双栈配置的两套订阅完全独立：IPv4 URL 只返回 IPv4 节点，IPv6 URL 只返回 IPv6 节点，不合并为双节点订阅。原 IPv4 URL 和文件路径保持不变。IPv6 URL 格式为：

```text
http://[公网IPv6]:订阅端口/sub/令牌
http://[公网IPv6]:订阅端口/sub/令牌/vless
```

IPv6 订阅通过 IPv6 下载，节点连接也走 IPv6，客户端当前网络必须具备公网 IPv6 连通性。服务器配置 IPv6 不代表客户端网络也能使用 IPv6。IPv6 订阅无法下载时，不会自动改用 IPv4。

## 防火墙

脚本仅在 UFW 已启用时添加 Reality 和订阅 TCP 端口。云服务器安全组或云防火墙仍需手工放行这两个 TCP 端口。

使用 IPv6 时还需在网卡配置公网 IPv6 和默认路由，并为节点、订阅两个端口放行 IPv6 TCP 入站。IPv4 放行规则不能替代 IPv6 规则。脚本检查本机 IPv6 配置和监听，并提示可能缺少的 UFW IPv6 规则；不会自动修改系统 IPv6、UFW 全局设置或云防火墙。本地监听检查通过仍需从外部 IPv6 网络验证连接。

## 安全说明

- Reality 私钥、VLESS 链接和二维码仅保存在 root 可读目录。
- 在线订阅使用随机 32 字节路径令牌，nginx 不记录该虚拟主机访问日志。
- 无域名订阅只能使用 HTTP。链路观察者可能看到订阅 URL。请把完整 URL 当作密码保存。
- 脚本不会接管已有 sing-box 业务配置、运行中的服务或自定义服务覆盖，也不会覆盖同名 nginx 配置；仅复用通过检查的未配置软件包。
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

附加 IPv6 产物为 `/etc/singbox-agent/vless-ipv6-uri.txt`、`/etc/singbox-agent/vless-ipv6.png`（均为 `600` 权限），以及 `/var/lib/singbox-agent/www/clash-ipv6.yaml`、`/var/lib/singbox-agent/www/vless-ipv6.txt`。移除附加 IPv6 时清理这些文件及对应监听；卸载时一并清理。

## 本地检查

```bash
for script in install.sh tests/*.sh; do bash -n "$script"; done
bash tests/test.sh
shellcheck -x install.sh tests/test.sh tests/recovery.sh tests/ipv6.sh
```

集成验收需在全新 Debian 或 Ubuntu 虚拟机执行。不要在已有 sing-box 业务的机器上测试安装流程。

恢复测试使用临时根目录及系统命令替身；Linux 下额外使用 Python 3 伪终端发送真实 Ctrl+C，并验证安装中断后重试、其他信号和安装锁。该测试不安装软件包或修改真实服务。

在具备 IPv6 回环、`sing-box`、`nginx`、`curl`、`jq`、`openssl` 和 Python 3 的 Linux 测试环境，可执行 `SBA_TEST_DUAL_STACK=1 bash tests/ipv6.sh`，临时启动真实进程，验证双栈节点监听、两套订阅内容和精确路径保护；测试结束关闭进程并清理临时目录。事务记录使用版本 `2`，同时支持恢复旧版事务，完成状态版本仍为 `1`。

## 许可证

[AGPL-3.0](LICENSE)
