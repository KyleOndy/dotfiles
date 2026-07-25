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

// tmux colours, matching the gruvbox palette already used in tmux.nix.
const NORMAL: &str = "colour246";
const WARM: &str = "colour214";
const HOT: &str = "colour167";

/// U+E0B3, the powerline thin separator, carried as a trailing suffix. Every
/// metric segment can collapse to nothing, so a separator written between the
/// segments in tmux.nix would outlive its segment and leave `│ │` behind.
const SEP: &str = " \u{e0b3} ";

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

fn colors_enabled() -> bool {
    std::env::var_os("NO_COLOR").is_none()
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

/// tmux re-expands the stdout of a `#()` job through its format parser, so
/// `#[fg=...]` here is honoured (tmux 3.6a, format.c `format_job_get`).
fn format_temp(celsius: f32, color: bool) -> String {
    let rounded = celsius.round() as i64;
    if color {
        format!(
            "#[fg={}]{}°C#[fg={}]{}",
            color_for(celsius),
            rounded,
            NORMAL,
            SEP
        )
    } else {
        format!("{rounded}°C{SEP}")
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
