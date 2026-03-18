#!/bin/sh -eux

echo "vm.nr_hugepages=1000" >> /etc/sysctl.conf
echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
echo "vm.swappiness=10" >> /etc/sysctl.conf
echo "kernel.dmesg_restrict=0" >> /etc/sysctl.conf

echo "*    hard   memlock           unlimited" >> /etc/security/limits.d/99-limits.conf
echo "*    soft   memlock           unlimited" >> /etc/security/limits.d/99-limits.conf
echo "*    hard   nofile             50000" >> /etc/security/limits.d/99-limits.conf
echo "*    soft   nofile             50000" >> /etc/security/limits.d/99-limits.conf
