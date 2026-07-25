//! GPU utilization, formatted for a tmux status bar.
//!
//! Answers one question the rest of the bar cannot: is the GPU actually
//! working, or has the model server wedged. On trex that is the difference
//! between waiting and restarting.
//!
//! Hidden while the GPU is idle. Zero is the common case, and a `gpu 0%` that
//! never leaves the bar is a column tax with no information in it. The segment
//! appears when something is running and gets out of the way otherwise.

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

/// Below this the GPU is doing window compositing, not work worth watching.
const FLOOR: u8 = 5;

/// U+E0B3, the powerline thin separator, carried as a trailing suffix. This
/// segment is the reason the separator lives here rather than between the
/// segments in tmux.nix: an idle GPU prints nothing, and a separator owned by
/// tmux.nix would stay behind and collide with the neighbouring one.
const SEP: &str = " \u{e0b3} ";

fn main() {
    match busy_percent() {
        // Idle is a successful reading with nothing to say, so it prints
        // nothing and still exits 0. Only an unreadable source is a failure.
        Ok(pct) => print!("{}", format_gpu(pct)),
        Err(_) => process::exit(1),
    }
}

/// Uncoloured on purpose. A pegged GPU during inference is the machine doing
/// its job, so there is no threshold here that would mean trouble, and the
/// surrounding `#[fg=colour246]` from tmux.nix carries the style.
fn format_gpu(pct: u8) -> String {
    if pct < FLOOR {
        String::new()
    } else {
        format!("gpu {pct}%{SEP}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The separator has to go with it. Left behind, it would sit against the
    /// separator of the segment before and read as a double rule.
    #[test]
    fn idle_renders_nothing_at_all() {
        assert_eq!(format_gpu(0), "");
        assert_eq!(format_gpu(4), "");
    }

    #[test]
    fn busy_renders_a_labelled_percentage() {
        // The bar already shows a bare percentage for the battery, so this one
        // needs the label to not be read as a second battery reading.
        assert_eq!(format_gpu(5), "gpu 5% \u{e0b3} ");
        assert_eq!(format_gpu(82), "gpu 82% \u{e0b3} ");
        assert_eq!(format_gpu(100), "gpu 100% \u{e0b3} ");
    }
}
