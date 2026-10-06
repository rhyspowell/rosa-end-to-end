#!/bin/bash
set -euxo pipefail

# Remove Packer/build SSH authorized keys so they are not published with the image.
for user in cloud-user ec2-user root; do
  home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
  if [ -n "${home:-}" ] && [ -f "${home}/.ssh/authorized_keys" ]; then
    truncate -s 0 "${home}/.ssh/authorized_keys"
  fi
done

# Reset machine identity so each instance gets a unique ID on first boot.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Clear cloud-init state so first boot configuration runs cleanly.
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init clean --logs --seed || true
fi
rm -rf /var/lib/cloud/instances /var/lib/cloud/instance /var/lib/cloud/data
rm -f /var/lib/cloud/sem/* /var/lib/cloud/*.gz 2>/dev/null || true

# Clear package caches.
dnf clean all || true
rm -rf /var/cache/dnf /var/cache/yum

# Truncate logs and clear temp files.
find /var/log -type f -exec truncate -s 0 {} +
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

# Remove shell history for root and build users.
for user in root cloud-user ec2-user; do
  home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
  if [ -n "${home:-}" ]; then
    rm -f "${home}/.bash_history" "${home}/.zsh_history"
  fi
done
history -c 2>/dev/null || true

echo "Image cleanup complete"
