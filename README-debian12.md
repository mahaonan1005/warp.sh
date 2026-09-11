# Debian 12 minimal DNS fix

这是 P3TERX `warp.sh d` 的 Debian 12 最小修正版。

## 唯一功能改动

原脚本在 Debian 上安装 `openresolv`。Debian 12 Lightsail 镜像原本使用独立的 `systemd-resolved` 包；安装 `openresolv` 会移除它，同时留下指向 `/run/systemd/resolve/resolv.conf` 的链接。安装当次仍可使用，reboot 清空 `/run` 后 DNS 失效。

本脚本只调整 Debian 安装依赖：

- Debian 12：安装或保留 `systemd-resolved`
- 其他原脚本支持的 Debian 版本：继续使用 `openresolv`
- WARP 配置、路由、交互、systemd 自启和其他功能保持 P3TERX 原逻辑

基线为 P3TERX 归档版本 `1.0.40_Final`，固定上游 commit `c4ef402c556f3e17c67009dd9d5fbac06c1bcb80`。

## 一键安装

已经是 root 用户：

```bash
bash <(curl -fsSL https://github.com/mahaonan1005/warp.sh/raw/557bd4b/warp-debian12.sh) d
```

Debian/Lightsail 默认 `admin` 用户：

```bash
sudo bash -c 'bash <(curl -fsSL https://github.com/mahaonan1005/warp.sh/raw/557bd4b/warp-debian12.sh) d'
```

脚本 SHA-256：

```text
dc97bbcc80e3360ab12a67316f7a7ca5d51209638964a55b41e36520a9fa58ba
```

## 已验证

2026-09-11 在一台 Debian 12 AWS Lightsail 测试实例完成：

1. 原版安装后可用；
2. reboot 后复现 DNS 失效；
3. 确认 WARP 路由、握手和 Outline 监听正常，故障集中在悬空 `/etc/resolv.conf`；
4. 安装 `systemd-resolved` 后 reboot 通过；
5. 使用本分支脚本重新安装并再次 reboot，域名解析、IPv4/IPv6 `warp=on`、Outline host-network 容器和 TCP/UDP 监听均正常。

实机验证没有读取或记录 Outline Access Key。使用者仍应自行验证一条测试 Key 的 TCP 与 UDP 数据面。

## 上游与许可

- [P3TERX 使用教程](https://p3terx.com/archives/cloudflare-warp-configuration-script.html)
- [P3TERX/warp.sh](https://github.com/P3TERX/warp.sh)
- [Debian 12 systemd-resolved](https://packages.debian.org/bookworm/systemd-resolved)

沿用上游 MIT License。
