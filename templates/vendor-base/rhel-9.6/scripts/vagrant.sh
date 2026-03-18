#!/bin/sh -eux
HOME_DIR="${HOME_DIR:-/home/vagrant}"

# Use the Vagrant RSA insecure public key directly (no network access needed).
# vagrant-libvirt uses ~/.vagrant.d/insecure_private_key (RSA).
# The ED25519 key from Vagrant's main/master branch is NOT compatible.
mkdir -p "$HOME_DIR/.ssh"
cat > "$HOME_DIR/.ssh/authorized_keys" << 'PUBKEY'
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key
PUBKEY
chown -R vagrant "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
echo "Vagrant RSA insecure public key installed"
