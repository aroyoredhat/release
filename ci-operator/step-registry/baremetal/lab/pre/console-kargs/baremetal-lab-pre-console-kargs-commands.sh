#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

function join_by_semicolon() {
  local array_string="${1}"
  local prefix="${2}"
  local postfix="${3}"
  while [[ "${array_string}" = *\;* ]]; do
    # print initial part of string; then, remove it
    echo -n "${prefix}${array_string%%;*}${postfix} "
    array_string="${array_string#*;}"
  done
  # either the last or only one element is printed at the end
  if [ "${#array_string}" -gt 0 ]; then
    echo -n "${prefix}${array_string}${postfix} "
  fi
}

echo "Rendering the ignition hook from butane..."

if [[ "${ipv4_enabled:-true}" == "false" ]] && [[ "${ipv6_enabled:-false}" == "true" ]]; then
  base_url="http://[${INTERNAL_NET_IPV6}]/$(<"${SHARED_DIR}/cluster_name")"
else
  base_url="http://${INTERNAL_NET_IP}/$(<"${SHARED_DIR}/cluster_name")"
fi

# We use a different console-hook ignition file for each node to allow the configuration of heterogeneous nodes
# (i.e., nodes from different vendors)
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [ "${#mac}" -eq 0 ] || [ "${#name}" -eq 0 ]; then
    echo "Error while unmarshalling hosts entries"
    exit 1
  fi
  mac_prefix=${mac//:/-}
  role=${name%%-[0-9]*}
  role=${role%%-a*}
  echo "Rendering ignition for ${name} (${role}) - #${host}..."
  butane --strict --raw -o "${SHARED_DIR}/${mac_prefix}-console-hook.ign" <<EOF
variant: fcos
version: 1.3.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
      - $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
systemd:
  units:
  - name: console-hook.service
    enabled: true
    contents: |
      [Unit]
      Description=Run installer with custom kargs
      Requires=coreos-installer-pre.target
      After=coreos-installer-pre.target
      OnFailure=emergency.target
      OnFailureJobMode=replace-irreversibly
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      EnvironmentFile=/etc/os-release
      # Ensure disks are wiped before running the installer. This should be done by the wiping steps, but since
      # we can control installation in bm-upi, let's mitigate the risk of a previous installation that left data
      # on the disks due to the wiping step failing or being skipped.
      ExecStartPre=-bash -c 'set -x; for i in \$(lsblk -I8,259 -nd --output name); do wipefs -a /dev/\$i; done; set +x'
      ExecStartPre=/usr/bin/coreos-installer install $root_device \
        --delete-karg console=ttyS0,115200n8 $(join_by_semicolon "${console_kargs}" "--append-karg console=" "") \
        --ignition-url ${base_url%%*(/)}/${role}.ign \
        --insecure-ignition --copy-network
      # Some servers' firmware push any new detected boot options to the tail of the boot order.
      # When other boot options are present and bootable, such a server will boot from them instead of the new one.
      # As a (temporary?) workaround, we manually add the boot option.
      # NOTE: it's assumed that old OSes boot options are removed from the boot options list during the wipe operations.
      # xrefs: https://bugzilla.redhat.com/show_bug.cgi?id=1997805
      #        https://github.com/coreos/fedora-coreos-tracker/issues/946
      #        https://github.com/coreos/fedora-coreos-tracker/issues/947
      ExecStartPre=/usr/bin/bash -c ' \
        ARCH=\$(uname -m | sed "s/x86_64/x64/;s/aarch64/aa64/"); \
        [ \$ID = "fedora" ] && OS="fedora" || OS=\$(cut -d \':\' -f 3 <<< "\$CPE_NAME"); \
        /usr/sbin/efibootmgr -c -d "$root_device" -p 2 -c -L "Red Hat CoreOS" -l "\\\\EFI\\\\\\\$OS\\\\shim\$ARCH.efi" \
      '
      ExecStart=/usr/bin/systemctl --no-block reboot
      StandardOutput=kmsg+console
      StandardError=kmsg+console

      [Install]
      RequiredBy=default.target

EOF
done

echo "Ignition files are ready to deploy."
