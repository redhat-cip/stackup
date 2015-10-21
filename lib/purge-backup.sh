#!/bin/bash -x
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

cinder snapshot-list \
  | grep bck-full | awk -F"|" '{ print $2"|"$3"|"$5 }' | sed 's/ //g' > $expiredSnapshotsFile

for snapshot in $(cat $expiredSnapshotsFile)
do
  snapshotId=$(echo $snapshot | awk -F"|" '{ print $1 }')
  snapshotVolumeId=$(echo $snapshot | awk -F"|" '{ print $2 }')
  snapshotName=$(echo $snapshot | awk -F"|" '{ print $3 }')
  snapshotTenantName=$(echo $snapshotName | awk -F"_" '{ print $1 }')
  
  tenantBackupDirectory=${backupDirectory}/${snapshotTenantName}
  
  if [ -d $tenantBackupDirectory ]
  then
    for archive in $(find ${tenantBackupDirectory}/archives/ -maxdepth 1 -type f -regex "^.*\(incr\|full\)-vol-${snapshotVolumeId}.*tar.bz2$")
    do
      archiveDateCreation=$(stat --format=%x $archive | awk '{ print $1 }' | sed 's/-//g')
      archiveDateExpire=$(( $archiveDateCreation + $retention ))
      
      if [ "$archiveDateExpire" == $(date +%Y%m%d) ]
      then
        rm -f $archive
      fi
    done
  fi
done

rm $expiredSnapshotsFile
