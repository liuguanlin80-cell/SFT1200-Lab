#!/bin/bash
# SFT1200-Lab firmware customization, reviewed against source on 2026-09-09.
# Compilation and hardware verification are still required.
set -euo pipefail

test -f Makefile
test -s .sft1200-lab/base.config || {
    echo 'ERROR: The replacement diy-part1.sh must run before this script.' >&2
    exit 1
}

fetch_source() {
    local repository="$1" revision="$2" destination="$3"
    if [ -d "$destination/.git" ]; then
        test "$(git -C "$destination" rev-parse HEAD)" = "$revision" || {
            echo "ERROR: Unexpected existing source revision in $destination" >&2
            return 1
        }
    else
        test ! -e "$destination"
        git init "$destination"
        git -C "$destination" remote add origin "$repository"
        git -C "$destination" fetch --depth 1 origin "$revision"
        git -C "$destination" checkout --detach FETCH_HEAD
        test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
    fi
}

fetch_source https://github.com/Zxilly/UA2F.git \
    b7009eea5b6548631ec3a555b1fe737a86c58b54 package/sft1200-lab-ua2f
fetch_source https://github.com/CHN-beta/rkp-ipid.git \
    073e389703853aeaced6cf1299ca8fbe60635614 package/sft1200-lab-ipid

python3 - <<'SFT1200_PREPARE_PY'
from pathlib import Path
import re

def replace_once(path, old, new):
    text = path.read_text(encoding='utf-8')
    if new in text:
        return
    if text.count(old) != 1:
        raise SystemExit(f'ERROR: Compatibility patch does not match {path}: {old!r}')
    path.write_text(text.replace(old, new, 1), encoding='utf-8')

ua = Path('package/sft1200-lab-ua2f')
ipid = Path('package/sft1200-lab-ipid')

# The SDK uses GCC 7.4 and CMake 3.19.1. All used C language features are C11.
# CMP0135 affects archive timestamps for test dependencies; tests are disabled.
replace_once(ua / 'CMakeLists.txt', 'set(CMAKE_C_STANDARD 17)',
             'set(CMAKE_C_STANDARD 11)')
replace_once(ua / 'CMakeLists.txt', 'cmake_policy(SET CMP0135 NEW)',
             'if(POLICY CMP0135)\n    cmake_policy(SET CMP0135 NEW)\nendif()')

# Use this SDK's firewall3/iptables package names; avoid unrelated nftables deps.
makefile = ua / 'openwrt/Makefile'
text = makefile.read_text(encoding='utf-8')
dependencies = '''  DEPENDS:= \\
    +libnetfilter-conntrack \\
    +libnetfilter-queue \\
    +libmnl \\
    +libnfnetlink \\
    +libatomic \\
    +libpthread \\
    +libuci \\
    +ip-full \\
    +iptables-mod-conntrack-extra \\
    +iptables-mod-filter \\
    +iptables-mod-nfqueue \\
    +iptables-mod-tproxy
'''
text, count = re.subn(r'  DEPENDS:=[\s\S]*?(?=endef)', lambda _: dependencies, text, count=1)
if count != 1:
    raise SystemExit('ERROR: UA2F package dependency block was not found.')
makefile.write_text(text, encoding='utf-8')

source = ipid / 'src/rkp-ipid.c'
replace_once(source, '#include <linux/moduleparam.h>',
             '#include <linux/moduleparam.h>\n#include <net/ip.h>')
replace_once(source, 'mark_capture = 0x10;', 'mark_capture = 0x10000000;')
replace_once(source, 'mark_random = 0x20;', 'mark_random = 0x20000000;')
replace_once(source, '\tiph = ip_hdr(skb);\n\t\n#if LINUX_VERSION_CODE',
             '\tif (!pskb_may_pull(skb, sizeof(struct iphdr)))\n'
             '\t\treturn NF_ACCEPT;\n'
             '\tiph = ip_hdr(skb);\n'
             '\t/* Preserve fragment IDs so reassembly remains possible. */\n'
             '\tif (iph->ihl < 5 || ip_is_fragment(iph))\n'
             '\t\treturn NF_ACCEPT;\n\n#if LINUX_VERSION_CODE')
replace_once(source, 'skb_ensure_writable(skb, (char*)iph - (char*)skb -> data + 6)',
             'skb_ensure_writable(skb, (char*)iph - (char*)skb -> data + iph->ihl * 4)')
replace_once(source, 'skb_make_writable(skb, (char*)iph - (char*)skb -> data + 6)',
             'skb_make_writable(skb, (char*)iph - (char*)skb -> data + iph->ihl * 4)')
