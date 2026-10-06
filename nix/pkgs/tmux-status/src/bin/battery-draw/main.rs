//! Battery charge and power draw for the tmux status bar. Exits 1 where there
//! is no battery, which collapses the segment on desktops and VMs.
//!
//! Thresholds only apply while the battery drains: a machine at 15% and
//! climbing is fine, and painting it red teaches you to ignore the colour.
//! Draining is read off the current, not the charger, because a 15 W charger
//! under load reports charging and still loses ground.

#[cfg(target_os = "macos")]
mod darwin;
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
use darwin::sample;
#[cfg(target_os = "linux")]
use linux::sample;

use tmux_status::{colors_enabled, emit, falling, paint, NORMAL};

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn sample() -> tmux_status::Res<Charge> {
    Err("unsupported platform".into())
}

struct Charge {
    /// Percent of full, unrounded.
    percent: f64,
    /// Watts into the battery, negative while it drains.
    watts: f64,
}

// Sized for "should I go find a charger": warm while there is still time to
// react, hot once it is the next thing you have to deal with.
const WARM_UNDER: i64 = 25;
const HOT_UNDER: i64 = 10;

fn main() {
    emit(sample().map(|charge| format_charge(&charge, colors_enabled())));
}

/// Eleven columns for anything under 100 W, so the segments to its left hold
/// still. Only filling takes a sign: once the percentage stops moving it is
/// the one thing telling the directions apart, and "+0.0W" would claim a
/// charge that is not happening.
fn format_charge(charge: &Charge, colored: bool) -> String {
    let percent = charge.percent.round() as i64;
    let watts = (charge.watts * 10.0).round() / 10.0;
    let sign = if watts > 0.0 { "+" } else { "" };
    let draw = format!("{sign}{:.1}W", watts.abs());
    let color = if watts < 0.0 {
        falling(percent, WARM_UNDER, HOT_UNDER)
    } else {
        NORMAL
    };
    paint(&format!("{percent:>3}% {draw:>6}"), color, colored)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tmux_status::{HOT, WARM};

    fn plain(percent: f64, watts: f64) -> String {
        format_charge(&Charge { percent, watts }, false)
    }

    fn color(percent: f64, watts: f64) -> &'static str {
        let painted = format_charge(&Charge { percent, watts }, true);
        [HOT, WARM, NORMAL]
            .into_iter()
            .find(|c| painted.starts_with(&format!("#[fg={c}]")))
            .unwrap()
    }

    #[test]
    fn draining_omits_the_sign_and_filling_carries_it() {
        assert_eq!(plain(75.0, -12.5), " 75%  12.5W \u{e0b3} ");
        assert_eq!(plain(75.0, 44.3), " 75% +44.3W \u{e0b3} ");
    }

    #[test]
    fn a_resting_battery_reports_zero_draw_unsigned() {
        assert_eq!(plain(80.0, 0.0), " 80%   0.0W \u{e0b3} ");
        assert_eq!(plain(80.0, -0.04), " 80%   0.0W \u{e0b3} ");
    }

    #[test]
    fn width_is_constant_under_a_hundred_watts() {
        let widths: Vec<usize> = [(5.0, 0.0), (100.0, 2.3), (42.0, -99.9), (8.0, 15.1)]
            .iter()
            .map(|&(p, w)| plain(p, w).chars().count())
            .collect();
        assert!(widths.windows(2).all(|w| w[0] == w[1]), "{widths:?}");
    }

    #[test]
    fn thresholds_follow_the_printed_percentage_while_draining() {
        assert_eq!(color(80.0, -8.0), NORMAL);
        assert_eq!(color(25.0, -8.0), NORMAL);
        assert_eq!(color(24.6, -8.0), NORMAL);
        assert_eq!(color(24.4, -8.0), WARM);
        assert_eq!(color(10.0, -8.0), WARM);
        assert_eq!(color(9.0, -8.0), HOT);
    }

    #[test]
    fn filling_never_warns_however_low_it_is() {
        assert_eq!(color(4.0, 44.0), NORMAL);
    }

    #[test]
    fn a_charger_that_cannot_keep_up_still_warns() {
        assert_eq!(plain(8.0, -15.1), "  8%  15.1W \u{e0b3} ");
        assert_eq!(color(8.0, -15.1), HOT);
    }

    #[test]
    fn colored_output_restores_the_surrounding_style() {
        assert_eq!(
            format_charge(
                &Charge {
                    percent: 5.0,
                    watts: -1.0
                },
                true
            ),
            "#[fg=colour167]  5%   1.0W#[fg=colour246] \u{e0b3} "
        );
    }
}
