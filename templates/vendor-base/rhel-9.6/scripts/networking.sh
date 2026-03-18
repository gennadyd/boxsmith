#!/bin/sh -eux
# Disable predictable network interface names — use eth0
sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 net.ifnames=0 biosdevname=0"/g' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg || grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg || true

# Rename existing NM connection to eth0
CONN=$(nmcli -t -f NAME conn show | head -1)
if [ -n "$CONN" ] && [ "$CONN" != "eth0" ]; then
    nmcli connection modify "$CONN" connection.id eth0 || true
fi
