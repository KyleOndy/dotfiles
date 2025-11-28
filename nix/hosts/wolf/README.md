# Wolf

## Install

```
nix run github:nix-community/nixos-anywhere -- \
  --flake .#generic \
  --generate-hardware-config nixos-generate-config ./hardware-configuration.nix \
  --target-host ubuntu@51.79.99.201
```

- Get the new host key for sops
- Update sops

make HOSTNAME=wolf deploy-rs