replace_once(source, '\treturn 0;\n}\n\nstatic void __exit hook_exit',
             '\treturn ret;\n}\n\nstatic void __exit hook_exit')
replace_once(ipid / 'Makefile', '\tKCONFIG:=',
             '\tDEPENDS:=+kmod-ipt-core +kmod-nf-conntrack-netlink +kmod-nfnetlink-queue\n'
             '\tKCONFIG:=CONFIG_NETFILTER_NETLINK_GLUE_CT=y CONFIG_NF_CONNTRACK_MARK=y')
replace_once(ipid / 'Makefile', 'PKG_RELEASE:=2', 'PKG_RELEASE:=3')

# Start with the SDK baseline saved by diy-part1.sh, not the inherited large
# third-party configuration copied into place by the old repository template.
baseline = Path('.sft1200-lab/base.config')
text = baseline.read_text(encoding='utf-8')
required = 'CONFIG_TARGET_siflower_sf19a28_fullmask_SF19A28-GL-SFT1200=y'
if required not in text.splitlines():
    raise SystemExit('ERROR: Saved SDK baseline is not for GL-SFT1200.')
settings = {
    'CONFIG_PACKAGE_ua2f': 'y',
    'CONFIG_PACKAGE_kmod-rkp-ipid': 'y',
    'CONFIG_PACKAGE_iptables': 'y',
    'CONFIG_PACKAGE_ip6tables': 'y',
    'CONFIG_PACKAGE_iptables-mod-ipopt': 'y',
    'CONFIG_PACKAGE_iptables-mod-nfqueue': 'y',
    'CONFIG_PACKAGE_iptables-mod-conntrack-extra': 'y',
    'CONFIG_PACKAGE_kmod-ipt-ipopt': 'y',
    'CONFIG_PACKAGE_kmod-ipt-nfqueue': 'y',
    'CONFIG_PACKAGE_kmod-nf-conntrack-netlink': 'y',
    'CONFIG_PACKAGE_kmod-nfnetlink-queue': 'y',
    'CONFIG_PACKAGE_libatomic': 'y',
    'CONFIG_PACKAGE_flock': 'y',
    'CONFIG_PACKAGE_ip-full': 'y',
    'CONFIG_PACKAGE_luci': 'y',
    'CONFIG_PACKAGE_luci-i18n-base-zh-cn': 'y',
    'CONFIG_PACKAGE_tcpdump-mini': 'y',
    'CONFIG_PACKAGE_iptables-nft': 'n',
    'CONFIG_PACKAGE_ip6tables-nft': 'n',
    'CONFIG_PACKAGE_nftables': 'n',
    'CONFIG_UA2F_ENABLE_LIBBACKTRACE': 'n',
    'CONFIG_UA2F_CUSTOM_USER_AGENT': 'n',
}
lines = []
for line in text.splitlines():
    name = line[2:-11] if line.startswith('# CONFIG_') and line.endswith(' is not set') else line.split('=', 1)[0]
    if name not in settings:
        lines.append(line)
for name, value in settings.items():
    lines.append(f'# {name} is not set' if value == 'n' else f'{name}={value}')
Path('.config').write_text('\n'.join(lines) + '\n', encoding='utf-8')
print('SDK configuration and source compatibility patches prepared.')

SFT1200_PREPARE_PY

mkdir -p 'files/etc/config'
cat > 'files/etc/config/ua2f' <<'SFT1200_FILE_3'
config ua2f 'enabled'
	option enabled '1'

config ua2f 'firewall'
	option handle_fw '0'
	option handle_tls '0'
	option handle_intranet '1'

config ua2f 'main'
	option mode 'NFQUEUE'
	option nfqueue_workers '1'
	option disable_connmark '1'
	option custom_ua 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
	option max_http_sessions '1024'
	option session_ttl '120'
SFT1200_FILE_3
chmod 0644 'files/etc/config/ua2f'

mkdir -p 'files/etc/hotplug.d/iface'
cat > 'files/etc/hotplug.d/iface/99-sft1200-lab' <<'SFT1200_FILE_6'
#!/bin/sh
case "$ACTION" in
    ifup|ifupdate|ifdown) ;;
    *) exit 0 ;;
esac
case "$INTERFACE" in
    wan|wan6) /usr/sbin/sft1200-lab-apply ;;
esac
SFT1200_FILE_6
chmod 0755 'files/etc/hotplug.d/iface/99-sft1200-lab'

