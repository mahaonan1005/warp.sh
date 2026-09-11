# Outline WARP Safe

面向 Debian 11/12 公网 Outline Server 的 Cloudflare WARP WireGuard 双栈全局出站脚本。

适用范围是官方安装脚本创建的 `shadowbox` host-network 部署。自定义 Docker bridge、Kubernetes、多 VPN 或多网络管理器主机需要单独设计和验证。

它保留 P3TERX 全局模式的业务目标：

- 新建 IPv4、IPv6 普通出站连接走 WARP；
- Outline 连接目标网站的 TCP、UDP 流量走 WARP；
- SSH、Outline 入站和 Management API 的响应继续使用服务器原生线路。

它针对 Debian 12 重启失联增加了以下保护：

- 每次启动重新读取当前物理网卡与原生 IPv4/IPv6，不沿用安装时固化的地址；
- 为原生源地址创建高优先级 main-table 回程规则；
- systemd-networkd 存在时保留 wg-quick 创建的外部路由和策略规则；
- 固定 wgcf 2.2.32，并校验官方 GitHub Release SHA-256；
- 使用数字 WireGuard endpoint，减少开机 DNS 依赖；
- 不安装 openresolv，不改 /etc/resolv.conf；
- 不安装 wireguard-go；
- 启动必须通过握手、双栈 WARP、endpoint 路由、当前地址集合和原生回程检查；
- 启动失败只撤销本脚本拥有的规则，拆除后再次核对；
- 安装、启用和修复保留十分钟自动回退，外部验证后才允许开机自启；
- 管理动作和 systemd 运行动作使用两把独立锁，避免健康检查与卸载、修复并发；
- 不修改 Docker、Outline、Access Key、AWS、DNS或云防火墙。

## 当前状态

这是 1.0.0 候选版本。完成源码审阅、Bash语法、ShellCheck和模拟测试后，仍需在可丢弃的 Debian 11、Debian 12 实例分别完成两次重启及真实 Outline TCP/UDP 验收，再用于生产。

## 一键安装

安装器必须从普通文件运行。进程替换 `bash <(curl ...)` 无法安全复制正在执行的脚本，因此会被安装器拒绝。

先看计划，不修改系统：

    ( set -eu; t="$(mktemp)"; trap 'rm -f "$t"' EXIT; curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 10 --max-time 120 'https://raw.githubusercontent.com/mahaonan1005/warp.sh/c8f6a4193af8b46169260d85c1b2371009f22035/warp-d12-safe.sh' -o "$t"; printf '%s  %s\n' 'c14c9002133a609189aa786c9d3da7c2596af5040a2e135c84d05a61e3e079e9' "$t" | sha256sum -c -; bash "$t" plan )

一键安装候选配置：

    ( set -eu; t="$(mktemp)"; trap 'rm -f "$t"' EXIT; curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 10 --max-time 120 'https://raw.githubusercontent.com/mahaonan1005/warp.sh/c8f6a4193af8b46169260d85c1b2371009f22035/warp-d12-safe.sh' -o "$t"; printf '%s  %s\n' 'c14c9002133a609189aa786c9d3da7c2596af5040a2e135c84d05a61e3e079e9' "$t" | sha256sum -c -; sudo bash "$t" install --yes )

命令固定到完整 commit，同时再次核对脚本 SHA-256；不会跟随 `main` 后续变化。

安装完成时 WARP 只作为十分钟候选运行，主服务和健康 timer 尚未开机自启。立即从第二条新 SSH 连接和外部 Outline 测试 Key 验证 TCP、UDP。全部通过后执行：

    sudo outline-warp-safe confirm --yes

十分钟内没有确认，临时 systemd timer 会停止 WARP，让服务器回到原生路由。唯一 SSH 会话不适合作为确认依据。

## 日常命令

    sudo outline-warp-safe status
    sudo outline-warp-safe check
    sudo outline-warp-safe repair --yes
    sudo outline-warp-safe disable --yes
    sudo outline-warp-safe enable --yes
    sudo outline-warp-safe confirm --yes
    sudo outline-warp-safe uninstall --yes

