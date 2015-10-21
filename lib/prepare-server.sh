#!/bin/bash
#
# Stackup is an OpenStack instances backup tool
#
# Copyright (C) 2015 Gaëtan Trellu <gaetan.trellu@enovance.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA,
# 02110-1301, USA.

# Packages to install
pkgs="libvirt guestfish mailx ceph kmod-rbd lbzip2 rsync lvm2"

# Add MTU 9000 if not
# Add a check to determine if MTU 9000 is set

# Add Ceph repositories
cat <<EOF > /etc/yum.repos.d/ceph.conf
[ceph]
name=Ceph packages for $basearch
baseurl=http://ceph.com/rpm-firefly/rhel7/$basearch
enabled=1
priority=2
gpgcheck=1
type=rpm-md
gpgkey=https://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/release.asc

[ceph-noarch]
name=Ceph noarch packages
baseurl=http://ceph.com/rpm-firefly/rhel7/noarch
enabled=1
priority=2
gpgcheck=1
type=rpm-md
gpgkey=https://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/release.asc

[ceph-source]
name=Ceph source packages
baseurl=http://ceph.com/rpm-firefly/rhel7/SRPMS
enabled=1
priority=2
gpgcheck=1
type=rpm-md
gpgkey=https://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/release.asc
EOF

# Install packages
yum update -y
yum install $pkgs -y

# Check if RBD is supported in the qemu version installed on the backup server
if [ ! "$(qemu-img -h | tail -1 | grep rbd)" ]
then
  echo "The qemu-img version installed doesn't support RBD support."
  yum remove qemu-kvm qemu-img qemu-kvm-common -y
  
  for qemuPkg in libcacard qemu-img libcacard-tools qemu-kvm-common qemu-kvm qemu-kvm-tools
  do
    rpm -ivh http://labs.incloudus.com/rpm/centos/7/${qemuPkg}-rhev-1.5.3-60.el7.centos.10.x86_64.rpm
  done
  
  yum install libvirt libguestfs-tools-c -y
fi

# Enable and start the libvirtd service
systemctl enable libvirtd
systemctl start libvirtd

# Make RBD working with LVM
sed -i 's/# types = \[ "fd", 16 \]/types = \[ "rbd", 1024 \]/g' /etc/lvm/lvm.conf

# Enable and start lvmetad services
systemctl enable lvm2-lvmetad.socket
systemctl enable lvm2-lvmetad.service
systemctl start lvm2-lvmetad.socket
systemctl start lvm2-lvmetad.service

# Enable the allow_other/allow_root options in Fuse
sed -i 's/# user_allow_other/user_allow_other/g' /etc/fuse.conf

# Load the rbd kernel module
if [ ! "$(lsmod | grep ^rbd)" ]
then
  modprobe rbd
  if [ "$?" != 0 ]
  then
    echo "Unable to load the rbd kernel module"
    exit 1
  fi
fi

if [ ! -d $miscDirectory ]
then
  mkdir -p ${miscDirectory}/user
fi

cat <<EOF > ${miscDirectory}/user/msg_backup

if [ ! -z \$SSH_TTY ]
then
        backups=\$(mount | grep \$USER | awk '{ print \$3 }' | sed 's/^.*'\$USER'\///')
        total=\$(echo \$backups | wc -l)
        echo "######################################################"
        echo "#       Welcome to the OpenStack backup server       #"
        echo "######################################################"
        echo
        echo "You have \$total backup(s) available:"
        for backup in \$backups
        do
                echo -e "\t- cd ~/\${backup}\n"
        done
fi

EOF

# Create stackup log files
if [ ! -d /var/log/stackup ]
then
  mkdir /var/log/stackup
fi