mkdir -p 'files/etc/init.d'
cat > 'files/etc/init.d/sft1200-lab' <<'SFT1200_FILE_8'
#!/bin/sh /etc/rc.common
START=98
STOP=10

start() {
    /usr/sbin/sft1200-lab-apply
}

reload() {
    /usr/sbin/sft1200-lab-apply
}
SFT1200_FILE_8
chmod 0755 'files/etc/init.d/sft1200-lab'

mkdir -p 'files/etc/init.d'
cat > 'files/etc/init.d/sft1200-mac' <<'SFT1200_FILE_9'
#!/bin/sh /etc/rc.common
START=18
STOP=89

start() {
    local mac
    . /lib/functions.sh
    config_load firewall
    config_foreach disable_offload defaults
    [ "$(uci -q get network.wan)" = 'interface' ] || {
        logger -t sft1200-lab 'ERROR: WAN interface configuration is missing.'
        return 1
    }
    if [ ! -s /tmp/sft1200-wan.mac ]; then
        umask 077
        mac="02$(hexdump -n 5 -v -e '5/1 ":%02x"' /dev/urandom)"
        echo "$mac" | grep -Eq '^02(:[0-9a-f]{2}){5}$' || return 1
        printf '%s\n' "$mac" > /tmp/sft1200-wan.mac
    fi
    mac="$(cat /tmp/sft1200-wan.mac)"
    # Save to the volatile UCI delta before netifd starts. No per-boot flash write.
    uci set network.wan.macaddr="$mac" || return 1
    logger -t sft1200-lab "WAN MAC for this boot: $mac"
}

disable_offload() {
    uci set "firewall.$1.flow_offloading=0"
    uci set "firewall.$1.flow_offloading_hw=0"
}
SFT1200_FILE_9
chmod 0755 'files/etc/init.d/sft1200-mac'

mkdir -p 'files/etc/uci-defaults'
cat > 'files/etc/uci-defaults/99-z-sft1200-lab' <<'SFT1200_FILE_11'
#!/bin/sh
set -e
. /lib/functions.sh

uci set network.lan.ipaddr='192.168.8.1'
uci set network.lan.netmask='255.255.255.0'
uci set network.wan.proto='dhcp'
uci set system.@system[0].hostname='SFT1200-Lab'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'

disable_offload() {
    uci set "firewall.$1.flow_offloading=0"
    uci set "firewall.$1.flow_offloading_hw=0"
}
config_load firewall
config_foreach disable_offload defaults
uci set firewall.sft1200_lab='include'
uci set firewall.sft1200_lab.type='script'
uci set firewall.sft1200_lab.path='/usr/sbin/sft1200-lab-apply'
uci set firewall.sft1200_lab.reload='1'
uci commit network
uci commit system
uci commit firewall

# Configure the existing LAN access points with a device-local random password.
# It is generated on first boot, never embedded in the public GitHub repository.
if [ -s /etc/config/wireless ]; then
    mkdir -p /etc/sft1200-lab
    umask 077
    if [ ! -s /etc/sft1200-lab/wifi-key ]; then
        hexdump -n 10 -v -e '10/1 "%02x"' /dev/urandom > /etc/sft1200-lab/wifi-key
        printf '\n' >> /etc/sft1200-lab/wifi-key
    fi
    wifi_key="$(cat /etc/sft1200-lab/wifi-key)"
    echo "$wifi_key" | grep -Eq '^[0-9a-f]{20}$'
    setup_ap() {
        local mode network radio
        config_get mode "$1" mode
        config_get network "$1" network
        [ "$mode" = 'ap' ] && [ "$network" = 'lan' ] || return 0
        config_get radio "$1" device
        uci set "wireless.$radio.disabled=0"
        uci set "wireless.$1.disabled=0"
        uci set "wireless.$1.ssid=SFT1200-Lab"
        uci set "wireless.$1.encryption=psk2"
        uci set "wireless.$1.key=$wifi_key"
    }
    config_load wireless
    config_foreach setup_ap wifi-iface
    uci commit wireless
fi

/etc/init.d/sft1200-mac enable
/etc/init.d/sft1200-lab enable
/etc/init.d/ua2f enable
exit 0
SFT1200_FILE_11
chmod 0755 'files/etc/uci-defaults/99-z-sft1200-lab'

mkdir -p 'files/usr/lib/lua/luci/controller'
cat > 'files/usr/lib/lua/luci/controller/sft1200_lab.lua' <<'SFT1200_FILE_17'
module("luci.controller.sft1200_lab", package.seeall)

function index()
    entry({"admin", "status", "sft1200_lab"}, call("show_status"),
          "SFT1200 启动检查", 90).dependent = false
