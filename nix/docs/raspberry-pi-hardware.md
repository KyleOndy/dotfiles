# Raspberry Pi Hardware Management with NixOS

## Philosophy & Approach

This repository uses a **stability-focused approach** to managing Raspberry Pi hardware with NixOS.

### What's Declarative

- Device tree overlays (via `hardware.deviceTree.overlays`)
- Peripheral configuration (via `nixos-hardware` modules)
- User permissions and udev rules
- Kernel modules and parameters

### What's Manual

- `config.txt` modifications (requires SD image rebuild or manual partition editing)
- Firmware updates
- One-time hardware initialization

### Why This Approach

As of NixOS 24.11, the `boot.loader.raspberryPi.firmwareConfig` option was removed from nixpkgs. While projects like `raspberry-pi-nix` (archived March 2025) provide full declarative config.txt management, we prioritize **stable, well-maintained tooling** over bleeding-edge declarativity.

**Trade-off**: config.txt changes require rebuilding the SD image or manual editing. In practice, this is rare after initial setup.

---

## config.txt Management

### When You Need to Edit config.txt

Common scenarios:

- Enabling firmware-level overlays (e.g., `dtoverlay=uart4`)
- Adjusting GPU memory split
- Setting display resolution
- Enabling hardware features (UART, I2C, SPI at firmware level)

### Option 1: Build-Time Configuration (Recommended)

Add settings when building the SD image:

```nix
sdImage.populateFirmwareCommands = lib.mkAfter ''
  chmod +w ./firmware/config.txt
  echo "# Custom hardware settings" >> ./firmware/config.txt
  echo "dtoverlay=uart4" >> ./firmware/config.txt
  echo "disable_splash=1" >> ./firmware/config.txt
'';
```

**Pros**: Declared in NixOS config, tracked in git
**Cons**: Only applies during SD image build, not on `nixos-rebuild`

### Option 2: Manual Editing (For Debugging)

On the running Raspberry Pi:

```bash
# Mount firmware partition
sudo mkdir -p /boot/firmware
sudo mount /dev/disk/by-label/FIRMWARE /boot/firmware

# Edit config.txt
sudo vim /boot/firmware/config.txt

# Unmount and reboot
sudo umount /boot/firmware
sudo reboot
```

**Use case**: Testing overlay settings before committing to SD image rebuild.

### Common config.txt Settings

```ini
# Performance
arm_boost=1
force_turbo=1

# Display
disable_splash=1
hdmi_group=2
hdmi_mode=82

# Hardware overlays (firmware-level)
dtoverlay=uart4
dtoverlay=i2c1
dtoverlay=disable-bt

# GPU memory (headless systems)
gpu_mem=16
```

---

## Device Tree Overlays

Device tree overlays configure hardware at the kernel level. NixOS provides two methods.

### Method 1: Inline DTS (Recommended)

Define overlays directly in your configuration:

```nix
hardware.deviceTree = {
  enable = true;
  filter = "*-rpi-4-*.dtb";  # Only process Pi 4 device trees
  overlays = [
    {
      name = "uart4-overlay";
      dtsText = ''
        /dts-v1/;
        /plugin/;

        / {
          compatible = "brcm,bcm2711";

          fragment@0 {
            target-path = "/soc/gpio@7e200000";
            __overlay__ {
              uart4_pins: uart4_pins {
                brcm,pins = <8 9>;
                brcm,function = <4>;  // alt4 = UART
                brcm,pull = <0 2>;    // TX no-pull, RX pull-up
              };
            };
          };

          fragment@1 {
            target-path = "/soc/serial@7e201600";
            __overlay__ {
              pinctrl-names = "default";
              pinctrl-0 = <&uart4_pins>;
              status = "okay";
            };
          };
        };
      '';
    }
  ];
};
```

### Method 2: External DTBO Files

Reference pre-compiled overlays:

```nix
hardware.deviceTree.overlays = [
  {
    name = "spi";
    dtboFile = "${pkgs.device-tree_rpi.overlays}/spi0-0cs.dtbo";
  }
];
```

### Enable dtmerge for Compatibility

Some overlays fail with "FDT_ERR_NOTFOUND". Enable dtmerge:

```nix
hardware.raspberry-pi."4".apply-overlays-dtmerge.enable = true;
```

### Device Tree Source (DTS) Syntax Reference