`enable` 和 `repair` 也会进入十分钟候选期，需要再次完成外部验证并执行 `confirm --yes`。

同时删除本项目活动路径中的 WARP account：

    sudo outline-warp-safe uninstall --yes --purge-project-account

卸载会在 `/var/backups/outline-warp-safe` 留下 root-only 备份，不卸载可能由其他软件共享的 Debian 软件包。迁移前存在的旧 `wgcf.conf` 会恢复到原路径并保持禁用；`--purge-project-account` 不删除这份用户原有 profile。

## 发生失联时

从云厂商控制台执行：

    sudo outline-warp-safe disable --yes

如果 helper 本身无法运行，再执行：

    sudo systemctl disable --now outline-warp-health.timer
    sudo systemctl disable --now outline-warp.service

随后检查：

    ip link show wgcf
    ip -4 rule show
    ip -6 rule show
    ip -4 route get 1.1.1.1

不要执行 ip rule flush、nft flush ruleset 或 iptables -F。

## 工作方式

### 全局出站

wgcf.conf 保留：

    AllowedIPs = 0.0.0.0/0, ::/0

配置使用 `Table = off`，脚本再建立独立的 table 51888 与 fwmark 规则。这样可以记录每一条自有规则，拆除时无需刷新系统中的其他路由或防火墙。

### 原生回程

启动器在 WARP 上线前读取物理默认路由，并为该网卡当前的所有全局地址创建独立优先级：

    from <本地原生IPv4>/32 lookup main
    from <本地原生IPv6>/128 lookup main

在 Lightsail 等 1:1 NAT 环境中，这里使用 Linux 网卡上的本地私网 IPv4；控制台显示但未配置在网卡上的 Static IP 不参与 source rule。

### Fail-open

outline-warp.service 不依赖 Outline 或 Docker。WARP 失败时脚本主动撤销接口与 /0 路由，让 Shadowbox 和 SSH 继续使用原生网络。

健康检查同时验证：

1. wgcf 接口及本次运行的所有权标记；
2. 物理网卡、IPv4/IPv6 地址集合没有漂移；
3. 当前原生地址回程精确使用启动时的物理网卡；
4. WireGuard 外层 endpoint 使用同一物理网卡；
5. 普通 IPv4、IPv6 出站使用 wgcf；
6. 90 秒内的握手；
7. Cloudflare trace 的 IPv4 `warp=on/plus`；
8. Cloudflare trace 的 IPv6 `warp=on/plus`。

单一 Cloudflare trace 短暂失败不会立即改路由。连续三次普通失败后进行一次受控重启；回程路由错误会立即停用WARP。

systemd-networkd 正在管理主机并且 systemd 版本支持相关开关时，安装器会写入一个带管理标记的全局 drop-in，保留外部程序创建的 route 和 policy rule。它要到 networkd 下次启动时生效；安装器不会在远程会话中重启 networkd。该设置也会保留其他程序创建的外部路由，因此多网络管理器或多 VPN 主机不在本候选版的适用范围内。systemd 低于 249 时缺少所需开关，安装会在改动路由前停止；这主要影响使用 systemd-networkd 的 Debian 11 主机。

## 从旧 P3TERX 配置迁移

安装器会：

1. 备份现有 `/etc/wireguard/wgcf.conf`、已发现的 wgcf 账户、ip rule 和 route；
2. 下载并校验固定版 wgcf，在原生网络仍工作的阶段生成、解析和校验候选 profile；
3. 停止并禁用旧 `wg-quick@wgcf`；
4. 原子安装由本项目管理的新配置和 systemd unit；
5. 启动十分钟候选，等待第二条外部连接确认；
6. 保留旧备份和旧账号。卸载时可恢复原 profile，但保持禁用。

如果 warp-svc、warp-go 或 wg-quick@warp 仍启用，安装会停止。先决定唯一的WARP路由管理者。

## 与其他项目的取舍