end

function show_status()
    local report = require("luci.sys").exec("/usr/sbin/sft1200-lab-status 2>&1")
    require("luci.template").render("sft1200_lab", { report = report })
end
SFT1200_FILE_17
chmod 0644 'files/usr/lib/lua/luci/controller/sft1200_lab.lua'

mkdir -p 'files/usr/lib/lua/luci/view'
cat > 'files/usr/lib/lua/luci/view/sft1200_lab.htm' <<'SFT1200_FILE_19'
<%+header%>
<h2>SFT1200 启动检查</h2>
<p>此页显示本次开机的服务、MAC 与规则状态。刷新页面可更新结果。</p>
<p>UA 改写仅适用于可解析的明文 HTTP。IPID 随机化跳过已分片数据包。这里的状态不能证明出口被识别为单台电脑。</p>
<pre style="white-space:pre-wrap;overflow-wrap:anywhere"><%=luci.util.pcdata(report)%></pre>
<%+footer%>
SFT1200_FILE_19
chmod 0644 'files/usr/lib/lua/luci/view/sft1200_lab.htm'

mkdir -p 'files/usr/sbin'
cat > 'files/usr/sbin/sft1200-lab-apply' <<'SFT1200_FILE_21'
#!/bin/sh
set -e
. /lib/functions/network.sh

mkdir -p /var/lock
exec 9>/var/lock/sft1200-lab.lock
flock -x -w 15 9 || {
    logger -t sft1200-lab 'ERROR: Timed out waiting to update packet rules.'
    exit 1
}
trap 'code=$?; [ "$code" -eq 0 ] || logger -t sft1200-lab "ERROR: Packet rule setup failed ($code)."' EXIT

wan4=''
wan6=''
network_flush_cache
network_get_device wan4 wan || true
network_get_device wan6 wan6 || true
[ -n "$wan6" ] || wan6="$wan4"
for device in "$wan4" "$wan6"; do
    case "$device" in
        *[!a-zA-Z0-9_.:@-]*)
            logger -t sft1200-lab 'ERROR: Unexpected WAN device name.'
            exit 1
            ;;
    esac
done

if [ ! -d /sys/module/rkp_ipid ]; then
    modprobe rkp-ipid
fi
test -d /sys/module/rkp_ipid

write_rules() {
    local family="$1" device="$2" chain="$3" file="$4"
    {
        printf '*mangle\n:%s - [0:0]\n-F %s\n' "$chain" "$chain"
        if [ -n "$device" ]; then
            if [ "$family" = '4' ]; then
                printf -- '-A %s -d 224.0.0.0/4 -j RETURN\n' "$chain"
                printf -- '-A %s -d 255.255.255.255/32 -j RETURN\n' "$chain"
                printf -- '-A %s -o %s -j TTL --ttl-set 128\n' "$chain" "$device"
                printf -- '-A %s -o %s -j MARK --set-xmark 0x30000000/0x30000000\n' "$chain" "$device"
            else
                printf -- '-A %s -d ff00::/8 -j RETURN\n' "$chain"
                printf -- '-A %s -o %s -j HL --hl-set 128\n' "$chain" "$device"
            fi
            printf -- '-A %s -o %s -p tcp --dport 22 -j RETURN\n' "$chain" "$device"
            printf -- '-A %s -o %s -p tcp --dport 443 -j RETURN\n' "$chain" "$device"
            printf -- '-A %s -o %s -p tcp -m conntrack --ctdir ORIGINAL -j NFQUEUE --queue-num 10010 --queue-bypass\n' "$chain" "$device"
        fi
        printf 'COMMIT\n'
    } > "$file"
}

write_rules 4 "$wan4" SFT_LAB4 /tmp/sft1200-lab4.rules
iptables-restore -w 5 --noflush < /tmp/sft1200-lab4.rules
if ! iptables -w 5 -t mangle -C POSTROUTING -j SFT_LAB4 2>/dev/null; then
    iptables -w 5 -t mangle -A POSTROUTING -j SFT_LAB4
fi

if [ -s /proc/net/if_inet6 ]; then
    write_rules 6 "$wan6" SFT_LAB6 /tmp/sft1200-lab6.rules
    ip6tables-restore -w 5 --noflush < /tmp/sft1200-lab6.rules
    if ! ip6tables -w 5 -t mangle -C POSTROUTING -j SFT_LAB6 2>/dev/null; then
        ip6tables -w 5 -t mangle -A POSTROUTING -j SFT_LAB6
    fi
fi

