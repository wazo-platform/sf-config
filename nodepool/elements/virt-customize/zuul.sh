#!/bin/bash

set -x
set -e

# outside chroot
if [ $# == 1 ]; then
    dir="$1"
    cp /var/lib/nodepool/.ssh/zuul_rsa.pub "$dir/tmp/authorized_keys"
    cp $0 $dir/tmp/custom
    exec chroot "$dir" /tmp/custom
fi

# inside chroot

apt update -y

apt install -y openssh-server sudo cloud-init cloud-initramfs-growroot cloud-utils haveged

apt install -y apt-transport-https ca-certificates gnupg2 curl locales

curl -s https://download.docker.com/linux/debian/gpg > /tmp/docker.gpg
apt-key add /tmp/docker.gpg

COMMON="libldap2-dev libsasl2-dev libssl-dev linphone-nogtk python-dev lsof"

if [[ $(cat /etc/debian_version) =~ ^9\. ]]; then
    # debian 9
    PKGS="rsync iproute git virtualenv python-pip python3-pip traceroute libpq-dev python2.7 libpython2.7-dev python-pkg-resources python-yaml python3.7 libpython3.7-dev python3-pkg-resources sudo docker-ce docker-ce-cli containerd.io devscripts dirmngr build-essential $COMMON"
    debian_distro=stretch
else
    # debian 10
    PKGS="rsync iproute2 git python-pip python3-pip traceroute libpq-dev python2.7 libpython2.7-dev python-pkg-resources python-yaml python3.7 libpython3.7-dev python3-pkg-resources python-virtualenv python3-virtualenv sudo docker-ce docker-ce-cli containerd.io devscripts dirmngr build-essential $COMMON"
    debian_distro=buster
fi

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=amd64] https://download.docker.com/linux/debian $debian_distro stable
EOF

apt update -y

apt install -y $PKGS

apt upgrade -y

pip install tox

useradd -m zuul-worker -G docker -s /bin/bash
sed -i "s/zuul-worker:\!:/zuul-worker:*:/" /etc/shadow
mkdir /home/zuul-worker/.ssh
chmod 0700 /home/zuul-worker/.ssh
cp /tmp/authorized_keys /home/zuul-worker/.ssh/
chmod 0600 /home/zuul-worker/.ssh/authorized_keys
echo 'PATH="/home/zuul-worker/.local/bin:$PATH"' >> /home/zuul-worker/.profile
mkdir -p /home/zuul-worker/.local/bin
chown -R zuul-worker:zuul-worker /home/zuul-worker

echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> '/etc/sysctl.conf'
echo 'net.ipv6.conf.default.disable_ipv6 = 1' >> '/etc/sysctl.conf'

# sudo config without password
cat > /etc/sudoers.d/zuul <<EOF
Defaults    !requiretty
zuul-worker ALL=(ALL) NOPASSWD:ALL
zuul ALL=(ALL) NOPASSWD:ALL
EOF

chmod 0440 /etc/sudoers.d/zuul

# finalyze l10n
. /etc/default/locale
grep "^$LANG " /etc/locale.gen || grep "$LANG " /usr/share/i18n/SUPPORTED >> /etc/locale.gen
locale-gen

cat > /etc/network/interfaces <<EOF
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug enp1s0
iface enp1s0 inet dhcp

# The normal eth0
allow-hotplug eth0
iface eth0 inet dhcp

# Additional interfaces, just in case we're using
# multiple networks
allow-hotplug eth1
iface eth1 inet dhcp

allow-hotplug eth2
iface eth2 inet dhcp

# Set this one last, so that cloud-init or user can
# override defaults.
source /etc/network/interfaces.d/*
EOF

# Do not manage ssh keys in cloud-init as we inject our own key
cat > /etc/cloud/cloud.cfg.d/keep_ssh_keys.cfg <<EOF
ssh_deletekeys: False
EOF

# zuul.sh ends here
