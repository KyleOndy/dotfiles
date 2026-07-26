//! GPU utilization, formatted for a tmux status bar.
//!
//! Answers one question the rest of the bar cannot: is the GPU actually
//! working, or has the model server wedged. On trex that is the difference
//! between waiting and restarting.
//!
//! Always rendered, idle included. Hiding `gpu 0%` saved eight columns, but it
//! shifted every segment to its left each time the GPU woke up, and a bar that
//! rearranges itself is harder to read at a glance than one carrying a zero.

use std::process;

#[cfg(target_os = "macos")]
mod darwin;
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
use darwin::busy_percent;
#[cfg(target_os = "linux")]
use linux::busy_percent;

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn busy_percent() -> Result<u8, Box<dyn std::error::Error>> {
    Err("unsupported platform".into())
}

use tmux_status::SEP;

fn main() {
    match busy_percent() {
        Ok(pct) => print!("{}", format_gpu(pct)),
        // Only an unreadable source collapses the segment, and that is a
        // property of the machine rather than of the moment: a box with no
        // amdgpu never shows this segment, instead of flickering it.
        Err(_) => process::exit(1),
    }
}

/// Uncoloured on purpose. A pegged GPU during inference is the machine doing
/// its job, so there is no threshold here that would mean trouble, and the
/// surrounding `#[fg=colour246]` from tmux.nix carries the style.
///
/// The number is right-aligned in three columns for the same reason the idle
/// case still renders: a segment that changes width drags everything left of it
/// along with it. Three is what 100% needs, so the width is fixed across the
/// whole range rather than only up to 99.
fn format_gpu(pct: u8) -> String {
    format!("gpu {pct:>3}%{SEP}")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An idle GPU holds its place in the bar rather than vacating it, so
    /// nothing to its left moves when work starts.
    #[test]
    fn idle_still_renders() {
        assert_eq!(format_gpu(0), "gpu   0% \u{e0b3} ");
        assert_eq!(format_gpu(4), "gpu   4% \u{e0b3} ");
    }

    #[test]
    fn busy_renders_a_labelled_percentage() {
        // The bar already shows a bare percentage for the battery, so this one
        // needs the label to not be read as a second battery reading.
        assert_eq!(format_gpu(5), "gpu   5% \u{e0b3} ");
        assert_eq!(format_gpu(82), "gpu  82% \u{e0b3} ");
        assert_eq!(format_gpu(100), "gpu 100% \u{e0b3} ");
    }

    /// The point of the padding: every reading occupies the same columns, so
    /// no segment to the left of this one moves when the GPU wakes up.
    #[test]
    fn width_is_constant_across_the_range() {
        let widths: Vec<usize> = [0, 7, 42, 99, 100]
            .iter()
            .map(|&p| format_gpu(p).chars().count())
            .collect();
        assert!(widths.windows(2).all(|w| w[0] == w[1]), "{widths:?}");
    }
}
