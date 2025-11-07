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


## 📦 基础信息
- **硬件平台**: Rockchip ARMv8
- **源码基础**: [OpenWrt 官方仓库](https://github.com/openwrt/openwrt)
- **管理地址**: `192.168.5.100`
- **登录密码**: `password`（可为空）

## ⚡ 性能增强
- **硬件优化**: CPU动态调频、PWM风扇控制
- **系统调优**: 中断负载均衡、Multi-Gen LRU
- **网络加速**: Shortcut-FE流量卸载

## 🌐 网络与服务
- **网络功能**: NAT6、全锥型NAT（兼容Nftables/Broadcom）
- **容器支持**: Docker 28.5.2（国内镜像源、IPv6桥接）
- **Web服务**: nginx替代uhttpd
- **安全防护**: WAN口防火墙默认启用
- **远程访问**: 所有LAN口支持网页终端和SSH