if [ -n "$wan4" ]; then
    logger -t sft1200-lab "Rules applied: WAN=$wan4; IPv6=${wan6:-none}; TTL/HL=128; IPv4 IPID=random."
else
    logger -t sft1200-lab 'Waiting for WAN; interface hotplug will apply the rules when it is available.'
fi
SFT1200_FILE_21
chmod 0755 'files/usr/sbin/sft1200-lab-apply'

mkdir -p 'files/usr/sbin'
cat > 'files/usr/sbin/sft1200-lab-status' <<'SFT1200_FILE_22'
#!/bin/sh
. /lib/functions/network.sh
printf 'SFT1200-Lab boot and packet-rule status\n\n'
if [ -s /etc/sft1200-lab/wifi-key ]; then
    printf 'Initial Wi-Fi SSID: SFT1200-Lab\nInitial Wi-Fi password: '
    cat /etc/sft1200-lab/wifi-key
    printf '(If you later changed Wi-Fi settings, use the updated password.)\n\n'
fi
printf 'UA2F process: '
if pidof ua2f >/dev/null; then echo RUNNING; else echo NOT_RUNNING; fi
printf 'IPID kernel module: '
if [ -d /sys/module/rkp_ipid ]; then echo LOADED; else echo NOT_LOADED; fi
printf 'Configured HTTP UA: '
uci -q get ua2f.main.custom_ua
printf '\nWAN MAC generated for this boot: '
cat /tmp/sft1200-wan.mac 2>/dev/null || echo UNAVAILABLE
wan=''
network_get_device wan wan || true
printf 'WAN device: %s\n' "${wan:-UNAVAILABLE}"
if [ -n "$wan" ] && [ -r "/sys/class/net/$wan/address" ]; then
    printf 'Current WAN device MAC: '
    cat "/sys/class/net/$wan/address"
fi
printf '\nOffload configuration (both should be 0):\n'
uci -q show firewall | grep -E '\.flow_offloading(_hw)?='
printf '\nIPv4 rules and packet counters:\n'
iptables -w 5 -t mangle -L SFT_LAB4 -n -v 2>&1
printf '\nIPv6 rules and packet counters (if IPv6 is active):\n'
ip6tables -w 5 -t mangle -L SFT_LAB6 -n -v 2>&1
printf '\nNFQUEUE listeners (queue 10010 should be present):\n'
cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null
printf '\nRecent startup messages:\n'
logread | grep -E 'sft1200-lab|rkp-ipid|UA2F' | tail -n 35
printf '\nThese checks show local state; verify packet changes separately.\n'
SFT1200_FILE_22
chmod 0755 'files/usr/sbin/sft1200-lab-status'

mkdir -p files/etc/rc.d files/etc/sft1200-lab
ln -sf ../init.d/sft1200-mac files/etc/rc.d/S18sft1200-mac
ln -sf ../init.d/sft1200-lab files/etc/rc.d/S98sft1200-lab
ln -sf ../init.d/ua2f files/etc/rc.d/S99ua2f

{
    echo 'SFT1200-Lab source revisions'
    echo 'UA2F b7009eea5b6548631ec3a555b1fe737a86c58b54 (5.2.0 plus SDK compatibility patches)'
    echo 'rkp-ipid 073e389703853aeaced6cf1299ca8fbe60635614 (fragment/writability/init-result patches)'
    cat .sft1200-lab/feed-revisions.txt
} > files/etc/sft1200-lab/build-sources.txt

make defconfig
for option in \
    CONFIG_TARGET_siflower_sf19a28_fullmask_SF19A28-GL-SFT1200 \
    CONFIG_PACKAGE_ua2f CONFIG_PACKAGE_kmod-rkp-ipid \
    CONFIG_PACKAGE_iptables-mod-ipopt CONFIG_PACKAGE_iptables-mod-nfqueue \
    CONFIG_PACKAGE_libatomic CONFIG_PACKAGE_flock CONFIG_PACKAGE_luci; do
    grep -qx "${option}=y" .config || {
        echo "ERROR: Required package/target disappeared after defconfig: $option" >&2
        exit 1
    }
done

if [ -n "${LOG_DIR:-}" ]; then
    mkdir -p "$LOG_DIR"
    cp files/etc/sft1200-lab/build-sources.txt "$LOG_DIR/build-sources.txt"
    git -C package/sft1200-lab-ua2f diff > "$LOG_DIR/ua2f-compatibility.patch"
    git -C package/sft1200-lab-ipid diff > "$LOG_DIR/rkp-ipid-compatibility.patch"
fi
echo 'Firmware customization is prepared. Build and hardware tests are still required.'
