#!/bin/sh
# ssh helpers for the USB-connected phone (iproxy 2222 22). Password via NRSS_SSH_PASSWORD (default alpine).
export SSHPASS="${NRSS_SSH_PASSWORD:-alpine}"
NRSS_SSH_OPTS="-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o PreferredAuthentications=password -o PubkeyAuthentication=no"
dev() { sshpass -e ssh $NRSS_SSH_OPTS -p "${NRSS_SSH_PORT:-2222}" root@127.0.0.1 "$@"; }
dev_put() { sshpass -e ssh $NRSS_SSH_OPTS -p "${NRSS_SSH_PORT:-2222}" root@127.0.0.1 "cat > '$2'" < "$1"; }
dev_get() { sshpass -e ssh $NRSS_SSH_OPTS -p "${NRSS_SSH_PORT:-2222}" root@127.0.0.1 "cat '$1'" > "$2"; }
