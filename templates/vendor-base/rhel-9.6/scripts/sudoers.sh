#!/bin/sh -eux
echo 'Defaults:vagrant !requiretty' > /etc/sudoers.d/vagrant
echo '%vagrant ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/vagrant
chmod 440 /etc/sudoers.d/vagrant
