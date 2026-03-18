#!/bin/sh -eu
# Configures DNS and injects authorized SSH keys.
# All values come from environment variables — see config.example.env

if [ -f /etc/os-release ]; then
    . /etc/os-release && export OS_NAME="${ID}"
else
    echo "/etc/os-release not found"
    exit 1
fi

: "${DNS_SERVERS:?Set DNS_SERVERS}"
: "${DNS_SEARCH_DOMAINS:?Set DNS_SEARCH_DOMAINS}"

if [ "${OS_NAME}" = "sles" ]; then
    echo "Define the desired DNS configuration"
    DNS_OPTIONS="edns0 trust-ad"

    CONFIG_FILE="/etc/sysconfig/network/config"
    sed -i "s/^NETCONFIG_DNS_STATIC_SERVERS=.*/NETCONFIG_DNS_STATIC_SERVERS=\"$DNS_SERVERS\"/" "$CONFIG_FILE"
    sed -i "s/^NETCONFIG_DNS_STATIC_SEARCHLIST=.*/NETCONFIG_DNS_STATIC_SEARCHLIST=\"$DNS_SEARCH_DOMAINS\"/" "$CONFIG_FILE"
    sed -i "s/^NETCONFIG_DNS_FORWARDER=.*/NETCONFIG_DNS_FORWARDER=\"yes\"/" "$CONFIG_FILE"

    if ! grep -q "NETCONFIG_DNS_RESOLVER_OPTIONS" "$CONFIG_FILE"; then
        echo "NETCONFIG_DNS_RESOLVER_OPTIONS=\"$DNS_OPTIONS\"" >> "$CONFIG_FILE"
    else
        sed -i "s/^NETCONFIG_DNS_RESOLVER_OPTIONS=.*/NETCONFIG_DNS_RESOLVER_OPTIONS=\"$DNS_OPTIONS\"/" "$CONFIG_FILE"
    fi

    if command -v /sbin/netconfig >/dev/null 2>&1; then
        /sbin/netconfig update -f
    elif command -v /usr/sbin/wicked >/dev/null 2>&1; then
        wicked --debug all ifup all
    else
        echo "Error: Neither netconfig nor wicked is available."
        exit 1
    fi
else
    for ns in ${DNS_SERVERS}; do
        echo "nameserver ${ns}" >> /etc/resolv.conf
    done
    echo "search ${DNS_SEARCH_DOMAINS}" >> /etc/resolv.conf
fi

# Inject additional authorized SSH keys if provided
mkdir -p ~root/.ssh/
touch ~root/.ssh/authorized_keys
chmod 600 ~root/.ssh/authorized_keys

if [ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ] && [ -f "${SSH_AUTHORIZED_KEYS_FILE}" ]; then
    cat "${SSH_AUTHORIZED_KEYS_FILE}" >> ~root/.ssh/authorized_keys
    echo "Injected SSH keys from ${SSH_AUTHORIZED_KEYS_FILE}"
fi
