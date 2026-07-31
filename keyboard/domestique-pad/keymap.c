// F16 and F17, not F14 and F15, which macOS binds to display brightness.
// The pad does nothing itself; see README.markdown for the other half.

#include QMK_KEYBOARD_H

#define KC_PTT KC_F13
#define KC_REPLAY KC_F16
#define KC_OUTOFBAND KC_F17

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    [0] = LAYOUT(KC_PTT, KC_REPLAY),
};

const uint16_t PROGMEM outofband_combo[] = {KC_PTT, KC_REPLAY, COMBO_END};

combo_t key_combos[] = {
    COMBO(outofband_combo, KC_OUTOFBAND),
};

bool get_combo_must_hold(uint16_t index, combo_t *combo) { return true; }
