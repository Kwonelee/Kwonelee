# istoreos_pkgs
备份一些插件/依赖源码

- [zhao](https://git.kejizero.online/zhao)
- [packages](https://github.com/sos801107/packages)
- [istoreos-ipk](https://github.com/Jaykwok2999/istoreos-ipk)
- [istoreos-theme](https://github.com/Jaykwok2999/istoreos-theme)
- [adguardhome](https://github.com/w9315273/luci-app-adguardhome)
- [immortalwrt/luci](https://github.com/immortalwrt/luci)
- [immortalwrt/packages](https://github.com/immortalwrt/packages)
- [jjm2473/luci](https://github.com/jjm2473/luci)
- [jjm2473/packages](https://github.com/jjm2473/packages)
- [sbwml/openwrt_pkgs](https://github.com/sbwml/openwrt_pkgs)


## 🛠 源码基础
- **平台架构**: Rockchip ARMv8
- **源码来源**: [OpenWrt 官方仓库](https://github.com/openwrt/openwrt)

## ⚙️ 默认设置
- **管理地址**: `192.168.5.100`
- **登录密码**: `password`（可为空）
- **访问方式**: 所有 LAN 口支持网页终端和 SSH
- **安全保护**: WAN 口默认启用防火墙
- **容器加速**: Docker 已配置国内镜像源

## 🚀 Rockchip 性能增强
- **CPU 管理**: 动态调频与性能调节
- **散热控制**: PWM 风扇控制
- **系统优化**: 
  - 中断负载均衡
  - Multi-Gen LRU 页面回收
  - Shortcut-FE 流量卸载

## 🌐 网络与容器
- **网络特性**:
  - 支持 NAT6
  - 全锥型 NAT（兼容 Nftables / Broadcom）
- **容器服务**:
  - Docker 28.5.2
  - 桥接网络 IPv6 支持
- **Web 服务**: 使用 nginx 替代 uhttpd
