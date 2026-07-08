# Expand an EBS Drive on an EC2 Instance

Short runbook for growing an EBS volume attached to a running EC2 instance. No downtime required for modern Nitro instances.

## Pick your OS

Scroll to the section for your OS - each is self-contained after the shared AWS step:

- **Linux** EC2 instance -> jump to the **Linux only** section below
- **Windows** EC2 instance -> jump to the **Windows only** section below

Every expansion follows three phases. The first (AWS-side) is identical for both OSes; the last two are OS-specific and covered in each section below.

1. **AWS side** - resize the EBS volume (Console or CLI).
2. **OS side - partition** - extend the partition to fill the new disk space.
3. **OS side - filesystem** - grow the filesystem into the extended partition.

---

## Shared prerequisites

- AWS CLI configured (**aws configure**) or Console access
- OS-level access to the instance:
    - **Linux:** SSH or SSM Session Manager
    - **Windows:** RDP, SSM Session Manager, or PowerShell remoting
- IAM permissions: **ec2:ModifyVolume**, **ec2:DescribeVolumes**, **ec2:DescribeVolumesModifications**, **ec2:CreateSnapshot**
- Snapshot the volume first if the data is important

---

## Shared step: resize the EBS volume in AWS

Do this **once** per expansion, regardless of OS. Then jump to your OS section.

### Option A - AWS Console

The console handles only the EBS volume resize (AWS-side phase). You still need to grow the partition and filesystem on the instance itself using the Linux or Windows section further down.

1. **Sign in** to the [AWS Management Console](https://console.aws.amazon.com/ec2/) and select the correct **Region** (top-right).
2. In the left nav, go to **Instances** and click the instance ID.
3. Open the **Storage** tab. Under *Block devices*, click the **Volume ID** of the drive to expand.
4. You are now in **EC2 > Volumes** with the volume selected. Click **Actions > Modify volume**.
5. (Optional but recommended) Before modifying, click **Actions > Create snapshot** and wait for it to reach **completed**.
6. In the *Modify volume* dialog:
    - **Size (GiB):** enter the new size (must be greater than current)
    - **Volume type / IOPS / Throughput:** change if needed (e.g. gp2 to gp3)
    - Click **Modify** and confirm **Yes**
7. Watch the volume's **Volume state** column. It will move through **in-use - modifying**, then **in-use - optimizing**, then **in-use**. The new size is usable as soon as it hits **optimizing**.
8. Connect to the instance (SSH for Linux, RDP or **Connect > Session Manager** for Windows) and run the OS-level steps for that platform below.

> Tip: to jump straight to the volumes list, use **EC2 > Elastic Block Store > Volumes** and filter by the instance ID.

### Option B - AWS CLI

    # Identify the volume attached to the instance
    aws ec2 describe-instances \
      --instance-ids i-0123456789abcdef0 \
      --query "Reservations[].Instances[].BlockDeviceMappings[].{Dev:DeviceName,Vol:Ebs.VolumeId}" \
      --output table
    
    # (Optional) Snapshot before resizing
    aws ec2 create-snapshot \
      --volume-id vol-0abc123def4567890 \
      --description "pre-resize $(date -u +%Y%m%dT%H%M%SZ)"
    
    # Modify the volume (new size in GiB, must be >= current size)
    aws ec2 modify-volume \
      --volume-id vol-0abc123def4567890 \
      --size 200
    
    # Watch progress; wait for state = optimizing or completed
    aws ec2 describe-volumes-modifications \
      --volume-ids vol-0abc123def4567890 \
      --query "VolumesModifications[].{State:ModificationState,Progress:Progress}"


Once the volume reaches **optimizing**, connect to your instance and follow the section for your OS.

---

# Linux only

All commands below are **Bash**, run on the Linux EC2 instance (SSH or SSM). Use **sudo** where shown.

## L1. Verify the new disk size is visible

    lsblk
    # nvme0n1        200G       <-- disk shows the NEW size
    # |- nvme0n1p1   100G       <-- partition still OLD size
    df -hT


If the disk still shows the old size on an older non-Nitro instance, run **sudo partprobe** or reboot.

## L2. Grow the partition

Replace device/partition numbers to match your **lsblk** output:

    # Nitro instances (nvme device names)
    sudo growpart /dev/nvme0n1 1
    
    # Xen instances (xvd device names)
    sudo growpart /dev/xvda 1


If **growpart** is missing:

    # Amazon Linux / RHEL / CentOS
    sudo yum install -y cloud-utils-growpart
    
    # Ubuntu / Debian
    sudo apt-get install -y cloud-guest-utils


## L3. Grow the filesystem

    # ext2 / ext3 / ext4 - pass the device
    sudo resize2fs /dev/nvme0n1p1
    
    # xfs - must be mounted; pass the mount point, NOT the device
    sudo xfs_growfs -d /
    
    # btrfs
    sudo btrfs filesystem resize max /
    
    # Verify
    df -hT


## L4. LVM volumes (optional)

If the partition is a physical volume in an LVM volume group:

    sudo pvresize /dev/nvme1n1
    sudo lvextend -r -l +100%FREE /dev/vg_name/lv_name   # -r resizes the fs too


## L5. Linux one-shot script (ext4/xfs, root vol, Nitro)

This script does both the AWS-side resize and the OS-side partition + filesystem grow. Run it **on the Linux instance** (the AWS CLI call happens from that instance's credentials).

    #!/usr/bin/env bash
    set -euo pipefail
    VOL_ID="${1:?volume-id required}"
    NEW_SIZE="${2:?new size in GiB required}"
    DEV="${3:-/dev/nvme0n1}"
    PART_NUM="${4:-1}"
    
    aws ec2 modify-volume --volume-id "$VOL_ID" --size "$NEW_SIZE"
    while [[ "$(aws ec2 describe-volumes-modifications --volume-ids "$VOL_ID" \
            --query 'VolumesModifications[0].ModificationState' --output text)" == "modifying" ]]; do
      sleep 10
    done
    
    sudo growpart "$DEV" "$PART_NUM"
    FS=$(lsblk -no FSTYPE "${DEV}p${PART_NUM}")
    case "$FS" in
      ext4) sudo resize2fs "${DEV}p${PART_NUM}" ;;
      xfs)  sudo xfs_growfs -d / ;;
      *)    echo "Unsupported fs: $FS" >&2; exit 1 ;;
    esac
    df -hT


