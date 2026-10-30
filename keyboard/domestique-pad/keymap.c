// F16 and F17, not F14 and F15, which macOS binds to display brightness.
// The pad does nothing itself; see README.markdown for the other half.

#include QMK_KEYBOARD_H
#include "ws2812.h"

#define KC_PTT KC_F13
#define KC_REPLAY KC_F16
#define KC_OUTOFBAND KC_F17
#define KC_INTERRUPT KC_F18

// A press of key 1 shorter than this is a tap. The same 0.4 s below which
// domestique-listen.py drops a recording, so the tap that starts a double tap
// never reaches the agent.
#define TAP_MS 400
// From a tap's release to the second press, at most.
#define DOUBLE_TAP_MS 300

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    [0] = LAYOUT(KC_PTT, KC_REPLAY),
};

const uint16_t PROGMEM outofband_combo[] = {KC_PTT, KC_REPLAY, COMBO_END};

combo_t key_combos[] = {
    COMBO(outofband_combo, KC_OUTOFBAND),
};

bool get_combo_must_hold(uint16_t index, combo_t *combo) { return true; }

// The second press of a double tap on key 1 sends F18 in place of F13 and
// swallows its own release. The first tap has already gone out as F13, which
// hushes speech. Event times rather than timer_read(), because the combo holds
// a lone press back for COMBO_TERM before it gets here.
bool process_record_user(uint16_t keycode, keyrecord_t *record) {
    static uint16_t pressed_at, released_at;
    static bool     tapped, interrupting;

    if (keycode != KC_PTT) return true;
    if (record->event.pressed) {
        if (tapped && TIMER_DIFF_16(record->event.time, released_at) < DOUBLE_TAP_MS) {
            tapped       = false;
            interrupting = true;
            tap_code(KC_INTERRUPT);
            return false;
        }
        pressed_at = record->event.time;
        return true;
    }
    if (interrupting) {
        interrupting = false;
        return false;
    }
    tapped      = TIMER_DIFF_16(record->event.time, pressed_at) < TAP_MS;
    released_at = record->event.time;
    return true;
}

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
