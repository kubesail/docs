#!/bin/bash
set -e
set -o noglob

VG_GROUP_NAME="pibox-group"
DISKS_TO_ADD=""

# For each of the possible 5 disks installed
for DISK in /dev/sda /dev/sdb /dev/sdc /dev/sdd /dev/sde; do
  # Ensure the device disks, it has no partition, and has no filesystem signature
  if [[ -a "${DISK}" && ! -a "${DISK}1" && "$(wipefs -i -n ${DISK})" == "" ]]; then
    # Test creating a PV out of this disk, which will fail if the disk appears to have data on it
    if echo n | pvcreate -qt "${DISK}"; then
      echo "${DISK} is not partitioned and has no filesystem signature, adding to volume group"
      # Format the disk as one large Linux partition and create the PV
      echo 'type=83' | sfdisk "${DISK}"
      echo n | pvcreate -q "${DISK}1" && {
        DISKS_TO_ADD="${DISKS_TO_ADD} ${DISK}1"
      }
    fi
  fi
done

# If our VirtualGroup doesn't exist, let's provision for the first time:
if [[ "$(vgdisplay ${VG_GROUP_NAME})" == "" && "${DISKS_TO_ADD}" != "" ]]; then
  vgcreate "${VG_GROUP_NAME}" "${DISKS_TO_ADD}"
  # Use 100% of available space
  lvcreate -n k3s -l 100%FREE "${VG_GROUP_NAME}"
  # Create a new EXT4 filesystem with zero reserved space
  mkfs.ext4 -F -m 0 -b 4096 "/dev/${VG_GROUP_NAME}/k3s"
  # Enable "fast_commit" https://www.phoronix.com/scan.php?page=news_item&px=EXT4-Fast-Commit-Queued
  tune2fs -O fast_commit "/dev/${VG_GROUP_NAME}/k3s"
  # Run a filesystem check to make sure things are OK
  e2fsck -f "/dev/${VG_GROUP_NAME}/k3s"
  # Add the mount location to /etc/fstab - note that we use data=ordered and journaling, which is potentially
  # slower than 'data=writeback' and `mkfs.ext4 -O ^has_journal`, but safer and more durable against crashes and power-loss
  # fast_commit above helps keep this from being too much of a slowdown
  echo "/dev/${VG_GROUP_NAME}/k3s /var/lib/rancher ext4 defaults,discard,nofail,noatime,data=ordered,errors=remount-ro 0 0" >> /etc/fstab

  # Migrate K3S if it exists (move /var/lib/rancher onto new LVM group)
  if [[ -d "/var/lib/rancher" ]]; then
    pgrep k3s && service k3s stop
    # Create a temporary directory
    mkdir -p /var/lib/rancher-ssd
    mount /dev/${VG_GROUP_NAME}/k3s /var/lib/rancher-ssd
    # Copy k3s into temp dir
    rsync -aqxP /var/lib/rancher/* /var/lib/rancher-ssd && rm -rf /var/lib/rancher
    # Move directories back into place and cleanup
    umount -l /var/lib/rancher-ssd
    mkdir /var/lib/rancher
    mount /dev/${VG_GROUP_NAME}/k3s
    rm -rf /var/lib/rancher-ssd
  else
    mkdir /var/lib/rancher
    mount /dev/${VG_GROUP_NAME}/k3s
  fi
elif [[ "${DISKS_TO_ADD}" != "" ]]; then
  echo "Extending disk array, adding: ${DISKS_TO_ADD}"
  vgextend "${VG_GROUP_NAME}" "${DISKS_TO_ADD}"
  lvextend -L100%FREE /dev/${VG_GROUP_NAME}/k3s
  resize2fs /dev/${VG_GROUP_NAME}/k3s
else
  echo "No disks to format, continuing"
fi