Usage:

    ./expand-ebs.sh vol-0abc123def4567890 200


---

# Windows only

All commands below are **PowerShell**, run **on the Windows EC2 instance** as Administrator (RDP or SSM). NTFS grows automatically when the partition is extended, so there is no separate filesystem step.

## W1. Rescan disks to detect the new size

    # Force Windows to re-read disk geometry
    "rescan" | diskpart
    
    # Confirm the disk now reports the new size (Size vs AllocatedSize)
    Get-Disk | Format-Table Number, FriendlyName, Size, AllocatedSize, PartitionStyle


## W2. Identify the partition to grow

    # List partitions and their drive letters
    Get-Partition | Format-Table DiskNumber, PartitionNumber, DriveLetter, Size, Type
    
    # Or focus on one drive letter (e.g. D:)
    Get-Partition -DriveLetter D


## W3. Extend the partition to fill the disk

    # Find the max size available for the partition
    $max = (Get-PartitionSupportedSize -DriveLetter D).SizeMax
    
    # Extend to that size
    Resize-Partition -DriveLetter D -Size $max
    
    # Verify
    Get-Volume -DriveLetter D


GUI alternative: **Server Manager > Tools > Computer Management > Disk Management**, right-click the volume, choose **Extend Volume**, and accept the wizard defaults.

## W4. MBR to GPT (if you need more than 2 TiB)

MBR disks cap partitions at ~2 TiB. To go larger without data loss:

    # Validate the disk can be converted (no data loss)
    mbr2gpt /validate /disk:0 /allowFullOS
    
    # Convert (make a snapshot first!)
    mbr2gpt /convert /disk:0 /allowFullOS


## W5. Windows one-shot script (NTFS, any partition)

Two small scripts: one to run on your workstation to resize the EBS volume, one to run on the Windows instance to grow the partition.

**Workstation - Expand-Ebs.ps1** (needs AWS CLI + credentials):

    param(
      [Parameter(Mandatory)] [string] $VolumeId,
      [Parameter(Mandatory)] [int]    $NewSizeGiB
    )
    aws ec2 modify-volume --volume-id $VolumeId --size $NewSizeGiB | Out-Null
    do {
      Start-Sleep 10
      $state = aws ec2 describe-volumes-modifications --volume-ids $VolumeId `
               --query 'VolumesModifications[0].ModificationState' --output text
      Write-Host "State: $state"
    } while ($state -eq 'modifying')


**On the Windows instance - Grow-Partition.ps1** (run as Administrator):

    param(
      [Parameter(Mandatory)] [char] $DriveLetter
    )
    "rescan" | diskpart | Out-Null
    $max = (Get-PartitionSupportedSize -DriveLetter $DriveLetter).SizeMax
    Resize-Partition -DriveLetter $DriveLetter -Size $max
    Get-Volume -DriveLetter $DriveLetter


Usage:

    # From your workstation
    .\Expand-Ebs.ps1 -VolumeId vol-0abc123def4567890 -NewSizeGiB 200
    
    # On the Windows EC2 instance
    .\Grow-Partition.ps1 -DriveLetter D


---

# Constraints and gotchas (both OSes)

- Only one **modify-volume** per volume per **6 hours**
- New size must be **greater than or equal to** current size (cannot shrink an EBS volume in place)
- MBR partitions max out at **2 TiB** - convert to GPT if you need more (see the **W4** step in the Windows section)
- Older non-Nitro instance types may require a stop/start to see the new size
- Root volume resizes work the same way - no reboot required on Nitro
- **Windows NTFS** grows automatically with **Resize-Partition**; **Linux** always needs a separate **resize2fs**, **xfs_growfs**, or **btrfs filesystem resize** step
