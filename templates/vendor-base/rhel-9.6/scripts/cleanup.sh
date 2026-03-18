#!/bin/sh -eux
dnf -y clean all
rm -rf /var/cache/dnf /var/log/dnf* /var/log/yum*
rm -rf /tmp/* /var/tmp/*
truncate -s 0 /etc/machine-id
unset HISTFILE
history -c
