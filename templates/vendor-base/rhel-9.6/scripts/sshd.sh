#!/bin/sh -eux
sed -i 's/^#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
sed -i 's/^#GSSAPIAuthentication/GSSAPIAuthentication/' /etc/ssh/sshd_config
echo "UseDNS no" >> /etc/ssh/sshd_config
systemctl enable sshd
