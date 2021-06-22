FROM ubuntu:focal

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      avr-libc \
      binutils-arm-none-eabi \
      binutils-avr \
      ca-certificates \
      dfu-util \
      gcc \
      gcc-arm-none-eabi \
      gcc-avr \
      git-core \
      libnewlib-arm-none-eabi \
      make \
      python3 \
      python3-pip \
      python3-setuptools \
      sudo \
      unzip \
      wget \
      zip \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /qmk_firmware

# build latest if not specified. Cache will not be busted when upstream is
# updated though as `master` is not a change to the Dockerfile
ARG QMK_RELEASE=master
# todo: pin to a known version of qmk_firmware?
RUN python3 -m pip install qmk
RUN git clone https://github.com/qmk/qmk_firmware.git . \
 && git checkout $QMK_RELEASE \
 && mkdir -p qmk_firmware/keyboards/ergodox_ez/keymaps/kyleondy \
 && make git-submodule

RUN util/qmk_install.sh
CMD make ergodox_ez:kyleondy \
 && cp ergodox_ez_kyleondy.hex keyboards/ergodox_ez/keymaps/kyleondy
