#!/bin/sh -eux

SSHD_CONFIG="/etc/ssh/sshd_config"

# ensure that there is a trailing newline before attempting to concatenate
sed -i -e '$a\' "$SSHD_CONFIG"

USEDNS="UseDNS no"
if grep -q -E "^[[:space:]]*UseDNS" "$SSHD_CONFIG"; then
    sed -i "s/^\s*UseDNS.*/${USEDNS}/" "$SSHD_CONFIG"
else
    echo "$USEDNS" >>"$SSHD_CONFIG"
fi

GSSAPI="GSSAPIAuthentication no"
if grep -q -E "^[[:space:]]*GSSAPIAuthentication" "$SSHD_CONFIG"; then
    sed -i "s/^\s*GSSAPIAuthentication.*/${GSSAPI}/" "$SSHD_CONFIG"
else
    echo "$GSSAPI" >>"$SSHD_CONFIG"
fi
ENV_ACC=AcceptEnv
if grep -q -E "^[[:space:]]*${ENV_ACC}" "$SSHD_CONFIG"; then
    sed -i "s/\(^\s*${ENV_ACC}.*\)/#\1/" "$SSHD_CONFIG"
fi

PSW_AUTH="PasswordAuthentication yes"
if grep -q -E "^[[:space:]]*PasswordAuthentication" "$SSHD_CONFIG"; then
    sed -i "s/^\s*PasswordAuthentication.*/${PSW_AUTH}/" "$SSHD_CONFIG"
fi

LOGIN_TIMEOUT="LoginGraceTime 0"
if grep -q -E ".*LoginGraceTime" "$SSHD_CONFIG"; then
    sed -i "s/.*LoginGraceTime.*/${LOGIN_TIMEOUT}/" "${SSHD_CONFIG}"
else
    echo "${LOGIN_TIMEOUT}" >> "${SSHD_CONFIG}"
fi

CLIENT_ALIVE_INTERVAL="ClientAliveInterval 600"
if grep -q -E ".*ClientAliveInterval" "$SSHD_CONFIG"; then
    sed -i "s/.*ClientAliveInterval.*/${CLIENT_ALIVE_INTERVAL}/" "${SSHD_CONFIG}"
else
    echo "${CLIENT_ALIVE_INTERVAL}" >> "${SSHD_CONFIG}"
fi

CLIENT_ALIVE_COUNT="ClientAliveCountMax 10"
if grep -q -E ".*ClientAliveCountMax" "$SSHD_CONFIG"; then
    sed -i "s/.*ClientAliveCountMax.*/${CLIENT_ALIVE_COUNT}/" "${SSHD_CONFIG}"
else
    echo "${CLIENT_ALIVE_COUNT}" >> "${SSHD_CONFIG}"
fi