```dts
/dts-v1/;
/plugin/;

/ {
  compatible = "brcm,bcm2711";  // BCM2711 = Pi 4

  fragment@0 {
    // Option 1: Phandle reference (preferred)
    target = <&uart4>;

    // Option 2: Explicit path
    target-path = "/soc/serial@7e201600";

    __overlay__ {
      status = "okay";
      // Additional properties
    };
  };
};
```

**Finding device paths**: Check `/sys/firmware/devicetree/base/` or Raspberry Pi firmware overlays README.

---

## Peripheral Configuration

Use `nixos-hardware` modules for standard peripherals.

### GPIO

```nix
hardware.raspberry-pi."4".gpio.enable = true;
```

**What it does**:

- Creates `gpio` group
- Adds udev rules for `/dev/gpiochip*` and `/dev/gpiomem`
- Adds `iomem=relaxed` kernel parameter (needed for pigpiod)

**User access**:

```nix
users.users.myuser.extraGroups = [ "gpio" ];
```

**GPIO access methods**:

| Method           | Interface       | Library         | Use case                     |
| ---------------- | --------------- | --------------- | ---------------------------- |
| Character device | /dev/gpiochip0  | libgpiod        | Modern, recommended          |
| Sysfs            | /sys/class/gpio | Direct file I/O | Legacy, deprecated           |
| Memory-mapped    | /dev/gpiomem    | pigpio          | Fastest, requires root/iomem |

**Example usage**:

```bash
gpioget gpiochip0 17        # Read GPIO 17
gpioset gpiochip0 17=1      # Set GPIO 17 high
gpioinfo                    # List all pins
```

### I2C

```nix
hardware.raspberry-pi."4" = {
  i2c1.enable = true;          # Main user I2C bus (GPIO 2/3)
  i2c1.frequency = 400000;     # Optional: 400kHz fast mode
};
```

**What it does**:

- Enables I2C device tree
- Loads `i2c-dev` kernel module
- Creates `/dev/i2c-1`

**User access**:

```nix
users.users.myuser.extraGroups = [ "i2c" ];
```

**I2C bus mapping**:

| Bus  | Device     | GPIOs | Purpose              |
| ---- | ---------- | ----- | -------------------- |
| I2C0 | /dev/i2c-0 | -     | VideoCore (reserved) |
| I2C1 | /dev/i2c-1 | 2/3   | User GPIO pins       |

**Example usage**:

```bash
i2cdetect -y 1              # Scan I2C bus 1
i2cget -y 1 0x48 0x00       # Read from device 0x48
```

### PWM

```nix
hardware.raspberry-pi."4".pwm0.enable = true;  # PWM0 on GPIO 18
```

**PWM channel mapping**:

| Channel | Default GPIO | Alternates | Device                       |
| ------- | ------------ | ---------- | ---------------------------- |
| PWM0    | 18           | 12, 40     | /sys/class/pwm/pwmchip0/pwm0 |
| PWM1    | 19           | 13, 41, 45 | /sys/class/pwm/pwmchip0/pwm1 |

**Dual-channel PWM** (via config.txt):

```ini
dtoverlay=pwm-2chan,pin=18,pin2=19
```

### Audio

```nix
hardware.raspberry-pi."4".audio.enable = true;
```

**What it does**:

- Enables onboard audio (HDMI + headphone jack)
- Configures PulseAudio with `tsched=0` for better performance

**External I2S DAC** (HiFiBerry, etc.):

```ini
# In config.txt
dtoverlay=hifiberry-dacplus
```

Or via device tree overlay (see Device Tree Overlays section).

### Touchscreen

```nix
hardware.raspberry-pi."4".touch-ft5406.enable = true;
```

For official Raspberry Pi touchscreen display.

---

## UART Configuration

Raspberry Pi 4 has 6 UARTs, but UART0 is shared with Bluetooth.

### Pi 4 UART Mapping

| UART          | GPIOs | Device       | Notes                          |
| ------------- | ----- | ------------ | ------------------------------ |
| UART0 (PL011) | 14/15 | /dev/ttyAMA0 | Shared with Bluetooth          |
| UART1 (mini)  | 14/15 | /dev/ttyS0   | Less capable, baud rate issues |
| UART2         | 0/1   | /dev/ttyAMA1 | Pi 4 only                      |
| UART3         | 4/5   | /dev/ttyAMA2 | Pi 4 only                      |
| UART4         | 8/9   | /dev/ttyAMA3 | Pi 4 only                      |
| UART5         | 12/13 | /dev/ttyAMA4 | Pi 4 only                      |

