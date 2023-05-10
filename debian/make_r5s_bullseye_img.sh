#!/bin/sh

set -e

# script exit codes:
#   1: missing utility
#   2: download failure
#   3: image mount failure
#   4: missing file
#   5: invalid file hash
#   9: superuser required

main() {
    # file media is sized with the number between 'mmc_' and '.img'
    #   use 'm' for 1024^2 and 'g' for 1024^3
    local deb_dist='bullseye'
    local board='r5s'
    local media="mmc_2g_${board}_${deb_dist}.img" # or block device '/dev/sdX'
    local hostname="nanopi-${board}"
    local acct_uid='debian'
    local acct_pass='debian'
    local disable_ipv6=true
    local extra_pkgs='cloud-guest-utils, cloud-init, curl, ifupdown2, gpg, gpg-agent, pciutils, python3-cffi-backend, sudo, u-boot-tools, uuid, unzip, wget, xz-utils, zip, zstd'

    is_param 'clean' $@ && rm -rf cache.${board}.${deb_dist}* && rm mmc_2g_${board}_${deb_dist}.img* && exit 0

    if [ -f "$media" ]; then
        read -p "file $media exists, overwrite? <y/N> " yn
        if ! [ "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo 'exiting...'
            exit 0
        fi
    fi

    # no compression if disabled or block media
    local compress=$(is_param 'nocomp' $@ || [ -b "$media" ] && echo false || echo true)
    compress=false

    if $compress && [ -f "$media.xz" ]; then
        read -p "file $media.xz exists, overwrite? <y/N> " yn
        if ! [ "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo 'exiting...'
            exit 0
        fi
    fi

    check_installed 'debootstrap' 'u-boot-tools' 'wget' 'xz-utils'

    print_hdr "downloading files"
    local cache="cache.$board.$deb_dist"
    # linux firmware
    local lfw=$(download "$cache" 'https://mirrors.edge.kernel.org/pub/linux/kernel/firmware/linux-firmware-20230210.tar.xz')
    local lfwsha='6e3d9e8d52cffc4ec0dbe8533a8445328e0524a20f159a5b61c2706f983ce38a'
    # device tree & uboot
    local dtb=$(download "$cache" "https://github.com/inindev/nanopi-r5/releases/download/v12-rc3/rk3568-nanopi-${board}.dtb")
#    local dtb='../dtb/rk3568-nanopi-r5s.dtb'
    local uboot_spl=$(download "$cache" 'https://github.com/inindev/nanopi-r5/releases/download/v12-rc3/idbloader.img')
#    local uboot_spl='../uboot/idbloader.img'
    local uboot_itb=$(download "$cache" 'https://github.com/inindev/nanopi-r5/releases/download/v12-rc3/u-boot.itb')
#    local uboot_itb='../uboot/u-boot.itb'

    if [ "$lfwsha" != $(sha256sum "$lfw" | cut -c1-64) ]; then
        echo "invalid hash for linux firmware: $lfw"
        exit 5
    fi

    if [ ! -f "$dtb" ]; then
        echo "unable to fetch device tree binary: $dtb"
        exit 4
    fi

    if [ ! -f "$uboot_spl" ]; then
        echo "unable to fetch uboot binary: $uboot_spl"
        exit 4
    fi

    if [ ! -f "$uboot_itb" ]; then
        echo "unable to fetch uboot binary: $uboot_itb"
        exit 4
    fi

    if [ ! -b "$media" ]; then
        print_hdr "creating image file"
        make_image_file "$media"
    fi

    print_hdr "partitioning media"
    partition_media "$media"

    print_hdr "formatting media"
    format_media "$media"

    mount_media "$media"

    # do not write the cache to the image
    mkdir -p "$cache/var/cache" "$cache/var/lib/apt/lists"
    mkdir -p "$mountpt/var/cache" "$mountpt/var/lib/apt/lists"
    mount -o bind "$cache/var/cache" "$mountpt/var/cache"
    mount -o bind "$cache/var/lib/apt/lists" "$mountpt/var/lib/apt/lists"

    # install debian linux from official repo packages
    print_hdr "installing root filesystem from debian.org"
    mkdir "$mountpt/etc"
    echo 'link_in_boot = 1' > "$mountpt/etc/kernel-img.conf"
    local pkgs="linux-image-arm64, dbus, openssh-server, systemd-timesyncd"
    pkgs="$pkgs, $extra_pkgs"
    debootstrap --arch arm64 --include "$pkgs" "$deb_dist" "$mountpt" 'https://deb.debian.org/debian/'

    dist=bookworm
    print_hdr "install linux-image from ${dist}"
    echo "$(file_apt_sources ${dist})\n" > "$mountpt/etc/apt/sources.list.d/${dist}.list"
    chroot "$mountpt" /usr/bin/apt -y update
    chroot "$mountpt" /usr/bin/apt -y install -t ${dist} --no-install-recommends linux-image-arm64
    rm -f "$mountpt/etc/apt/sources.list.d/${dist}.list"

    umount "$mountpt/var/cache"
    umount "$mountpt/var/lib/apt/lists"

    # motd
    [ -f "../etc/motd-${board}" ] && cp -f "../etc/motd-${board}" "$mountpt/etc/motd"

    # rename interfaces
    echo "[Match]\nPath=platform-fe2a0000.ethernet\n[Link]\nName=wan" > "$mountpt/etc/systemd/network/10-name-wan.link"
    echo "[Match]\nPath=platform-3c0000000.pcie-pci-0000:01:00.0\n[Link]\nName=lan1" > "$mountpt/etc/systemd/network/10-name-lan1.link"
    echo "[Match]\nPath=platform-3c0400000.pcie-pci-0001:01:00.0\n[Link]\nName=lan2" > "$mountpt/etc/systemd/network/10-name-lan2.link"

    # copy script to generate mac address
    cp -f gen_mac_addr.sh "$mountpt/usr/sbin/gen_mac_addr.sh"

    # populate interfaces
    echo "$(script_etc_interfaces)" >> "$mountpt/etc/network/interfaces"

    # populate apt sources list
    echo "$(file_apt_sources ${deb_dist})\n" > "$mountpt/etc/apt/sources.list"

    # locales to generate
    echo 'en_US.UTF-8 UTF-8' >> "$mountpt/etc/locale.gen"

    # cloud-init: use NoCloud as DataSource
    echo 'datasource_list: [ NoCloud, None ]' > "$mountpt/etc/cloud/cloud.cfg.d/10-nocloud-only.cfg"
    echo 'network: {config: disabled}' > "$mountpt/etc/cloud/cloud.cfg.d/20-disable-network-config.cfg"

    # setup /boot
    echo "$(script_boot_txt $disable_ipv6)\n" > "$mountpt/boot/boot.txt"
    mkimage -A arm64 -O linux -T script -C none -n 'u-boot boot script' -d "$mountpt/boot/boot.txt" "$mountpt/boot/boot.scr"
    echo "$(script_mkscr_sh)\n" > "$mountpt/boot/mkscr.sh"
    chmod 754 "$mountpt/boot/mkscr.sh"
    install -m 644 "$dtb" "$mountpt/boot/dtb"

    print_hdr "installing firmware"
    mkdir -p "$mountpt/lib/firmware"
    local lfwn=$(basename "$lfw")
    tar -C "$mountpt/lib/firmware" --strip-components=1 --wildcards -xavf "$lfw" "${lfwn%%.*}/rockchip" "${lfwn%%.*}/rtl_nic"

    #print_hdr "remove root password"
    #chroot "$mountpt" /usr/bin/passwd -d root

    # when compressing, reduce entropy in free space to enhance compression
    if $compress; then
        print_hdr "removing entropy before compression"
        cat /dev/zero > "$mountpt/tmp/zero.bin" 2> /dev/null || true
        sync
        rm -f "$mountpt/tmp/zero.bin"
    fi

    umount "$mountpt"
    rm -rf "$mountpt"

    print_hdr "installing u-boot"
    dd bs=4K seek=8 if="$uboot_spl" of="$media" conv=notrunc
    dd bs=4K seek=2048 if="$uboot_itb" of="$media" conv=notrunc,fsync

    if $compress; then
        print_hdr "compressing image file"
        xz -z8v "$media"
        echo "\n${cya}compressed image is now ready${rst}"
        echo "\n${cya}copy image to target media:${rst}"
        echo "  ${cya}sudo sh -c 'xzcat $media.xz > /dev/sdX && sync'${rst}"
    elif [ -b "$media" ]; then
        echo "\n${cya}media is now ready${rst}"
    else
        echo "\n${cya}image is now ready${rst}"
        echo "\n${cya}copy image to media:${rst}"
        echo "  ${cya}sudo sh -c 'cat $media > /dev/sdX && sync'${rst}"
    fi
    echo
}

make_image_file() {
    local filename="$1"
    rm -f "$filename"*
    local size="$(echo "$filename" | sed -rn 's/.*mmc_([[:digit:]]+[m|g])_.*\.img$/\1/p')"
    local bytes="$(echo "$size" | sed -e 's/g/ << 30/' -e 's/m/ << 20/')"
    dd bs=64K count=$(($bytes >> 16)) if=/dev/zero of="$filename" status=progress
}

partition_media() {
    local media="$1"

    # partition with gpt
    parted -a optimal -s -- "$media" \
	    unit MiB \
	    mklabel gpt \
	    mkpart rootfs ext4 16 100%
    sync
}

format_media() {
    local media="$1"

    # create ext4 filesystem
    if [ -b "$media" ]; then
        local part1="/dev/$(lsblk -no kname "$media" | grep '.*p1$')"
        mkfs.ext4 "$part1" && sync
    else
        local lodev="$(losetup -f)"
        losetup -P "$lodev" "$media" && sync
        mkfs.ext4 "${lodev}p1" && sync
        losetup -d "$lodev" && sync
    fi
}

mount_media() {
    local media="$1"

    if [ -d "$mountpt" ]; then
        echo "cleaning up mount points..."
        mountpoint -q "$mountpt/var/cache" && umount "$mountpt/var/cache"
        mountpoint -q "$mountpt/var/lib/apt/lists" && umount "$mountpt/var/lib/apt/lists"
        mountpoint -q "$mountpt" && umount "$mountpt"
    else
        mkdir -p "$mountpt"
    fi

    if [ -b "$media" ]; then
        local part1="/dev/$(lsblk -no kname "$media" | grep '.*p1$')"
        mount -n "$part1" "$mountpt"
    elif [ -f "$media" ]; then
        mount -n -o loop,offset=16M "$media" "$mountpt"
    else
        echo "file not found: $media"
        exit 4
    fi

    if [ ! -d "$mountpt/lost+found" ]; then
        echo 'failed to mount the image file'
        exit 3
    fi

    echo "media ${cya}$media${rst} successfully mounted on ${cya}$mountpt${rst}"
}

check_mount_only() {
    local img
    local flag=false
    for item in "$@"; do
        case "$item" in
            mount) flag=true ;;
            *.img) img=$item ;;
            *.img.xz) img=$item ;;
        esac
    done
    ! $flag && return

    if [ ! -f "$img" ]; then
        if [ -z "$img" ]; then
            echo "no image file specified"
        else
            echo "file not found: ${red}$img${rst}"
        fi
        exit 3
    fi

    if [ "$img" = *.xz ]; then
        tmp=$(basename "$img" .xz)
        if [ -f "$tmp" ]; then
            echo "compressed file ${bld}$img${rst} was specified but uncompressed file ${bld}$tmp${rst} exists..."
            echo -n "mount ${bld}$tmp${rst}"
            read -p " instead? <Y/n> " yn
            if ! [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
                echo 'exiting...'
                exit 0
            fi
            img=$tmp
        else
            echo -n "compressed file ${bld}$img${rst} was specified"
            read -p ', decompress to mount? <Y/n>' yn
            if ! [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
                echo 'exiting...'
                exit 0
            fi
            xz -dk "$img"
            img=$(basename "$img" .xz)
        fi
    fi

    echo "mounting file ${yel}$img${rst}..."
    mount_media "$img"
    trap - EXIT INT QUIT ABRT TERM
    echo "media mounted, use ${grn}sudo umount $mountpt${rst} to unmount"

    exit 0
}

# download / return file from cache
download() {
    local cache="$1"
    local url="$2"

    [ -d "$cache" ] || mkdir -p "$cache"

    local filename=$(basename "$url")
    local filepath="$cache/$filename"
    [ -f "$filepath" ] || wget "$url" -P "$cache"
    [ -f "$filepath" ] || exit 2

    echo "$filepath"
}

# check if utility program is installed
check_installed() {
    local todo
    for item in "$@"; do
        dpkg -l "$item" 2>/dev/null | grep -q "ii  $item" || todo="$todo $item"
    done

    if [ ! -z "$todo" ]; then
        echo "this script requires the following packages:${bld}${yel}$todo${rst}"
        echo "   run: ${bld}${grn}apt update && apt -y install$todo${rst}\n"
        exit 1
    fi
}

file_apt_sources() {
    local deb_dist="$1"

    cat <<-EOF
	# For information about how to configure apt package sources,
	# see the sources.list(5) manual.

	deb http://deb.debian.org/debian $deb_dist main contrib non-free
	#deb-src http://deb.debian.org/debian $deb_dist main contrib non-free

	deb http://deb.debian.org/debian-security $deb_dist-security main contrib non-free
	#deb-src http://deb.debian.org/debian-security $deb_dist-security main contrib non-free

	deb http://deb.debian.org/debian $deb_dist-updates main contrib non-free
	#deb-src http://deb.debian.org/debian $deb_dist-updates main contrib non-free
	EOF
}

script_etc_interfaces() {
    cat <<-EOF

	auto lo
	iface lo inet loopback

	auto wan
	iface wan inet dhcp
	EOF
}

script_boot_txt() {
    local no_ipv6="$($1 && echo ' ipv6.disable=1')"

    cat <<-EOF
	# after modifying, run ./mkscr.sh

	part uuid \${devtype} \${devnum}:\${distro_bootpart} uuid
	setenv bootargs console=ttyS2,1500000 root=PARTUUID=\${uuid} rw rootwait$no_ipv6 earlycon=uart8250,mmio32,0xfe660000

	if load \${devtype} \${devnum}:\${distro_bootpart} \${kernel_addr_r} /boot/vmlinuz; then
	    if load \${devtype} \${devnum}:\${distro_bootpart} \${fdt_addr_r} /boot/dtb; then
	        fdt addr \${fdt_addr_r}
	        fdt resize
	        if load \${devtype} \${devnum}:\${distro_bootpart} \${ramdisk_addr_r} /boot/initrd.img; then
	            booti \${kernel_addr_r} \${ramdisk_addr_r}:\${filesize} \${fdt_addr_r};
	        else
	            booti \${kernel_addr_r} - \${fdt_addr_r};
	        fi;
	    fi;
	fi
	EOF
}

script_mkscr_sh() {
    cat <<-EOF
	#!/bin/sh

	if [ ! -x /usr/bin/mkimage ]; then
	    echo 'mkimage not found, please install uboot tools:'
	    echo '  sudo apt -y install u-boot-tools'
	    exit 1
	fi

	mkimage -A arm64 -O linux -T script -C none -n 'u-boot boot script' -d boot.txt boot.scr
	EOF
}

is_param() {
    local match
    for item in $@; do
        if [ -z $match ]; then
            match=$item
        elif [ $match = $item ]; then
            return
        fi
    done
    false
}

print_hdr() {
    local msg=$1
    echo "\n${h1}$msg...${rst}"
}

# ensure inner mount points get cleaned up
on_exit() {
    if mountpoint -q "$mountpt"; then
        print_hdr "cleaning up mount points"
        mountpoint -q "$mountpt/var/cache" && umount "$mountpt/var/cache"
        mountpoint -q "$mountpt/var/lib/apt/lists" && umount "$mountpt/var/lib/apt/lists"

        read -p "$mountpt is still mounted, unmount? <Y/n> " yn
        if [ -z "$yn" -o "$yn" = 'y' -o "$yn" = 'Y' -o "$yn" = 'yes' -o "$yn" = 'Yes' ]; then
            echo "unmounting $mountpt"
            umount "$mountpt"
            sync
            rm -rf "$mountpt"
        fi
    fi
}

mountpt='rootfs'
trap on_exit EXIT INT QUIT ABRT TERM

rst='\033[m'
bld='\033[1m'
red='\033[31m'
grn='\033[32m'
yel='\033[33m'
blu='\033[34m'
mag='\033[35m'
cya='\033[36m'
h1="${blu}==>${rst} ${bld}"

if [ 0 -ne $(id -u) ]; then
    echo 'this script must be run as root'
    echo "   run: ${bld}${grn}sudo sh make_debian_img.sh${rst}\n"
    exit 9
fi

cd "$(dirname "$(readlink -f "$0")")"
check_mount_only $@
main $@
