#!/bin/sh
#
# required tools: cloud-localds, e2fsck, growpart, parted, resize2fs, mkfs.vfat
# provided by: cloud-image-utils, e2fsprogs, cloud-guest-utils, parted, e2fsprogs, dosfstools 
# 
set -e

img="$1"
media="$2"

dd if=${img} of=${media} bs=4M status=progress
growpart ${media} 1
parted -a optimal -s -- ${media} unit MiB rm 1 mkpart rootfs 16 -64 mkpart CIDATA fat32 -64 100%
e2fsck -f ${media}1
resize2fs ${media}1
mkfs.vfat -F 32 -n CIDATA ${media}2
tmp=$(mktemp -u)
[ ! -f ${tmp}.img ] || rm -f ${tmp}.img
cloud-localds -v ${tmp}.img user-data.yaml meta-data.yaml
[ ! -d ${tmp} ] || rm -rf ${tmp}
mkdir ${tmp}
mount ${tmp}.img ${tmp}
cidata=$(mktemp -u)
[ ! -d ${cidata} ] || rm -rf ${cidata}
mkdir ${cidata}
mount ${media}2 ${cidata}
cp ${tmp}/meta-data ${cidata}
cp ${tmp}/user-data ${cidata}
umount ${cidata} ${tmp}
rm -rf ${cidata} ${tmp} ${tmp}.img 
eject ${media}
