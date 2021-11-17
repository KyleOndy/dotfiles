# kubernetes Homelab

The three Initial master nodes setup as hyperV VMs.

Copy and paste into each terminal

```bash
parted /dev/sda -- mklabel msdos
parted /dev/sda -- mkpart primary 2048 100%
mkfs.ext4 -L nixos /dev/sda1
sleep 1
mount /dev/disk/by-label/nixos /mnt
nixos-generate-config --root /mnt
```

Todo: bake this file into the iso image. Rysnc it over for now. Add it as an
import before doing `nixos-install`

```bash
λ rsync -e "ssh -o "StrictHostKeyChecking=no" -o UserKnownHostsFile=/dev/null" -v ./hosts/bootstrap.nix root@m2:/mnt/etc/nixos/
```
