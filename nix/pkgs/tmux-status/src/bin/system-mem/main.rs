//! Memory headroom and swap in use, for the tmux status bar. Exits 1 when the
//! numbers are unavailable, which collapses the segment.
//!
//! Headroom rather than a used percentage: both kernels keep RAM full of
//! reclaimable cache when they can, so "percent used" idles high on a healthy
//! machine. Bytes left is the number that answers "will this fit".

#[cfg(target_os = "macos")]
mod darwin;
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
use darwin::sample;
#[cfg(target_os = "linux")]
use linux::sample;

use tmux_status::{colors_enabled, emit, falling, paint};

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn sample() -> tmux_status::Res<Memory> {
    Err("unsupported platform".into())
}

struct Memory {
    /// Bytes a new allocation can take without paging.
    available: u64,
    /// Bytes paged out: the compressor's swapfiles on darwin, zram or a swap
    /// device on linux.
    swap_used: u64,
}

const MIB: u64 = 1024 * 1024;
const GIB: u64 = 1024 * MIB;

// A box at 90% used is fine; a box with 500M left is one model load away from
// thrashing. Sized for the 32-64G machines this runs on.
const WARM_UNDER: u64 = 4 * GIB;
const HOT_UNDER: u64 = GIB;

fn main() {
    emit(sample().map(|mem| format_mem(&mem, colors_enabled())));
}

/// At most four columns (`812M`, `9.9G`, `128G`), and the byte count that text
/// stands for, so the colour can be picked from what is on screen.
fn shown(bytes: u64) -> (String, u64) {
    let mib = (bytes as f64 / MIB as f64).round() as u64;
    if mib < 1000 {
        return (format!("{mib}M"), mib * MIB);
    }
    let tenths = (bytes as f64 * 10.0 / GIB as f64).round() as u64;
    if tenths < 100 {
        return (
            format!("{}.{}G", tenths / 10, tenths % 10),
            tenths * GIB / 10,
        );
    }
    let gib = (bytes as f64 / GIB as f64).round() as u64;
    (format!("{gib}G"), gib * GIB)
}

/// Right-aligned in nine columns, two sizes of up to four and the `+`, so
/// the segments to its left hold still. Headroom alone picks the colour:
/// pages that went out to swap stay there until something touches them, so
/// one idle VM paged out days ago holds swap up on a machine with 15G to
/// spare, and a segment stuck warm for days teaches you to stop reading it.
fn format_mem(mem: &Memory, colored: bool) -> String {
    let (available, available_bytes) = shown(mem.available);
    let (swap, _) = shown(mem.swap_used);
    paint(
        &format!("{:>9}", format!("{available}+{swap}")),
        falling(available_bytes, WARM_UNDER, HOT_UNDER),
        colored,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use tmux_status::{HOT, NORMAL, WARM};

    fn mem(available: u64, swap_used: u64) -> Memory {
        Memory {
            available,
            swap_used,
        }
    }

    fn painted(available: u64) -> &'static str {
        let out = format_mem(&mem(available, 0), true);
        [HOT, WARM, NORMAL]
            .into_iter()
            .find(|c| out.starts_with(&format!("#[fg={c}]")))
            .unwrap()
    }

    #[test]
    fn sizes_take_at_most_four_columns() {
        assert_eq!(shown(0).0, "0M");
        assert_eq!(shown(812 * MIB).0, "812M");
        assert_eq!(shown(999 * MIB).0, "999M");
        assert_eq!(shown(1000 * MIB).0, "1.0G");
        assert_eq!(shown(GIB - 1).0, "1.0G");
        assert_eq!(shown(9 * GIB + 900 * MIB).0, "9.9G");
        assert_eq!(shown(9 * GIB + 1000 * MIB).0, "10G");
        assert_eq!(shown(128 * GIB).0, "128G");
    }

    #[test]
    fn width_is_constant_across_the_boundaries() {
        let widths: Vec<usize> = [
            (5 * MIB, 0),
            (9 * GIB + 900 * MIB, 5 * MIB),
            (10 * GIB, 1000 * MIB),
            (GIB - 1, 1023 * MIB),
            (128 * GIB, 965 * MIB),
        ]
        .iter()
        .map(|&(a, s)| format_mem(&mem(a, s), false).chars().count())
        .collect();
        assert!(widths.windows(2).all(|w| w[0] == w[1]), "{widths:?}");
        assert_eq!(format_mem(&mem(12 * GIB, 0), false), "   12G+0M \u{e0b3} ");
    }

    #[test]
    fn thresholds_follow_the_printed_figure() {
        assert_eq!(painted(24 * GIB), NORMAL);
        assert_eq!(painted(4 * GIB), NORMAL);
        // 3.96G prints as 4.0G and colours like it.
        assert_eq!(painted(4 * GIB - 40 * MIB), NORMAL);
        assert_eq!(painted(3 * GIB + 900 * MIB), WARM);
        assert_eq!(painted(GIB), WARM);
        assert_eq!(painted(999 * MIB), HOT);
    }

    #[test]
    fn swap_alone_never_colors_a_machine_that_has_headroom() {
        assert!(format_mem(&mem(24 * GIB, 8 * GIB), true).starts_with("#[fg=colour246]"));
        assert!(format_mem(&mem(0, 8 * GIB), true).starts_with("#[fg=colour167]"));
    }
}
