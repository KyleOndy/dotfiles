//! Hottest CPU/GPU die temperature, formatted for a tmux status bar.
//!
//! Mirrors the battery-draw contract: one short string on stdout, exit 1 and
//! print nothing when no sensor is available, so the status segment simply
//! disappears on hardware that cannot report (WSL, VMs, containers).

use std::process;

#[cfg(target_os = "macos")]
mod darwin;
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
use darwin::hottest;
#[cfg(target_os = "linux")]
use linux::hottest;

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn hottest() -> Result<f32, Box<dyn std::error::Error>> {
    Err("unsupported platform".into())
}

use tmux_status::{colors_enabled, styled, HOT, NORMAL, SEP, WARM};

// Apple Silicon idles in the 50s and throttles near 100. AMD Zen reports Tctl,
// which throttles at 95. One pair of thresholds is a rough fit for both.
const WARM_AT: f32 = 80.0;
const HOT_AT: f32 = 95.0;

fn main() {
    match hottest() {
        Ok(celsius) => print!("{}", format_temp(celsius, colors_enabled())),
        Err(_) => process::exit(1),
    }
}

fn color_for(celsius: f32) -> &'static str {
    if celsius >= HOT_AT {
        HOT
    } else if celsius >= WARM_AT {
        WARM
    } else {
        NORMAL
    }
}

fn format_temp(celsius: f32, color: bool) -> String {
    let body = format!("{}°C", celsius.round() as i64);
    if color {
        styled(color_for(celsius), &body)
    } else {
        format!("{body}{SEP}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_output_matches_battery_draw_shape() {
        assert_eq!(format_temp(72.4, false), "72°C \u{e0b3} ");
        assert_eq!(format_temp(72.6, false), "73°C \u{e0b3} ");
    }

    #[test]
    fn thresholds_pick_escalating_colors() {
        assert_eq!(color_for(45.0), NORMAL);
        assert_eq!(color_for(79.9), NORMAL);
        assert_eq!(color_for(80.0), WARM);
        assert_eq!(color_for(94.9), WARM);
        assert_eq!(color_for(95.0), HOT);
    }

    #[test]
    fn colored_output_restores_the_surrounding_style() {
        assert_eq!(
            format_temp(96.0, true),
            "#[fg=colour167]96°C#[fg=colour246] \u{e0b3} "
        );
        assert!(format_temp(50.0, true).ends_with("#[fg=colour246] \u{e0b3} "));
    }
}