| 项目 | 借鉴内容 | 未照搬内容 |
|---|---|---|
| P3TERX/warp.sh | /0全局路由、原生源地址查main | 安装时固定地址、开机无握手门、openresolv、动态短链接 |
| yonggekkk/warp-yg | 原生回程、失败后回原生 | systemd＋cron＋screen并行控制、锁定resolv.conf、curl -k、破坏式卸载 |
| distillium/warp-native | Table=off、Keepalive、握手检查 | 当前为应用绑定接口/IPv4路线，无法直接满足双栈全局目标 |
| rany2/warp.sh | 数字endpoint、MTU 1280、Keepalive | 只生成/0配置，没有SSH/Outline回程与启动保护 |
| MicroWARP | 每次容器启动动态捕获原路由、部分初始化清理 | 作为SOCKS sidecar，现有Shadowbox不能直接使用 |
| Docker-Warp-Socks | 网络命名空间隔离、显式健康检查 | 显式HTTP/SOCKS代理，不能透明承接现有Outline全部TCP/UDP |

参考：

- [P3TERX/warp.sh](https://github.com/P3TERX/warp.sh)
- [yonggekkk/warp-yg](https://github.com/yonggekkk/warp-yg)
- [distillium/warp-native](https://github.com/distillium/warp-native)
- [rany2/warp.sh](https://github.com/rany2/warp.sh)
- [ccbkkb/MicroWARP](https://github.com/ccbkkb/MicroWARP)
- [Mon-ius/Docker-Warp-Socks](https://github.com/Mon-ius/Docker-Warp-Socks)
- [WireGuard wg-quick](https://git.zx2c4.com/wireguard-tools/tree/src/wg-quick/linux.bash)
- [systemd-networkd Bookworm配置](https://manpages.debian.org/bookworm/systemd/networkd.conf.5.en.html)
- [Outline Server官方安装脚本](https://github.com/OutlineFoundation/outline-server/blob/master/src/server_manager/install_scripts/install_server.sh)

## 验收清单

只在可丢弃的 Debian 11、Debian 12 实例分别进行首轮验证：

1. 安装前保存原生route、rule、resolver、Outline容器和监听端口；
2. 安装成功后确认IPv4、IPv6均显示WARP；
3. 从两个外部网络验证SSH；
4. 使用独立测试Key验证Outline TCP；
5. 使用同一测试Key验证Outline UDP；
6. 执行一次 reboot；
7. 再执行一次云平台 stop/start，并检查本地地址是否变化；
8. 每次启动后核对握手、source rule、endpoint route和Shadowbox；
9. 模拟阻断WARP endpoint，确认 systemd 的 150 秒启动上限内失败并撤销 /0 路由；
10. 验证disable、enable、repair和uninstall后再次重启。

任一情况立即停止：

- SSH或Management API失联；
- 原生源地址route get显示wgcf；
- WARP无近期握手但 /0 路由仍存在；
- IPv4或IPv6只有一族通过；
- Outline TCP或UDP任一失败；
- 日志出现PrivateKey、Access Key或Management apiUrl；
- networkd、Docker或其他VPN重复改写相同规则。

## 安全边界

- wgcf是第三方非官方工具；WARP服务可用性和Cloudflare API变化不由本项目控制。
- 当前范围是单上游、单路由管理者的 Debian 11/12 Outline 主机；多上游、VRF、多 VPN 和自定义策略路由需要单独设计。
- 为了保持 SSH、Outline 入站与 Management API 可达，显式绑定服务器原生地址的响应流量保留在原生线路。
- 完整 /etc/wireguard/wgcf.conf 与 wgcf-account.toml 是凭据，只能root读取。
- 脚本日志从不打印配置正文。
- 项目不保存或处理Outline Access Key与Management apiUrl。
- 这份候选版没有连接或修改任何真实 Outline Server；静态测试无法替代重启和外部 TCP/UDP 验收。
- 新的一键链接使用GitHub raw URL；git.io不能创建新的可控短链接。
- 使用前应确认Cloudflare条款、云厂商政策及适用地区规则。

## License

MIT。新脚本为独立实现；参考项目及其许可证见上方链接。
