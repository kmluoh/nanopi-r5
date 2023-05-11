#!/bin/sh
#
# required tools: cloud-localds, e2fsck, growpart, parted, resize2fs, mkfs.vfat, uuid
# provided by: cloud-image-utils, e2fsprogs, cloud-guest-utils, parted, e2fsprogs, dosfstools, uuid
# 
set -e

img="$1"
media="$2"
meta_data_yml="$3"

# dump image to media
dd if=${img} of=${media} bs=4M status=progress

# resize partition table and root (1st) partiton
growpart ${media} 1

# create (2nd) partition on media for cloud-init NoCloud data source
parted -a optimal -s -- ${media} unit MiB rm 1 mkpart rootfs 16 -64 mkpart CIDATA fat32 -64 100%

# resize root (1st) filesystem
e2fsck -f ${media}1
resize2fs ${media}1

# create filesystem on 2nd partition of media for cloud-init NoCloud data source
mkfs.vfat -F 32 -n CIDATA ${media}2

# generate a meta-data yaml file if not provided
if [ ! -f "${meta_data_yml}" ]; then
	mdtmp=$(mktemp -u)
	myuuid=$(uuid -v 1)
	echo "instance-id: ${myuuid}" > "${mdtmp}"
	meta_data_yml="${mdtmp}"
fi

# generate an iso image with user-data and meta-data
tmp=$(mktemp -u)
[ ! -f ${tmp}.img ] || rm -f ${tmp}.img
cloud-localds -v ${tmp}.img user-data.yaml ${meta_data_yml}
[ ! -f "${mdtmp}" ] || rm -f "${mdtmp}"

# mount iso image with user-data and meta-data
[ ! -d ${tmp} ] || rm -rf ${tmp}
mkdir ${tmp}
mount ${tmp}.img ${tmp}

# mount 2nd partition of media
cidata=$(mktemp -u)
[ ! -d ${cidata} ] || rm -rf ${cidata}
mkdir ${cidata}
mount ${media}2 ${cidata}

# copy user-data and meta-data from iso image to 2nd partition of media
cp ${tmp}/meta-data ${cidata}
cp ${tmp}/user-data ${cidata}

# cleanup
umount ${cidata} ${tmp}
rm -rf ${cidata} ${tmp} ${tmp}.img
eject ${media}
