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

# List volumes with stackup=True metadata
# stackup=True metadata means that volume will be backuped
cinder list \
  --metadata stackup=True \
  --all-tenants | sed '1,3d;$d' | awk -F"|" '{ print $2"|"$3"|"$6 }' | sed 's/ //g' > $volumesFile

for info in $(cat $volumesFile)
do
  # Split informations volume in many variables
  volumeId=$(echo $info | awk -F"|" '{ print $1 }')
  tenantId=$(echo $info | awk -F"|" '{ print $2 }')
  volumeSize=$(echo $info | awk -F"|" '{ print $3 }')
  
  # Get the volume stackup status (True or False)
  backupStatus=$(cinder metadata-show $volumeId | awk '$2 ~ /^stackup/ { print $4 }')
  
  # Because enduser isn't perfect, we accept True, true and TRUE as a metadata value
  if [ "$backupStatus" == "True" ] || [ "$backupStatus" == "true" ] || [ "$backupStatus" == "TRUE" ]
  then
    # Get tenant client name if the current tenant have admin level
    if [ "$OS_TENANT_NAME" == "admin" ] || [ "$OS_TENANT_NAME" == "$backupTenant" ]
    then
      tenantName=$(keystone tenant-get $tenantId | awk '$2 ~ /^name/ { print $4 }')
    else
      tenantName=$OS_TENANT_NAME
    fi
  
    tenantBackupDirectory=${backupDirectory}/${tenantName}
    
    # Create the home if it's the first backup for the tenant
    # An email is send with the server address, username and password
    # If there is an SSH key in the backuped volume, this one will be add to the authorized_keys
    if [ ! -d $tenantBackupDirectory ]
    then
      useradd -s $defaultShell -m -d $tenantBackupDirectory $tenantName
      mkdir -p ${tenantBackupDirectory}/qcow2
      mkdir -p ${tenantBackupDirectory}/mount
      mkdir -p ${tenantBackupDirectory}/archives
      mkdir -p ${tenantBackupDirectory}/logs
      chown -R $tenantName:$tenantName $tenantBackupDirectory
  
      password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 12 | xargs)
      email=$(keystone user-get $tenantName | awk '$2 ~ /^email/ { print $4 }')
      echo -e "${password}\n${password}" | passwd $tenantName

      mailContent="Hi,\n\nPlease find your login:\n\n\t- Login: ${tenantName}\n\t- Password: ${password}\n\t- ${backupServerFqdn}\n\nRegards,\n\n- OpenStack Team -"
      echo -e $mailContent | mail -s "OpenStack backup server account" $email
    fi
  
    # Create a snapshot of the volume who should be backuped
    # The force option will be used only if the volume isn't in "available" state
    # Backup name will be "xxxx_bck-incr-xxxx", if it's a full, incr become full
    cinder snapshot-create \
      --force True \
      --display-name "${tenantName}_bck-incr-${volumeId}" \
      --display-description "Stackup - $dateFormat" $volumeId | awk '$2 ~ /^id/ { print $4 }' > $snapshotsFile
    
    # Snapshot creation can take few seconds
    sleep 3
    
    # Get the new snapshot ID and remove useless file
    snapshotId=$(cat $snapshotsFile)
    rm -f $snapshotsFile
  
    # If --use-ceph option is used
    if [ $ceph ]
    then
      # Set date as metadata value for the new snapshot
      # This date will be use for the expire part
      cinder snapshot-metadata $snapshotId set stackup_date=$(date +%Y%m%d) > /dev/null
      
      # Check if full already exists for the volume
      # During the full snapshot creation, snapshot ID is stored in a new created file
      # This file is very important, NEVER delete this one !
      if [ -f ${tenantBackupDirectory}/logs/full-${volumeId}.last ]
      then
        # Check if the full snapshot is expired
        # Get the expire metadata from the full snapshot and compare it with current date
        # If both match, the full will be deleted
        expireFullDate=$(cinder snapshot-metadata-show $(cat ${tenantBackupDirectory}/logs/full-${volumeId}.last) | awk '$2 ~ /^stackup_expire/ { print $4 }')
        oldFullSnapshotId=$(cat ${tenantBackupDirectory}/logs/full-${volumeId}.last)
        if [ "$expireFullDate" == "$(date +%Y%m%d)" ]
        then
          # Full snapshot deletion and cleaning in the *.last file
          cinder snapshot-delete $oldFullSnapshotId
          >${tenantBackupDirectory}/logs/full-${volumeId}.last
        else
          # If the snapshot isn't expire, RBD will be used to map the Ceph snapshot on the system
          currentFullSnapshotId=$(cat ${tenantBackupDirectory}/logs/full-${volumeId}.last)
          rbd -p $rbdPool map volume-${volumeId}@snapshot-${currentFullSnapshotId} --name $rbdName --id $rbdUser
          rbdDeviceFull=$(rbd showmapped | awk '$4 ~ /'$currentFullSnapshotId'/ { print $NF }' | awk -F"/" '{ print $NF }')
          
          # Get the snapshot filesystem type
          blockType=$(/sbin/blkid -o value -s TYPE /dev/${rbdDeviceFull}p*)
          
          # Detect if snapshot is under LVM
          # If yes, we have to use guestmount to mount the snapshot
          if [ "$blockType" == "LVM2_member" ]
          then
            lvm=true

            # Get the volume group and logical volume name
            vgName=$(vgs --noheadings -o +devices | awk '$NF ~ /'$rbdDeviceFull'/ { print $1 }')
            lvFromVg=$(lvs --noheadings -o name $vgName)
            for lv in $lvFromVg
            do
              mkdir -p ${tenantBackupDirectory}/mount/${currentFullSnapshotId}/${vgName}/${lv}
              lvBlockType=""

              while [ -z $lvBlockType ]
              do
                lvBlockType=$(/sbin/blkid -o value -s TYPE /dev/${vgName}/${lv})
              done

              # Disable the snaphot volume group
              # LVM will not be mount on the backup node
              vgchange -an $vgName

              # Detect the filesystem on the snapshot's logical volume
              # When detected, guestmount options are set
              case $lvBlockType in
              	xfs) guestmount -a /dev/${rbdDeviceFull} \
                       -r -m /dev/${vgName}/${lv}:/:${mountXfsOpts}:xfs ${tenantBackupDirectory}/mount/${currentFullSnapshotId}/${vgName}/${lv}
              	;;
              	ext3) guestmount -a /dev/${rbdDeviceFull} \
                        -r -m /dev/${vgName}/${lv}:/:${mountExt3Opts}:ext3 ${tenantBackupDirectory}/mount/${currentFullSnapshotId}/${vgName}/${lv}
              	;;
              	ext4) guestmount -a /dev/${rbdDeviceFull} \
                        -r -m /dev/${vgName}/${lv}:/:${mountExt4Opts}:ext4 ${tenantBackupDirectory}/mount/${currentFullSnapshotId}/${vgName}/${lv}
              	;;
              	*) echo "$lvBlockType filesystem not supported"
              	;;
              esac
            done
          else
            # If no LVM has been detected so we get the snapshot's filesystem type
            for rbdFullPartition in $(ls -1 /dev/${rbdDeviceFull}p* | awk -F"/" '{ print $NF }')
            do
              # Store the snapshot's full device and partition
              # This will be used during the rsync to compare directories
              # mount options have to be changed in /etc/stackup/stackup.conf
              echo $rbdFullPartition > ${tenantBackupDirectory}/logs/full-${volumeId}-partition.last
              case $blockType in
                xfs) mount -t xfs -o $mountXfsOpts \
                       /dev/${rbdFullPartition} ${tenantBackupDirectory}/mount/${currentFullSnapshotId}/${rbdFullPartition}
                ;;
                ext3) mount -t ext3 -o $mountExt3Opts \
                        /dev/${rbdFullPartition} ${tenantBackupDirectory}/mount/${currentFullSnapshotId}/${rbdFullPartition}
                ;;
                ext4) mount -t ext4 -o $mountExt4Opts \
                        /dev/${rbdFullPartition} ${tenantBackupDirectory}/mount/${currentFullSnapshotId}/${rbdFullPartition}
                ;;
                *) echo "$blockType filesystem not supported"
                ;;
              esac
            done
          fi
          # Cleaning is good :)
          unset blockType vgName lvFromVg lvBlockType lv rbdFullPartition
        fi
      fi
  
      # Get snapshot list for the volume
      snapshotExists=$(cinder snapshot-list \
        --all-tenants \
        --status available \
        --volume-id $volumeId | sed '1,3d;$d' | wc -l)
      
      # If snapshot list is equal to 1 it means that it's a full
      # Because it's a full, we have to set metadata:
      # stackup_type to determine if it's a full or an incremental
      # stackup_expire to set an expiration of the full
      # $retention value can be changed in /etc/stackup/stackup.conf
      if [ $snapshotExists -eq 1 ]
      then
        cinder snapshot-metadata $snapshotId set stackup_type=Full > /dev/null
        cinder snapshot-metadata $snapshotId set stackup_expire=$(date +%Y%m%d -d "+ $retention day") > /dev/null
        cinder snapshot-rename $snapshotId ${tenantName}_bck-full-${volumeId} > /dev/null
        echo $snapshotId > ${tenantBackupDirectory}/logs/full-${volumeId}.last
        makeFull=true
      else
        cinder snapshot-metadata $snapshotId set stackup_type=Incremental > /dev/null
      fi
  
      # Map the RBD volume@snapshot on the system
      rbd -p $rbdPool map volume-${volumeId}@snapshot-${snapshotId} --name $rbdName --id $rbdUser
      rbdDevice=$(rbd showmapped | awk '$4 ~ /'$snapshotId'/ { print $NF }')
      
      sleep 1
      
      mkdir ${tenantBackupDirectory}/mount/${snapshotId}
    
      for rbdPartition in $(ls -1 ${rbdDevice}p* | awk -F"/" '{ print $NF }')
      do
        # Detect if snapshot is under LVM
        # If yes, we have to use guestmount to mount the snapshot
        blockType=$(/sbin/blkid -o value -s TYPE /dev/${rbdPartition})
        if [ "$blockType" == "LVM2_member" ]
        then
        	lvm=true
        
        	# Get the volume group and logical volume name
        	vgName=$(vgs --noheadings -o +devices | awk '$NF ~ /'$rbdPartition'/ { print $1 }')
        	lvFromVg=$(lvs --noheadings -o name $vgName)
        	for lv in $lvFromVg
        	do
            mkdir -p ${tenantBackupDirectory}/mount/${snapshotId}/${vgName}/${lv}
            lvBlockType=""
            
            while [ -z $lvBlockType ]
            do
            	lvBlockType=$(/sbin/blkid -o value -s TYPE /dev/${vgName}/${lv})
            done
            
            # Disable the snaphot volume group
            # LVM will not be mount on the backup node
            vgchange -an $vgName
            
            # Detect the filesystem on the snapshot's logical volume
            # When detected, guestmount options are set
            case $lvBlockType in
              xfs) guestmount -a /dev/${rbdPartition} \
                     -r -m /dev/${vgName}/${lv}:/:${mountXfsOpts}:xfs ${tenantBackupDirectory}/mount/${snapshotId}/${vgName}/${lv}
              ;;
              ext3) guestmount -a /dev/${rbdPartition} \
                      -r -m /dev/${vgName}/${lv}:/:${mountExt3Opts}:ext3 ${tenantBackupDirectory}/mount/${snapshotId}/${vgName}/${lv}
              ;;
              ext4) guestmount -a /dev/${rbdPartition} \
                      -r -m /dev/${vgName}/${lv}:/:${mountExt4Opts}:ext4 ${tenantBackupDirectory}/mount/${snapshotId}/${vgName}/${lv}
              ;;
              *) echo "$lvBlockType filesystem not supported"
              ;;
            esac
          done
        else
          mkdir -p ${tenantBackupDirectory}/mount/${snapshotId}/${rbdPartition}
          
          # mount options have to be changed in /etc/stackup/stackup.conf
          case $blockType in
            xfs) mount -t xfs -o $mountXfsOpts \
                   /dev/${rbdPartition} ${tenantBackupDirectory}/mount/${snapshotId}/${rbdPartition}
            ;;
            ext3) mount -t ext3 -o $mountExt3Opts \
                    /dev/${rbdPartition} ${tenantBackupDirectory}/mount/${snapshotId}/${rbdPartition}
            ;;
            ext4) mount -t ext4 -o $mountExt4Opts \
                    /dev/${rbdPartition} ${tenantBackupDirectory}/mount/${snapshotId}/${rbdPartition}
            ;;
            *) echo "$blockType filesystem not supported"
            ;;
          esac
        fi
    
        # Set some values for the rsync and tar commandd
        if [ $lvm ]
        then
          partition="${vgName}/${lv}"
          fullPartition="$partition"
          unset lvm
        else
          partition="$rbdPartition"
          if [ -f ${tenantBackupDirectory}/logs/full-${volumeId}-partition.last ]
          then
            fullPartition=$(cat ${tenantBackupDirectory}/logs/full-${volumeId}-partition.last)
          fi
        fi
   
        # If $makeFull is true it means that a full backup will be performed
        # We try to find a SSH public key in the full to make the login easier on the backup server 
        if [ $makeFull ]
        then
          if [ -f ${tenantBackupDirectory}/mount/${snapshotId}/${partition}/root/.ssh/authorized_keys ] && [ ! -f ${tenantBackupDirectory}/.ssh/authorized_keys ]
          then
            /usr/sbin/runuser -l $tenantName -c "mkdir ~/.ssh ; chmod 0700 ~/.ssh"
            sed 's/^.*ssh/ssh/' ${tenantBackupDirectory}/mount/${snapshotId}/${partition}/root/.ssh/authorized_keys > ${tenantBackupDirectory}/.ssh/authorized_keys
            chown ${tenantName}:${tenantName} ${tenantBackupDirectory}/.ssh/authorized_keys
            /usr/sbin/runuser -l $tenantName -c "chmod 0600 -R ~/.ssh/authorized_keys"
            /usr/sbin/runuser -l $tenantName -c "cat /opt/enovance/misc/user/msg_backup >> ~/.bashrc"
          fi
          
          # Full backup is archived and compressed, the harder part for your server :)
          # The compression method can be changed in the /etc/stackup/stacup.conf
          # tarBackupName can be changed in /etc/stackup/stackup.conf
          cd ${tenantBackupDirectory}/mount/${snapshotId}/${partition}
          tar -I $compressMode -cSf ${tenantBackupDirectory}/archives/full-vol-${volumeId}-${tarBackupName}-$(date +%Y%m%d).tar.bz2 .
          chown -R $tenantName:$tenantName $tenantBackupDirectory/archives/
          unset makeFull
        else
          mkdir -p $tenantBackupDirectory/archives/tmp/incr-vol-${volumeId}-${tarBackupName}-$(date +%Y%m%d)
          
          # If it's an incremental backup, some values have to be defined
          # fullSource to define the last full backup
          # incrSource to define the current snapshot backup
          # tempSource to define where diff files should be stored
          fullSource="${tenantBackupDirectory}/mount/$(cat ${tenantBackupDirectory}/logs/full-${volumeId}.last)/${fullPartition}/"
          incrSource="${tenantBackupDirectory}/mount/${snapshotId}/${partition}/"
          tempSource="$tenantBackupDirectory/archives/tmp/incr-vol-${volumeId}-${tarBackupName}-$(date +%Y%m%d)"
          rsync -av --compare-dest=${fullSource} $incrSource $tempSource
          find $tempSource -depth -type d -empty -delete
    
          # Incremental backup is archived and compressed
          # The compression method can be changed in the /etc/stackup/stacup.conf
          cd $tenantBackupDirectory/archives/tmp
          tar -I lbzip2 -cSf ${tenantBackupDirectory}/archives/incr-vol-${volumeId}-${tarBackupName}-$(date +%Y%m%d).tar.bz2 .
          rm -rf $tenantName:$tenantName $tenantBackupDirectory/archives/tmp/incr-vol-${volumeId}-${tarBackupName}-$(date +%Y%m%d)
          
          chown -R $tenantName:$tenantName $tenantBackupDirectory/archives/
          
          # Deletion of the incremental snapshot
          cinder snapshot-delete $snapshotId
          
          # Umount and unmap the full snapshot volume
          umount ${tenantBackupDirectory}/mount/${currentFullSnapshotId}/${fullPartition}
          sleep 5
          rbd unmap /dev/${rbdDeviceFull}
        fi
   
        cd ${tenantBackupDirectory}
        
        # Umount and unmap the incremental snapshot volume
        umount ${tenantBackupDirectory}/mount/${snapshotId}/${partition}
        sleep 5
        rbd unmap $rbdDevice
      done
    else
      # If Ceph isn't the selectd backup method
      # Create a new volume from the last snapshot created from the volume who should be backuped
      cinder create \
        --snapshot-id $snapshotId \
        --display-name "${tenantName}_bck-from-snap-${snapshotId}" \
        --display-description "Stackup - $dateFormat" $volumeSize | awk '$2 ~ /^id/ {print $4}' > $glanceVolumeFile
      
        sleep 3
      
      # Upload the new volume in Glance as an image
      cinder upload-to-image \
        --force True \
        --disk-format $imageType \
        $(cat $glanceVolumeFile) ${tenantName}_bck-vol-${volumeId}-$(date +%Y%m%d) | awk '$2 ~ /^image_id/ {print $4}' > $glanceImageFile
      
      # Set metadata on the volume to avoid that user add stackup=True metadata
      # Without this metadata, the volume of the snapshot created from the volume that we want backup will be backuped
      # Crazy loop :)
      cinder metadata $(cat $glanceVolumeFile) set stackup_already_backuped=True
      
      # Set expiration metadata on the Glance image
      glance image-update --property stackup_expire=$(date +%Y%m%d -d "+ $retention day") $(cat $glanceImageFile)
    fi
  fi
done

# Delete useless files
rm -rf $volumesFile $glanceVolumeFile $glanceImageFile
