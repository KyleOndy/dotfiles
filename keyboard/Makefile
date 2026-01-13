.PHONY: build flash clean

# Build the firmware
build:
	nix build ..#ergodox-firmware

# Flash the firmware to the keyboard
# Requires keyboard to be in bootloader mode (press reset button or QK_BOOT key)
flash: build
	teensy-loader-cli -mmcu=atmega32u4 -w ../result/ergodox_ez_base_kyleondy.hex -v

# Clean build artifacts
clean:
	rm -rf ../result
