// F16 and F17, not F14 and F15, which macOS binds to display brightness.
// The pad does nothing itself; see README.markdown for the other half.

#include QMK_KEYBOARD_H
#include "ws2812.h"

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

void keyboard_post_init_user(void) {
    ws2812_init();
    ws2812_flush();
}

// The NeoPixel follows the switches themselves, ahead of combos and USB, so a
// press that leaves it dark is wiring and one that lights it but reaches no
// state file is the host. Key 1 is green, key 2 blue, both cyan.
void housekeeping_task_user(void) {
    static matrix_row_t last = 0;
    matrix_row_t        row  = matrix_get_row(0);
    if (row == last) return;
    last = row;
    ws2812_set_color(0, 0, (row & 1) ? 32 : 0, (row & 2) ? 32 : 0);
    ws2812_flush();
}
