#!/bin/sh
# HigoOS 保真 overlay —— 首次启动配置（uci-defaults，只跑一次）
# 目标：与原厂 HigoOS 的出厂网络状态一致 —— LAN 192.168.88.1，
#       海狗前端占 80，传统 LuCI(uhttpd) 在 8080。

# 1) 启用海狗后端与风扇服务
[ -x /etc/init.d/higoros ] && /etc/init.d/higoros enable
[ -x /etc/init.d/fancontrol ] && /etc/init.d/fancontrol enable

# 1b) QModem 模组支持库的**提前合并**（START=78，早于 qmodem_init 的 80）
#     modem_scand 只在启动时读一次支持库并缓存，而库的镜像版本不含 RG520N-CN
#     （那一条由 luci-app-qmodem-generic 的 S90 服务运行时 merge）。不提前合并，
#     daemon 就带着「不认识这块模组」的库启动，之后所有补扫都报 profile not matched。
#     该服务同步执行注入器，且注入器幂等，因此 S90 那一遍自然退化为空操作。
[ -x /etc/init.d/qmodem-support-early ] && /etc/init.d/qmodem-support-early enable

# 1c) QModem 模组识别补扫服务
#     镜像里确实出现过 S92 软链，但仓库里没有任何一行显式启用它（uci-defaults 与
#     构建脚本都没有），说明它靠的是构建期的隐式行为。这里显式补上，不再依赖隐式：
#     脚本自带 START=92，enable 会生成 S92/K08。
#     注意：uci-defaults 跑在 /etc/init.d/boot (START=10) 内，而 rcS 在开始时就
#     展开了一次 /etc/rc.d/S* 列表 —— 所以**刷机后的首次开机**这一轮可能不在列表里，
#     第二次开机起必然生效（与原有的隐式机制行为一致）。
[ -x /etc/init.d/qmodem-rescan ] && /etc/init.d/qmodem-rescan enable

# 2) 若底座带了其他风扇后台，禁掉，避免两个控制器抢 pwm
#    （海狗页 + /usr/bin/fancontrol v2 是唯一管理者）
for SVC in h5000m-fancontrol fancontrol-h5000m; do
    [ -x "/etc/init.d/$SVC" ] && /etc/init.d/"$SVC" disable 2>/dev/null
done

# 3) 网络：延续 HigoOS 出厂值 192.168.88.1
#    底座默认是 192.168.1.1，既不是原厂值、又和常见内网撞段，这里覆盖。
#    不在这里 restart network：uci-defaults 跑在 /etc/init.d/boot（START=10）里，
#    早于 network（START=20），落盘即可被后续启动流程读到。
uci -q set network.lan.proto='static'
uci -q set network.lan.ipaddr='192.168.88.1'
uci -q set network.lan.netmask='255.255.255.0'
uci -q set network.lan.ip6assign='60'
uci -q commit network

uci -q set dhcp.lan.interface='lan'
uci -q set dhcp.lan.start='100'
uci -q set dhcp.lan.limit='150'
uci -q set dhcp.lan.leasetime='12h'
uci -q set dhcp.lan.dhcpv4='server'
uci -q set dhcp.lan.dhcpv6='disabled'
uci -q set dhcp.lan.ra='server'
uci -q set dhcp.lan.ra_slaac='1'
uci -q set dhcp.lan.ra_flags='other-config'
uci -q set dhcp.lan.max_preferred_lifetime='2700'
uci -q set dhcp.lan.max_valid_lifetime='5400'
uci -q commit dhcp

# 主机名带空格，正是原厂值 —— 必须走 uci，不能用 hostname 命令
uci -q set system.@system[0].hostname='Hiveton H5000M'
uci -q commit system

# 4) 端口腾挪：higorosd 固定监听 :80（海狗前端），传统 LuCI(uhttpd) 挪 8080/8443
#    与原厂 24.10 布局一致：80 = 海狗，8080 = 传统 LuCI
if [ -f /etc/config/uhttpd ]; then
    uci -q set uhttpd.main.listen_http='0.0.0.0:8080'
    uci -q set uhttpd.main.listen_https='0.0.0.0:8443'
    uci -q commit uhttpd
    /etc/init.d/uhttpd restart 2>/dev/null
fi

# 5) U-Boot 环境文件 —— 「一句话进 failsafe」的前提
#    uboot-envtools 包只提供 fw_printenv/fw_setenv，不带 /etc/fw_env.config，
#    overlay 里已经放了一份；这里只在它缺失/指错设备时兜底重写。
#    偏移与大小是实测出来的（CRC32 反推 env_size=0x80000），不要改动。
if [ ! -s /etc/fw_env.config ] || ! grep -q 'mmcblk0p1' /etc/fw_env.config 2>/dev/null; then
    cat > /etc/fw_env.config <<'EOF'
# Hiveton H5000M — U-Boot environment (see higoros-overlay/etc/fw_env.config)
/dev/mmcblk0p1	0x0	0x80000	0x200	0x400
EOF
fi
[ -f /usr/bin/to-failsafe ] && chmod +x /usr/bin/to-failsafe 2>/dev/null

# 6) 无线兜底：保证 radio 使能、国家码 CN（mt76 首启一般会自动生成）
uci -q set wireless.radio0.country='CN' 2>/dev/null
uci -q set wireless.radio1.country='CN' 2>/dev/null
uci -q commit wireless 2>/dev/null

exit 0
