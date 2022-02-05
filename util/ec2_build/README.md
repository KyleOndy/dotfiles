# EC2 builder

Kinda works. Sometimes.

Build aarch64 machines on a **big** EC2 instance. Useful because its way faster
than building on a RaspberryPi or via `binfmt` emulated on my x86_64 build
machine.

## Usage

```bash
make

#cleanup. Don't forget. Or $$$.
make destroy
```

## Todo

- Query out from flake which machines are aarch64 and build them all by default
- Figure out why `zfk-kernel` was not building.
- Look into `c6.metal` if I need `kvm` ability
