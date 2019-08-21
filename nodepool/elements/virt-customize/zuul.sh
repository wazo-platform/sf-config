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

apt install -y openssh-server sudo cloud-init cloud-initramfs-growroot cloud-utils

apt install -y apt-transport-https ca-certificates gnupg2 curl locales

curl -s https://download.docker.com/linux/debian/gpg > /tmp/docker.gpg
apt-key add /tmp/docker.gpg

if [[ $(cat /etc/debian_version) =~ ^9\. ]]; then
    # debian 9
    PKGS="rsync iproute git virtualenv python-pip python3-pip traceroute libpq-dev python2.7 libpython2.7-dev python-pkg-resources python-yaml python3.5 libpython3.5-dev python3-pkg-resources sudo docker-ce docker-ce-cli containerd.io devscripts dirmngr build-essential"
    debian_distro=stretch
else
    # debian 10
    PKGS="rsync iproute2 git python-pip python3-pip traceroute libpq-dev python2.7 libpython2.7-dev python-pkg-resources python3.7 libpython3.7-dev python3-pkg-resources python-virtualenv python3-virtualenv sudo docker-ce docker-ce-cli containerd.io devscripts dirmngr build-essential"
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

cat > /etc/ssh/sshd_config <<EOF
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
KexAlgorithms curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com
SyslogFacility AUTHPRIV
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
GSSAPIAuthentication no
GSSAPICleanupCredentials no
UsePAM yes
X11Forwarding no
UseDNS no
AcceptEnv LANG LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY LC_MESSAGES
AcceptEnv LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT
AcceptEnv LC_IDENTIFICATION LC_ALL LANGUAGE
AcceptEnv XMODIFIERS
Subsystem sftp  /usr/libexec/openssh/sftp-serve
EOF

chmod 0600 /etc/ssh/sshd_config

echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> '/etc/sysctl.conf'
echo 'net.ipv6.conf.default.disable_ipv6 = 1' >> '/etc/sysctl.conf'

cat > /etc/sudoers.d/zuul <<EOF
Defaults    !requiretty
zuul-worker ALL=(ALL) NOPASSWD:ALL
zuul ALL=(ALL) NOPASSWD:ALL
EOF

chmod 0440 /etc/sudoers.d/zuul

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
sed -i -e '/ - ssh$/d' /etc/cloud/cloud.cfg

# zuul.sh ends here
