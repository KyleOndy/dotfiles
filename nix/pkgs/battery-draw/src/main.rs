//! Battery charge and power draw, formatted for a tmux status bar.
//!
//! Mirrors the system-temp contract: one short string on stdout, exit 1 and
//! print nothing when there is no battery, so the segment disappears on
//! desktops and VMs rather than showing an error.
//!
//! Two behaviours the other segments do not have:
//!
//! Thresholds only apply while discharging. A machine at 15% and climbing is
//! not a problem, and painting it red teaches you to ignore the colour.
//!
//! The segment hides entirely once it is on AC and effectively full, following
//! system-gpu's precedent of getting out of the way when it has nothing to
//! say. A docked laptop reporting `100% +2.3W` forever is a column tax.

use battery::units::power::watt;
// Aliased because uom's units are unit structs: an unaliased `percent` in
// scope turns every `percent` binding into a unit-struct pattern match rather
// than a variable, which breaks the `Charge` field of the same name.
use battery::units::ratio::percent as percent_unit;
use battery::State;
use std::process;

/// What the bar needs, split from the hardware so the formatting is testable
/// without a battery present.
pub struct Charge {
    /// State of charge, already rounded to whole percent.
    pub percent: i64,
    /// Current energy rate. Zero when the battery is neither filling nor
    /// draining, which is what a full docked machine reports. f32 to match
    /// what the battery crate hands back.
    pub watts: f32,
    /// False whenever the machine is on AC, whatever the charger is doing.
    pub discharging: bool,
}

// tmux colours, matching the gruvbox palette already used in tmux.nix.
const NORMAL: &str = "colour246";
const WARM: &str = "colour214";
const HOT: &str = "colour167";

/// U+E0B3, the powerline thin separator, matching the one the clock segment
/// already puts between the date and the time. The left-pointing variants
/// (E0B2 solid, E0B3 thin) are the ones for the right of the bar; the window
/// tabs use the right-pointing E0B0/E0B1 for the same reason.
///
/// Carried as a trailing suffix rather than written between the segments in
/// tmux.nix on purpose: every metric segment can collapse to nothing, and a
/// separator owned by tmux.nix would survive its segment and leave `│ │`.
const SEP: &str = " \u{e0b3} ";

// Sized for "should I go find a charger": warm while there is still time to
// react, hot once it is the next thing you have to deal with.
const WARM_UNDER: i64 = 25;
const HOT_UNDER: i64 = 10;

/// Above this on AC the reading has stopped being news. Not 100%, because both
/// platforms sit at 96-99% for long stretches to spare the cell.
const FULL_AT: i64 = 95;

fn main() {
    match sample() {
        Ok(charge) => print!("{}", format_charge(&charge, colors_enabled())),
        Err(_) => process::exit(1),
    }
}

fn sample() -> Result<Charge, Box<dyn std::error::Error>> {
    let manager = battery::Manager::new()?;
    let battery = manager.batteries()?.next().ok_or("no battery found")??;

    Ok(Charge {
        percent: battery.state_of_charge().get::<percent_unit>().round() as i64,
        watts: battery.energy_rate().get::<watt>(),
        // Anything that is not actively draining means a charger is attached.
        // Darwin reports Full or Unknown while holding at a charge limit, and
        // treating those as "on battery" would flash the warning colours every
        // time the machine stopped topping up.
        discharging: battery.state() == State::Discharging,
    })
}

fn colors_enabled() -> bool {
    std::env::var_os("NO_COLOR").is_none()
}

/// Charge only reads as a warning when nothing is refilling it.
fn color_for(charge: &Charge) -> &'static str {
    if !charge.discharging {
        NORMAL
    } else if charge.percent < HOT_UNDER {
        HOT
    } else if charge.percent < WARM_UNDER {
        WARM
    } else {
        NORMAL
    }
}

/// Full and plugged in is the state that needs no reporting.
fn is_idle(charge: &Charge) -> bool {
    !charge.discharging && charge.percent >= FULL_AT
}

/// tmux re-expands the stdout of a `#()` job through its format parser, so
/// `#[fg=...]` here is honoured (tmux 3.6a, format.c `format_job_get`).
fn format_charge(charge: &Charge, color: bool) -> String {
    if is_idle(charge) {
        return String::new();
    }

    let mut body = format!("{}%", charge.percent);
    if charge.watts > 0.0 {
        // The sign is the only thing distinguishing filling from draining once
        // the percentage stops moving.
        let prefix = if charge.discharging { "" } else { "+" };
        body.push_str(&format!(" {}{:.1}W", prefix, charge.watts));
    }

    if color {
        format!("#[fg={}]{}#[fg={}]{}", color_for(charge), body, NORMAL, SEP)
    } else {
        format!("{body}{SEP}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn charge(percent: i64, watts: f32, discharging: bool) -> Charge {
        Charge {
            percent,
            watts,
            discharging,
        }
    }

    #[test]
    fn draining_omits_the_sign_and_charging_carries_it() {
        assert_eq!(
            format_charge(&charge(75, 12.5, true), false),
            "75% 12.5W \u{e0b3} "
        );
        assert_eq!(
            format_charge(&charge(75, 44.3, false), false),
            "75% +44.3W \u{e0b3} "
        );
    }

    #[test]
    fn a_resting_battery_shows_the_charge_alone() {
        assert_eq!(
            format_charge(&charge(80, 0.0, false), false),
            "80% \u{e0b3} "
        );
    }

    #[test]
    fn full_on_ac_collapses_the_whole_segment_separator_included() {
        assert_eq!(format_charge(&charge(100, 2.3, false), false), "");
        assert_eq!(format_charge(&charge(FULL_AT, 0.0, false), false), "");
        // One point below the cutoff it is still worth watching fill.
        assert_ne!(format_charge(&charge(FULL_AT - 1, 5.0, false), false), "");
    }

    /// Unplugging a full battery has to bring the segment straight back.
    #[test]
    fn a_full_battery_on_its_own_power_still_reports() {
        assert_eq!(
            format_charge(&charge(100, 8.0, true), false),
            "100% 8.0W \u{e0b3} "
        );
    }

    #[test]
    fn thresholds_pick_escalating_colors_while_draining() {
        assert_eq!(color_for(&charge(80, 8.0, true)), NORMAL);
        assert_eq!(color_for(&charge(WARM_UNDER, 8.0, true)), NORMAL);
        assert_eq!(color_for(&charge(WARM_UNDER - 1, 8.0, true)), WARM);
        assert_eq!(color_for(&charge(HOT_UNDER, 8.0, true)), WARM);
        assert_eq!(color_for(&charge(HOT_UNDER - 1, 8.0, true)), HOT);
    }

    /// The whole point of gating on discharge: plugging in at 4% is the fix,
    /// so the bar should stop shouting the moment you do it.
    #[test]
    fn charging_never_warns_however_low_it_is() {
        assert_eq!(color_for(&charge(4, 44.0, false)), NORMAL);
        assert_eq!(color_for(&charge(4, 44.0, true)), HOT);
    }

    #[test]
    fn colored_output_restores_the_surrounding_style() {
        assert_eq!(
            format_charge(&charge(5, 0.0, true), true),
            "#[fg=colour167]5%#[fg=colour246] \u{e0b3} "
        );
        assert!(format_charge(&charge(75, 0.0, true), true).ends_with("#[fg=colour246] \u{e0b3} "));
    }
}
