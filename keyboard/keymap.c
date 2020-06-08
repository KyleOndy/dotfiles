#include QMK_KEYBOARD_H

enum layers {
    BASE, // default layer
    FUNC, // funnctions
};

enum custom_keycodes {
#ifdef ORYX_CONFIGURATOR
  VRSN = EZ_SAFE_RANGE,
#else
  VRSN = SAFE_RANGE,
#endif
  RGB_SLD
};

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
/* Keymap 0: Basic layer
 *
 * ,--------------------------------------------------.           ,--------------------------------------------------.
 * |   `    |   1  |   2  |   3  |   4  |   5  |  -   |           |  +   |   6  |   7  |   8  |   9  |   0  |        |
 * |--------+------+------+------+------+-------------|           |------+------+------+------+------+------+--------|
 * | Tab    |   Q  |   W  |   E  |   R  |   T  |  [   |           |   ]  |   Y  |   U  |   I  |   O  |   P  |   \    |
 * |--------+------+------+------+------+------|      |           |      |------+------+------+------+------+--------|
 * | MO(1)  |   A  |   S  |   D  |   F* |   G  |------|           |------|   H  |   J* |   K  |   L  |   ;  |   '    |
 * |--------+------+------+------+------+------|  ,   |           |  .   |------+------+------+------+------+--------|
 * |        |   Z  |   X  |   C  |   V  |   B  |      |           |      |   N  |   M  |      |      |      |   /    |
 * `--------+------+------+------+------+-------------'           `-------------+------+------+------+------+--------'
 *   | CTRL |  Alt |      | LGui |LSft(()|                                       |RSft())|Ctrl|      |  Alt | Ctrl   |
 *   `-----------------------------------'                                       `-----------------------------------'
 *                                        ,-------------.       ,--------------.
 *                                        | BSpc | Del  |       | Del  |  BSpc |
 *                                 ,------|------|------|       |------+--------+------.
 *                                 |      |      |      |       |      |        |      |
 *                                 | Space|Enter |------|       |------| Enter  |Space |
 *                                 |      |      | Alt  |       | Ctrl |        |      |
 *                                 `--------------------'       `----------------------'
 */
[BASE] = LAYOUT_ergodox_pretty(
  // left hand                                                        // right hand
  KC_GRV,   KC_1,     KC_2,   KC_3,     KC_4,   KC_5,   KC_MINS,      KC_PLUS,  KC_6,   KC_7,   KC_8,     KC_9,     KC_0,     KC_NO,
  KC_TAB,   KC_Q,     KC_W,   KC_E,     KC_R,   KC_T,   KC_LBRC,      KC_RBRC,  KC_Y,   KC_U,   KC_I,     KC_O,     KC_P,     KC_BSLS,
  MO(1),    KC_A,     KC_S,   KC_D,     KC_F,   KC_G,                           KC_H,   KC_J,   KC_K,     KC_L,     KC_SCLN,  KC_QUOT,
  KC_NO,    KC_Z,     KC_X,   KC_C,     KC_V,   KC_B,   KC_COMM,      KC_DOT,   KC_N,   KC_M,   KC_COMM,  KC_DOT,   KC_NO,    KC_SLSH,
  KC_LCTL,  KC_LALT,  KC_NO,  KC_LGUI,  KC_LSPO,                                       KC_RSPC, KC_RCTL,  KC_NO,    KC_RALT,  KC_RCTL,

                                                KC_BSPC, KC_DEL,      KC_DEL, KC_BSPC,
                                                          KC_NO,      KC_NO,
                                      KC_SPC,   KC_ENT,   KC_LALT,    KC_RCTL, KC_ENT, KC_SPC

),
/* Keymap 1: Symbol Layer
 *
 * ,---------------------------------------------------.           ,--------------------------------------------------.
 * | Ecsape  |  F1  |  F2  |  F3  |  F4  |  F5  |     |           |      |  F6  |  F7  |  F8  |  F9  |  F10 |   F11  |
 * |---------+------+------+------+------+------+------|           |------+------+------+------+------+------+--------|
 * |         | Vol+ | Mute | NTrk | Brt+ |      |      |           |      |      |      |      |      |PrtSc |   F12  |
 * |---------+------+------+------+------+------|      |           |      |------+------+------+------+------+--------|
 * |  TRANS  | Vol- | Play | PTrk | Brt- |      |------|           |------| Left | Down |  Up  | Right|      |        |
 * |---------+------+------+------+------+------|      |           |      |------+------+------+------+------+--------|
 * |         |      |      |      |      |      |      |           |      |      | PgDwn| PgUp |      |      |        |
 * `---------+------+------+------+------+-------------'           `-------------+------+------+------+------+--------'
 *   | Reset |      |      |      |      |                                       |      |      |      |      |      |
 *   `-----------------------------------'                                       `----------------------------------'
 *                                        ,-------------.       ,-------------.
 *                                        |      |      |       |      |      |
 *                                 ,------|------|------|       |------+------+------.
 *                                 |      |      |      |       |      |      |      |
 *                                 | BKSPC| Del  |------|       |------| Del  | BKSPC|
 *                                 |      |      |      |       |      |      |      |
 *                                 `--------------------'       `--------------------'
 */
[FUNC] = LAYOUT_ergodox_pretty(
  // left hand
  KC_ESC,    KC_F1,   KC_F2,   KC_F3,   KC_F4,   KC_F5,  KC_TRNS,    KC_TRNS, KC_F6,   KC_F7,   KC_F8,    KC_F9,    KC_F10,  KC_F11,
  KC_TRNS, KC_VOLU, KC_MUTE,   KC_MNXT, KC_BRIU, KC_TRNS, KC_TRNS,   KC_TRNS, KC_TRNS, KC_TRNS, KC_TRNS,  KC_TRNS,  KC_PSCR, KC_F12,
  KC_TRNS, KC_VOLD, KC_MPLY,  KC_MPRV, KC_BRID, KC_TRNS,                     KC_LEFT, KC_DOWN, KC_UP,    KC_RIGHT, KC_TRNS, KC_TRNS,
  KC_TRNS, KC_TRNS, KC_TRNS, KC_TRNS, KC_TRNS, KC_TRNS, KC_TRNS,     KC_TRNS, KC_TRNS, KC_PGDN, KC_PGUP,  KC_TRNS,  KC_TRNS, KC_TRNS,
  RESET,   KC_TRNS, KC_TRNS, KC_TRNS, KC_TRNS,                                         KC_TRNS, KC_TRNS,  KC_TRNS,  KC_TRNS, KC_TRNS,
                                               KC_TRNS, KC_TRNS,     KC_TRNS, KC_TRNS,
                                                        KC_TRNS,     KC_TRNS,
                                      KC_BSPC, KC_DEL,  KC_TRNS,     KC_TRNS, KC_DEL,  KC_BSPC
),
};
