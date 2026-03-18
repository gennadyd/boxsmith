#!/bin/sh -eux

# Fix any interrupted dpkg state (can happen after UEFI autoinstall)
dpkg --configure -a || true
apt-get -f install -y || true

ubuntu_version="`lsb_release -r | awk '{print $2}'`"
major_version="`echo $ubuntu_version | awk -F. '{print $1}'`"

sed -i 's/^[ \t]*\(deb[^\n]+\)$/#\1/g' /etc/apt/sources.list
sed -i 's/\(Defaults.*secure_path.*\)/#\1/g' /etc/sudoers

apt-get -y update

apt install -y wget lsof vim git git-lfs

apt install -y \
    python3 \
    python3-pip \
    python3-dev \
    python3-tk \
    python3-setuptools

#This is a WA for pip install blocking on externally-managed error
if [ "$major_version" -ge "24" ]; then
   mv /usr/lib/python3.12/EXTERNALLY-MANAGED /usr/lib/python3.12/EXTERNALLY-MANAGED.old
fi

if [ "$major_version" -ge "22" ]; then

   apt install -y nfs-common
   apt remove  -y needrestart
fi

apt install -y unattended-upgrades
unattended-upgrade -d

if [ "$major_version" -ge "24" ]; then
   echo "Skipping fw stop"
else
   systemctl stop ufw.service
   systemctl disable ufw.service
fi

rm -rf /etc/dpkg/dpkg.cfg.d/excludes

# disable quiet for kernel boot
sed -i 's/quiet//g' /etc/default/grub
sed -i 's/splash//g' /etc/default/grub

update-grub

# this is a wa to fix bug with systemd-resolved.service loosing DNS resolving, see here:
# https://github.com/systemd/systemd/issues/10298
if [ "$major_version" -eq "18" ]; then
   ln -snf /run/systemd/resolve/resolv.conf /etc/resolv.conf
# habanalabs comes built in ubuntu 21, need to blacklist
elif [ "$major_version" -eq "21" ]; then
   sudo grep -qxF 'blacklist habanalabs' /etc/modprobe.d/blacklist-habanalabs.conf || sudo echo -e 'blacklist habanalabs\nblacklist habanalabs_en' | sudo tee -a /etc/modprobe.d/blacklist-habanalabs.conf
fi