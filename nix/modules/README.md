# Modules

These modules are not intended to be blindly dropped into someone else's
configuration. These are designed to fit my specific use cases, and there is
probably a lot of things that are not flexible enough for other people. I do
hope these modules can be an inspiration if needed.

## Home Manager Modules

The [hm_modules](./hm_modules) directory is for modules that leverage
[home-manager]. This is _typically_ modules that are applied to a user
configuration.

[home-manager]: https://github.com/nix-community/home-manager

## Nix Modules

The [nix_modules](./nix_modules) directory is for modules applied to a
system level, via standard nix configuration.
