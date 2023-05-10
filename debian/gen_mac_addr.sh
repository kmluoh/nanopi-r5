#!/bin/bash
set -e

gen_mac() {
	local oui=$1
	local base=$2
	local idx=$3
	local linkfile=$4
	vid=$(printf "%012x" $((0x${base} + $idx & 0x000000ffffff)))
	mac=$(printf "%012x" $((0x${oui} | 0x${vid})) | sed 's/../&:/g;s/:$//')
	echo "MACAddress=${mac}" >> $linkfile
}

# do nothing if INSTANCE_ID is not set
[ "${INSTANCE_ID}" != "" ] || exit 0


# take base mac address from INSTANCE_ID if it is a version 1 UUID
base_mac=$(uuid -d ${INSTANCE_ID} | awk '/node:/{print $2}' | sed 's/://g')

# do nothing if INSTANCE_ID if not version 1 UUID
[ "${base_mac}" != "" ] || exit 0

oui=$(printf "%012x" $((0x${base_mac} & 0xfeffff000000)))
base=$(printf "%012x" $((0x${base_mac} & 0x000000ffffff)))

idx=0
for f in $(ls /etc/systemd/network/*.link); do
	gen_mac ${oui} ${base} ${idx} $f
	source <(grep = $f)
	up=$(cat /sys/class/net/${Name}/operstate)
	[ "${up}" != "up" ] || ip link set dev ${Name} down
	ip link set dev ${Name} address ${MACAddress}
	[ "${up}" != "up" ] || ip link set dev ${Name} up
	idx=$((${idx} + 1))
done
