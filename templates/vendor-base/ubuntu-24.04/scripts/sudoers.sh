#!/bin/sh -eux

# shellcheck disable=SC2024,SC2260
# sudo-rs (Rust reimplementation of sudo, used in Ubuntu 24.10+) does not support exempt_group
if ! sudo --version > /dev/stdout 2>&1 | grep -q sudo-rs; then
  sed -i -e '/Defaults\s\+env_reset/a Defaults\texempt_group=sudo' /etc/sudoers;
fi

# Set up password-less sudo for the vagrant user
echo 'vagrant ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/99_vagrant;
chmod 440 /etc/sudoers.d/99_vagrant;