#!/bin/sh

set -e

src="$1"
dst="$2"
meta_data="$3"
user_data="$4"

usage() {
	print "Usage: $0 src_img dst_img meta-data user-data"
}

if [ ! -f "${user_data}" -o ! -f "${meta_data}" ]; then
	usage
	exit 255
fi

# dump image to media
cp "${src}" "${dst}"

lodev="$(losetup -f)"
losetup -P "${lodev}" "${dst}"
cidata_dev=$(blkid --label CIDATA)
if [ "${cidata_dev}" = "" ]; then
	losetup -d "${lodev}"
	rm "${dst}"
	print "can't find partition named CIDATA"
	exit 255
fi

cidata_mnt=$(mktemp -u)
[ ! -d "${cidata_mnt}" ] || rm -rf "${cidata_mnt}"
mkdir "${cidata_mnt}"
mount "${cidata_dev}" "${cidata_mnt}"
cp "${user_data}" "${cidata_mnt}"/user-data
cp "${meta_data}" "${cidata_mnt}"/meta-data
sync
umount "${cidata_mnt}"
rm -rf "${cidata_mnt}"
losetup -d "${lodev}"