**Recommendation**: Use UART2-5 to avoid Bluetooth conflicts.

### Example: Enable UART4

**Step 1**: Add device tree overlay

```nix
hardware.deviceTree.overlays = [{
  name = "uart4-complete";
  dtsText = ''
    /dts-v1/;
    /plugin/;

    / {
      compatible = "brcm,bcm2711";

      fragment@0 {
        target-path = "/soc/gpio@7e200000";
        __overlay__ {
          uart4_pins: uart4_pins {
            brcm,pins = <8 9>;
            brcm,function = <3>;  // alt4 = UART4 TXD/RXD
            brcm,pull = <0 2>;    // TX no-pull, RX pull-up
          };
        };
      };

      fragment@1 {
        target-path = "/soc/serial@7e201800";  // UART4
        __overlay__ {
          pinctrl-names = "default";
          pinctrl-0 = <&uart4_pins>;
          status = "okay";
        };
      };
    };
  '';
}];
```

**Step 2**: Add to config.txt (required)

```nix
sdImage.populateFirmwareCommands = lib.mkAfter ''
  chmod +w ./firmware/config.txt
  echo "dtoverlay=uart4" >> ./firmware/config.txt
'';
```

**Why both?**: The firmware needs to know about the overlay before kernel device tree processing.

### User Access

```nix
users.users.myuser.extraGroups = [ "dialout" ];
```

**Testing**:

```bash
ls -la /dev/ttyAMA*           # Verify UART devices exist
echo "test" > /dev/ttyAMA3    # Test UART4 (requires permissions)
```

---

## Permissions & udev Rules

### User Groups

| Group   | Purpose            | Devices                       |
| ------- | ------------------ | ----------------------------- |
| gpio    | GPIO access        | /dev/gpiochip\*, /dev/gpiomem |
| i2c     | I2C bus access     | /dev/i2c-\*                   |
| spi     | SPI bus access     | /dev/spidev\*                 |
| dialout | Serial port access | /dev/ttyAMA*, /dev/ttyS*      |

**Add user to groups**:

```nix
users.users.myuser = {
  extraGroups = [ "gpio" "i2c" "spi" "dialout" ];
};
```

### Custom udev Rules

If you need custom permissions not provided by `nixos-hardware`:

```nix
services.udev.extraRules = ''
  # GPIO character devices
  SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"

  # I2C devices
  SUBSYSTEM=="i2c-dev", GROUP="i2c", MODE="0660"

  # SPI devices
  SUBSYSTEM=="spidev", KERNEL=="spidev0.*", GROUP="spi", MODE="0660"

  # Serial ports
  SUBSYSTEM=="tty", KERNEL=="ttyAMA[0-9]*", GROUP="dialout", MODE="0660"
'';
```

---

## Quick Reference

### GPIO Pin Mappings (BCM Numbering)

Physical pin numbers differ from BCM GPIO numbers. Use BCM numbering in code.

**Common pins**:

| BCM GPIO | Physical Pin | Alt Functions        |
| -------- | ------------ | -------------------- |
| 2        | 3            | I2C1 SDA             |
| 3        | 5            | I2C1 SCL             |
| 8        | 24           | SPI0 CE0, UART4 TXD  |
| 9        | 21           | SPI0 MISO, UART4 RXD |
| 14       | 8            | UART0 TXD            |
| 15       | 10           | UART0 RXD            |
| 18       | 12           | PWM0                 |
| 19       | 35           | PWM1                 |

