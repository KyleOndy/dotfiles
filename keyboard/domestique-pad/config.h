// Longest gap between the two presses that still reads as one chord. Raising it
// makes the chord easier to land at 200 watts and delays both single keys by
// the same amount, since QMK cannot emit either until it knows the other is not
// coming.
#define COMBO_TERM 60

// Both keys together open the out-of-band channel, and an utterance there can
// end the pi session. A brush across both while reaching for one must not reach
// that, so the chord is a hold rather than a press.
#define COMBO_MUST_HOLD_PER_COMBO
#define COMBO_HOLD_TERM 200
