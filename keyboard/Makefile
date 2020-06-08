DOCKER_IMAGE=ergodox_ez:kyleondy
QMK_RELEASE=0.9.7

.PHONY: build-docker
build-docker:
	docker build --build-arg QMK_RELEASE=$(QMK_RELEASE) -t $(DOCKER_IMAGE) .

.PHONY: flash
flash:
	sudo teensy-loader-cli -mmcu=atmega32u4 -w ergodox_ez_kyleondy.hex -v

ergodox_ez_kyleondy.hex: build-docker keymap.c
	docker run --rm -v $(shell pwd):/qmk_firmware/keyboards/ergodox_ez/keymaps/kyleondy/ $(DOCKER_IMAGE)