Full pinout: [pinout.xyz](https://pinout.xyz/)

### Device Paths

| Hardware | Device           | Path                    |
| -------- | ---------------- | ----------------------- |
| GPIO     | Character device | /dev/gpiochip0          |
| GPIO     | Memory-mapped    | /dev/gpiomem            |
| I2C1     | I2C bus          | /dev/i2c-1              |
| SPI0     | SPI bus          | /dev/spidev0.0          |
| UART0    | Serial port      | /dev/ttyAMA0            |
| UART4    | Serial port      | /dev/ttyAMA3            |
| PWM0     | PWM controller   | /sys/class/pwm/pwmchip0 |

### Common Device Tree Overlays

Available in Raspberry Pi firmware overlays:

| Overlay       | Purpose                        |
| ------------- | ------------------------------ |
| uart2         | Enable UART2 on GPIO 0/1       |
| uart3         | Enable UART3 on GPIO 4/5       |
| uart4         | Enable UART4 on GPIO 8/9       |
| uart5         | Enable UART5 on GPIO 12/13     |
| disable-bt    | Disable Bluetooth, free UART0  |
| miniuart-bt   | Move Bluetooth to mini-UART    |
| i2c1          | Enable I2C1 on GPIO 2/3        |
| spi0-1cs      | Enable SPI0 with 1 chip select |
| pwm-2chan     | Enable dual-channel PWM        |
| hifiberry-dac | HiFiBerry DAC                  |
| vc4-kms-v3d   | KMS video driver               |

Reference: [Raspberry Pi firmware overlays README](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README)

---

## Troubleshooting

### Verify Device Tree Applied

```bash
# Check loaded device tree
dtc -I fs /sys/firmware/devicetree/base > /tmp/dt.dts
cat /tmp/dt.dts | grep uart4

# List loaded overlays
vcgencmd get_config dtoverlay

# Check specific device enabled
cat /sys/firmware/devicetree/base/soc/serial@7e201600/status
# Should output: okay
```

### Verify Kernel Modules Loaded

```bash
# List loaded modules
lsmod | grep -E "i2c|spi|gpio"

# Check specific module
lsmod | grep i2c_bcm2835

# Load module manually (for testing)
sudo modprobe i2c-dev
```

### Test Peripherals

**GPIO**:

```bash
# List GPIO chips
gpiodetect

# Show pin info
gpioinfo gpiochip0

# Test pin (BCM 17 = physical pin 11)
gpioset gpiochip0 17=1
gpioget gpiochip0 17
```

**I2C**:

```bash
# Scan for devices
i2cdetect -y 1

# Check bus exists
ls -la /dev/i2c-*
```

**UART**:

```bash
# List serial devices
ls -la /dev/tty*

# Test loopback (connect TX to RX)
stty -F /dev/ttyAMA3 115200
cat /dev/ttyAMA3 &
echo "test" > /dev/ttyAMA3
```

**PWM**:

```bash
# Export PWM channel
echo 0 > /sys/class/pwm/pwmchip0/export

# Set period (100Hz = 10ms = 10000000ns)
echo 10000000 > /sys/class/pwm/pwmchip0/pwm0/period

# Set duty cycle (50% = 5000000ns)
echo 5000000 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle

# Enable
echo 1 > /sys/class/pwm/pwmchip0/pwm0/enable
```

### Common Issues

**"Permission denied" accessing GPIO/I2C/SPI**:

- Check user is in correct group: `groups $USER`
- Log out and back in after adding to group
- Verify udev rules applied: `udevadm info /dev/gpiochip0`

**UART device doesn't exist**:

- Check device tree overlay applied: `dtc -I fs /sys/firmware/devicetree/base | grep uart`
- Verify config.txt has `dtoverlay=uart4`
- Rebuild SD image if config.txt changed

**I2C "No such device"**:

- Check module loaded: `lsmod | grep i2c`
- Verify device tree: `cat /sys/firmware/devicetree/base/soc/i2c@7e804000/status`
- Check `hardware.raspberry-pi."4".i2c1.enable = true`

**Device tree overlay not applying**:

- Enable dtmerge: `hardware.raspberry-pi."4".apply-overlays-dtmerge.enable = true`
- Check for syntax errors in DTS
- Verify `hardware.deviceTree.filter` matches your Pi model

---

## See Also

- [NixOS on ARM/Raspberry Pi 4 - Official Wiki](https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_4)
- [nixos-hardware Raspberry Pi modules](https://github.com/NixOS/nixos-hardware/tree/master/raspberry-pi/4)
- [Raspberry Pi firmware overlays README](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README)
- [Raspberry Pi Device Tree Configuration](https://github.com/raspberrypi/documentation/blob/develop/documentation/asciidoc/computers/configuration/device-tree.adoc)
- [Device Tree Overlays - Bootlin](https://bootlin.com/blog/enabling-new-hardware-on-raspberry-pi-with-device-tree-overlays/)
