//! GPU utilization for the tmux status bar. On trex it tells a working model
//! server from a wedged one; on tiger it shows Jellyfin transcoding.
//!
//! Always rendered, idle included, so the segments to its left never move
//! when the GPU wakes up.

#[cfg(target_os = "macos")]
mod darwin;
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
use darwin::busy_percent;
#[cfg(target_os = "linux")]
use linux::busy_percent;

use tmux_status::{colors_enabled, emit, paint, rising};

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn busy_percent() -> tmux_status::Res<u8> {
    Err("unsupported platform".into())
}

const WARM_AT: u8 = 60;
const HOT_AT: u8 = 90;

fn main() {
    emit(busy_percent().map(|pct| format_gpu(pct, colors_enabled())));
}

/// Three columns for the number, which is what 100 needs. The label keeps it
/// from being read as a second battery percentage.
fn format_gpu(pct: u8, colored: bool) -> String {
    paint(
        &format!("gpu {pct:>3}%"),
        rising(pct, WARM_AT, HOT_AT),
        colored,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_a_labelled_right_aligned_percentage() {
        assert_eq!(format_gpu(0, false), "gpu   0% \u{e0b3} ");
        assert_eq!(format_gpu(82, false), "gpu  82% \u{e0b3} ");
        assert_eq!(format_gpu(100, false), "gpu 100% \u{e0b3} ");
    }

    #[test]
    fn width_is_constant_across_the_range() {
        let widths: Vec<usize> = [0, 7, 42, 99, 100]
            .iter()
            .map(|&p| format_gpu(p, false).chars().count())
            .collect();
        assert!(widths.windows(2).all(|w| w[0] == w[1]), "{widths:?}");
    }

    #[test]
    fn thresholds_pick_escalating_colors() {
        assert!(format_gpu(59, true).starts_with("#[fg=colour246]"));
        assert!(format_gpu(60, true).starts_with("#[fg=colour214]"));
        assert!(format_gpu(89, true).starts_with("#[fg=colour214]"));
        assert!(format_gpu(90, true).starts_with("#[fg=colour167]"));
    }
}
