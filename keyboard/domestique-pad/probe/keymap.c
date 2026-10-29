// Not the pad. Every pin on the KB2040's headers is a key, and closing one to
// GND types its silkscreen label, to find where a wire actually landed. A pin
// already shorted to GND types its label once at plug-in. Two pins shorted to
// each other, as a switch whose common wire missed GND makes, type as a pair:
// "D6-D7".

#include QMK_KEYBOARD_H

static const char *const labels[MATRIX_COLS] = {
    "TX", "RX", "D2", "D3", "D4", "D5", "D6", "D7", "D8", "D9", "D10", "SCK", "MOSI", "MISO", "A0", "A1", "A2", "A3",
};

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    [0] = LAYOUT(KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO, KC_NO),
};

bool process_record_user(uint16_t keycode, keyrecord_t *record) {
    if (record->event.pressed) {
        send_string(labels[record->event.key.col]);
        send_string(" ");
    }
    return false;
}

// The matrix only sees a pin pulled to GND. Every 20 ms this drives each pin
// low in turn and reads the ones after it, so closed[i] bit j means pins i and
// j are shorted, i < j. Pins on GND are left out, or they would pair with
// everything. Each pin goes back to input-pullup before the matrix reads it.
void housekeeping_task_user(void) {
    static const pin_t pins[MATRIX_ROWS][MATRIX_COLS] = DIRECT_PINS;
    static uint32_t    closed[MATRIX_COLS];
    static uint16_t    last;

    if (timer_elapsed(last) < 20) return;
    last = timer_read();

    matrix_row_t grounded = matrix_get_row(0);
    for (uint8_t i = 0; i < MATRIX_COLS; i++) {
        uint32_t now = 0;
        if (!(grounded & (1UL << i))) {
            gpio_set_pin_output(pins[0][i]);
            gpio_write_pin_low(pins[0][i]);
            wait_us(10);
            for (uint8_t j = i + 1; j < MATRIX_COLS; j++) {
                if (!gpio_read_pin(pins[0][j])) now |= 1UL << j;
            }
            gpio_set_pin_input_high(pins[0][i]);
            wait_us(10);
            now &= ~grounded;
        }
        for (uint8_t j = i + 1; j < MATRIX_COLS; j++) {
            if ((now & ~closed[i]) & (1UL << j)) {
                send_string(labels[i]);
                send_string("-");
                send_string(labels[j]);
                send_string(" ");
            }
        }
        closed[i] = now;
    }
}
