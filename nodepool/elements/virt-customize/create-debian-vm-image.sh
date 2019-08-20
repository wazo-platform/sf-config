#!/bin/bash

set -e
set -x

fatal_error() {
    echo "$*" 1>&2
    exit 1
}

do_cleanup() {
    ret=$?
    trap - 0
    set +e

    rm -rf "$mdir/"dev/*
    umount "$mdir/"proc
    umount "$mdir"

    losetup -d $dev
    try=5
    while [ $try -gt 0 ] && ! kpartx -d "$disk"; do
	sleep 1
	try=$(($try - 1))
    done
    losetup -d $disk
    rmdir "$mdir"
}

check_binary() {
    type -p $1 || fatal_error "$1 is missing"
}

do_chroot() {
    local chdir="$1"
    shift
    PATH=/bin/:/sbin:$PATH LANG=C LC_ALL=C LC_CTYPE=C LANGUAGE=C chroot "$chdir" "$@"
}

if [ $(whoami) != root ]; then
    fatal_error "restart as root like sudo $0 $*"
fi

dir=$(cd $(dirname $0); pwd)

if [ $# != 1 -a $# != 2 ]; then
    fatal_error "Usage: $0 <distro name> [custom script]"
fi

distro=$1
img=$distro.raw
custom="$2"

# compress image in qcow2
comp_opt=-c
# no compression of the image in qcow2
#comp_opt=

export DEBIAN_FRONTEND=noninteractive

export DEBOOTSTRAP_DIR=$dir/debootstrap

if [ -r $dir/config ]; then
    . $dir/config
fi

FSTYPE=${FSTYPE:=ext2}

modprobe loop

for cmd in git du dd parted chroot kpartx qemu-img losetup mkfs.$FSTYPE rsync; do
    check_binary $cmd
done

if [ ! -d $DEBOOTSTRAP_DIR/.git ]; then
    rm -rf $DEBOOTSTRAP_DIR
    git clone https://salsa.debian.org/installer-team/debootstrap.git $DEBOOTSTRAP_DIR
else
    pushd $DEBOOTSTRAP_DIR
    git pull
    popd
fi

rm -rf $distro
mkdir -p $distro

$dir/debootstrap/debootstrap --include linux-image-amd64,grub-pc,bash --arch amd64 $distro $distro http://deb.debian.org/debian

# some scriptlets need /proc
mount --bind /proc $distro/proc

# run the custom script if any
if [ -x "$custom" ]; then
    set +e
    "$custom" $distro
    rc=$?
    set -e
fi

umount $distro/proc

if [ $rc != 0 ]; then
    exit $rc
fi

# cleanup distro
do_chroot $distro apt-get autoremove -y

rm -f $distro/var/cache/apt/archives/*.deb

# compute size of the directory
size=$(du -s -BM "$distro" | cut -f1 | sed -s 's/.$//')

# add 30% to be sure that metadata from the filesystem fit
size=$(($size * 130 / 100))

# Create the image file
rm -f $img
dd if=/dev/zero of=$img count=0 bs=1M seek=$size

disk=$(losetup --show --find "$img")
parted -s "$disk" mklabel msdos
parted -s "$disk" mkpart primary $FSTYPE 32k '100%'
parted "$disk" set 1 boot on

part=/dev/mapper/$(kpartx -avs $disk|cut -f3 -d' ')

try=5
while [ $try -gt 0 -a ! -b $part ]; do
    sleep 1
    try=$(($try - 1))
done

# create filesystem
rsync -aX --delete-before --exclude=shm /dev/ $distro/dev/
do_chroot "$distro" mkfs.$FSTYPE "$part"
mdir=$(mktemp -d -p .)
dev=$(losetup --show --find "$part")
mount "$dev" "$mdir"

trap do_cleanup 0

rsync -a "$distro/" "$mdir/"

# Let's create a copy of the current /dev
mkdir -p "${mdir}/"/dev/pts
rsync -a --delete-before --exclude=shm /dev/ ${mdir}/dev/

# Mount /proc
mkdir -p "${mdir}/proc"
mount -t proc none "$mdir/proc"

# Configure Grub
uuid=$(blkid -s UUID -o value "$part")
export grub_device_uuid=$uuid

# hack to have a correct part dev but don't know why
(cd $mdir/dev/; ln -sf $part $(basename $part))

# install grub
do_chroot "$mdir" grub-install --modules="ext2 xfs part_msdos" --no-floppy "$disk"

do_chroot "$mdir" grub-mkconfig -o /boot/grub/grub.cfg

# fix loopback lines
sed -i -e '/loop/d' < $mdir/boot/grub/grub.cfg

# debug grub.cfg
cp $mdir/boot/grub/grub.cfg ../$distro-grub.cfg || :

# add / to fstab
fs_options="errors=remount-ro,nobarrier,noatime,nodiratime"
echo "UUID=$uuid / $FSTYPE $fs_options 0 1" >> $mdir/etc/fstab

trap - 0
do_cleanup

qemu-img convert $comp_opt -O qcow2 "$img" "$distro".qcow2
rm -f $img

# create-debian-vm-image.sh ends here
