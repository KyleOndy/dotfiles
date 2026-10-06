//! Hottest CPU or GPU die temperature, for the tmux status bar. Exits 1 where
//! no sensor is readable (WSL, VMs, containers), which collapses the segment.

#[cfg(target_os = "macos")]
mod darwin;
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
use darwin::hottest;
#[cfg(target_os = "linux")]
use linux::hottest;

use tmux_status::{colors_enabled, emit, paint, rising};

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn hottest() -> tmux_status::Res<f32> {
    Err("unsupported platform".into())
}

// Apple Silicon idles in the 50s and throttles near 100. On linux hot starts
// at tiger's limit: its Ryzen 7 5800X has a Tjmax of 90.
const WARM_AT: i64 = 80;
#[cfg(target_os = "macos")]
const HOT_AT: i64 = 95;
#[cfg(not(target_os = "macos"))]
const HOT_AT: i64 = 90;

fn main() {
    emit(hottest().map(|celsius| format_temp(celsius, colors_enabled())));
}

/// Three columns for the number, which is what 100 needs.
fn format_temp(celsius: f32, colored: bool) -> String {
    let shown = celsius.round() as i64;
    paint(
        &format!("{shown:>3}°C"),
        rising(shown, WARM_AT, HOT_AT),
        colored,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounds_to_whole_degrees_right_aligned() {
        assert_eq!(format_temp(72.4, false), " 72°C \u{e0b3} ");
        assert_eq!(format_temp(72.6, false), " 73°C \u{e0b3} ");
        assert_eq!(format_temp(101.0, false), "101°C \u{e0b3} ");
    }

    #[test]
    fn thresholds_follow_the_printed_figure() {
        assert!(format_temp(79.4, true).starts_with("#[fg=colour246]"));
        assert!(format_temp(79.6, true).starts_with("#[fg=colour214]"));
        assert!(format_temp(80.0, true).starts_with("#[fg=colour214]"));
        let hot = (HOT_AT as f32) - 0.4;
        assert!(format_temp(hot, true).starts_with("#[fg=colour167]"));
    }
}
