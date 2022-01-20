# ZFS Setup

Delete existing partitions

```bash
sudo fdisk /dev/disk/by-id/usb-WD_My_Book_25ED_575832324436313731335A55-0\:0
> d
> w
```

Create mirror

```
sudo zpool create storage mirror "/dev/disk/by-id/usb-WD_My_Book_25ED_575832324436313731335A55-0:0" "/dev/disk/by-id/usb-WD_My_Book_25ED_575833324435313537483544-0:0"
```

Set legacy mountpoint so nix can mount it

```
sudo zfs set mountpoint=legacy storage
```

## Structure

- devices (typically disks)
- vdev (can be mirror or zraid, etc)
- pool ( can be one or more vdevs)
- dataset

## Resunce

```bash
mount /dev/disk/by-label/nixos /mnt && mount /dev/disk/by-label/boot /mnt/boot && nixos-enter
```

## tiget

```bash
sudo zpool create  -o ashift=12 -O mountpoint=legacy scratch /dev/nvme1n1
```

## My Setups

```txt
Dirves:   | 500 GB NVME     | 4TB spiiner | 4TB spinner | 4 TB spinner |
Vdev:     | scratch         |      Raid Z1                             |
pool:     | scratch         |      stoage                              |
datasets: | scratch/scratch | storage/{media,backups,data}             |

usage of datasets:
  scratch/scratch: fast local stroage, nothing _too_ important. Backedup to
                   storage pool, but not replicated off the box
  storage/media:   big media files. Not replicated, not backed up. Losing it
                   all would suck from an effort point of view, but nothing of
                   personal value is lost. Just an angry family when the
                   streaming system goes down.
  stoage/backups:  the most important files. Replicated to a ZFS server in an
                   outbuilding on propertty, and backed up into offsite
                   storage. These are the familiy photos and tax returns.
  sotrage/data:    Files that are inconvent to rebuild, but not worth paying to
                   backup in the cloud. Rolling the dice that the replication
                   across property is enough.
```

[svc.deploy@tiger:/mnt/scratch-big/unraid-media]$ rsync -arvhzP svc.deploy@util.lan.509ely.com:/mnt/scratch/unrad_copy/media/ .
