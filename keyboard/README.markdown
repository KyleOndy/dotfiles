# My keyboards

This project is designed for the Ergodox EZ which uses the [qmk](https://github.com/qmk/qmk_firmware) firmware.

## Goals

=======

This ergodox-ez is my first split keyboard.
My prior keyboard, a pok3r, is a 60%.

Due to the unfamiliar nature of this keyboard I fully expect this layout to be a long-term project.

There are _many_ layouts out there.
I have looked at some, but am trying to originally develop this keymap.

Due to my job, the majority of my time behind a keyboard are spent doing the following.

- Tap-dancing around vim
  - bash
  - terraform
  - powershell
  - python
  - clojure
  - markdown
  - technical documentation
- slinging arguments on the cli

## Templates

Here is a blank keymap to paste into `keymap.c` if I want to start over

```txt
 * ,--------------------------------------------------.           ,--------------------------------------------------.
 * |        |      |      |      |      |      |      |           |      |      |      |      |      |      |        |
 * |--------+------+------+------+------+-------------|           |------+------+------+------+------+------+--------|
 * |        |      |      |      |      |      |      |           |      |      |      |      |      |      |        |
 * |--------+------+------+------+------+------|      |           |      |------+------+------+------+------+--------|
 * |        |      |      |      |      |      |------|           |------|      |      |      |      |      |        |
 * |--------+------+------+------+------+------|      |           |      |------+------+------+------+------+--------|
 * |        |      |      |      |      |      |      |           |      |      |      |      |      |      |        |
 * `--------+------+------+------+------+-------------'           `-------------+------+------+------+------+--------'
 *   |      |      |      |      |      |                                       |      |      |      |      |      |
 *   `----------------------------------'                                       `----------------------------------'
 *                                        ,-------------.       ,---------------.
 *                                        |      |      |       |      |        |
 *                                 ,------|------|------|       |------+--------+------.
 *                                 |      |      |      |       |      |        |      |
 *                                 |      |      |------|       |------|        |      |
 *                                 |      |      |      |       |      |        |      |
 *                                 `--------------------'       `----------------------'
```

## Helpful links

- [Full list of QMK keycodes](https://beta.docs.qmk.fm/using-qmk/simple-keycodes/keycodes)
- [Home row mods](https://precondition.github.io/home-row-mods)
