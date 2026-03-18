#!/bin/sh -eux

echo "remove linux-headers"
dpkg --list \
  | awk '{ print $2 }' \
  | grep 'linux-headers' || true \
  | xargs -r apt-get -y purge;

echo "remove specific Linux kernels, such as linux-image-3.11.0-15-generic but keeps the current kernel and does not touch the virtual packages"
dpkg --list \
    | awk '{ print $2 }' \
    | grep 'linux-image-.*-generic' || true \
    | grep -v "$(uname -r)" || true \
    | xargs -r apt-get -y purge;

echo "remove old kernel modules packages"
dpkg --list \
    | awk '{ print $2 }' \
    | grep 'linux-modules-.*-generic' || true \
    | grep -v "$(uname -r)" || true \
    | xargs -r apt-get -y purge;

echo "remove linux-source package"
dpkg --list \
    | awk '{ print $2 }' \
    | grep linux-source || true \
    | xargs -r apt-get -y purge;

# 23.10+ gives dependency errors for systemd-dev — purge one-by-one
echo "remove all development packages"
dpkg --list \
    | awk '{ print $2 }' \
    | grep -- '-dev\(:[a-z0-9]\+\)\?$' || true \
    | xargs -r -I % apt-get -y purge % || true;

echo "remove docs packages"
dpkg --list \
    | awk '{ print $2 }' \
    | grep -- '-doc$' || true \
    | xargs -r apt-get -y purge;

echo "remove X11 libraries"
apt-get -y purge libx11-data xauth libxmuu1 libxcb1 libx11-6 libxext6 || true;

echo "remove obsolete networking packages"
apt-get -y purge ppp pppconfig pppoeconf || true;

echo "remove packages we don't need"
apt-get -y purge popularity-contest command-not-found friendly-recovery bash-completion laptop-detect motd-news-config usbutils grub-legacy-ec2 || true

# 22.04+ don't have these
apt-get -y purge fonts-ubuntu-font-family-console || true;
apt-get -y purge popularity-contest installation-report || true;
apt-get -y purge fonts-ubuntu-console || true;
# 19.10+ don't have this package
apt-get -y purge command-not-found-data || true;

# Exclude the files we don't need w/o uninstalling linux-firmware
echo "Setup dpkg excludes for linux-firmware"
cat <<_EOF_ | cat >> /etc/dpkg/dpkg.cfg.d/excludes
#BENTO-BEGIN
path-exclude=/lib/firmware/*
path-exclude=/usr/share/doc/linux-firmware/*
#BENTO-END
_EOF_

echo "delete the massive firmware files"
rm -rf /lib/firmware/*
rm -rf /usr/share/doc/linux-firmware/*

echo "autoremoving packages and cleaning apt data"
apt-get -y autoremove;
apt-get -y clean;

echo "remove /usr/share/doc/"
rm -rf /usr/share/doc/*

echo "remove /var/cache"
find /var/cache -type f -exec rm -rf {} \;

echo "truncate any logs that have built up during the install"
find /var/log -type f -exec truncate --size=0 {} \;

echo "blank netplan machine-id (DUID) so machines get unique ID generated on boot"
truncate -s 0 /etc/machine-id
if test -f /var/lib/dbus/machine-id; then
  truncate -s 0 /var/lib/dbus/machine-id  # if not symlinked to "/etc/machine-id"
fi

echo "remove the contents of /tmp and /var/tmp"
rm -rf /tmp/* /var/tmp/*

echo "force a new random seed to be generated"
rm -f /var/lib/systemd/random-seed

echo "clear the history so our install isn't there"
rm -f /root/.wget-hsts
export HISTSIZE=0
