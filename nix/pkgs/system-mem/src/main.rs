//! Memory headroom, formatted for a tmux status bar.
//!
//! Mirrors the system-temp contract: one short string on stdout, exit 1 and
//! print nothing when the numbers are unavailable, so the status segment
//! disappears rather than showing an error.
//!
//! Reports headroom rather than a used percentage on purpose. Both kernels
//! keep RAM full of reclaimable cache when they can, so "percent used" idles
//! high on a perfectly healthy machine and never moves enough to be worth
//! reading. Bytes left is the number that answers "will this fit".

use std::process;

#[cfg(target_os = "macos")]
mod darwin;
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
use darwin::sample;
#[cfg(target_os = "linux")]
use linux::sample;

/// What the bar needs: how much more can be allocated, and whether the machine
/// has already started paying for overcommit.
pub struct Memory {
    /// Bytes a new allocation can take without paging.
    pub available: u64,
    /// Bytes currently paged out. Compressed swap on darwin, zram or a real
    /// swap device on linux.
    pub swap_used: u64,
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn sample() -> Result<Memory, Box<dyn std::error::Error>> {
    Err("unsupported platform".into())
}

// tmux colours, matching the gruvbox palette already used in tmux.nix.
const NORMAL: &str = "colour246";
const WARM: &str = "colour214";
const HOT: &str = "colour167";

const MIB: u64 = 1024 * 1024;
const GIB: u64 = 1024 * MIB;

// Thresholds are on headroom, not usage. A box sitting at 90% used is fine; a
// box with 500 MB left is one model load away from thrashing. Sized for the
// 32-64 GB machines this runs on.
const WARM_UNDER: u64 = 4 * GIB;
const HOT_UNDER: u64 = 1 * GIB;

// The darwin compressor and zram on the Pi both page a little during normal
// operation, so a bare "swap is nonzero" test would pin the suffix on forever.
// Only surface swap once it is past incidental.
const SWAP_FLOOR: u64 = 256 * MIB;

fn main() {
    match sample() {
        Ok(mem) => print!("{}", format_mem(&mem, colors_enabled())),
        Err(_) => process::exit(1),
    }
}

fn colors_enabled() -> bool {
    std::env::var_os("NO_COLOR").is_none()
}

fn color_for(mem: &Memory) -> &'static str {
    if mem.available < HOT_UNDER {
        HOT
    } else if mem.available < WARM_UNDER || mem.swap_used >= SWAP_FLOOR {
        WARM
    } else {
        NORMAL
    }
}

/// Three characters plus a unit, so the segment does not shove the rest of the
/// bar sideways every time the number crosses a power of ten.
fn format_bytes(bytes: u64) -> String {
    let gib = bytes as f64 / GIB as f64;
    if gib >= 1.0 {
        let one_decimal = format!("{gib:.1}");
        // 9.9G keeps the decimal, 10.0G does not: both render as 4 columns.
        if one_decimal.len() > 3 {
            format!("{}G", gib.round() as u64)
        } else {
            format!("{one_decimal}G")
        }
    } else {
        format!("{}M", (bytes as f64 / MIB as f64).round() as u64)
    }
}

/// tmux re-expands the stdout of a `#()` job through its format parser, so
/// `#[fg=...]` here is honoured (tmux 3.6a, format.c `format_job_get`).
fn format_mem(mem: &Memory, color: bool) -> String {
    let mut body = format_bytes(mem.available);
    if mem.swap_used >= SWAP_FLOOR {
        body.push('+');
        body.push_str(&format_bytes(mem.swap_used));
    }

    if color {
        format!("#[fg={}]{}#[fg={}] ", color_for(mem), body, NORMAL)
    } else {
        format!("{body} ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mem(available: u64, swap_used: u64) -> Memory {
        Memory {
            available,
            swap_used,
        }
    }

    #[test]
    fn sizes_stay_four_columns_wide() {
        assert_eq!(format_bytes(24 * GIB), "24G");
        assert_eq!(format_bytes(9 * GIB + 900 * MIB), "9.9G");
        assert_eq!(format_bytes(GIB), "1.0G");
        assert_eq!(format_bytes(812 * MIB), "812M");
        assert_eq!(format_bytes(0), "0M");
    }

    #[test]
    fn ten_gibibytes_drops_the_decimal_instead_of_rendering_ten_point_zero() {
        assert_eq!(format_bytes(10 * GIB), "10G");
        // Rounds up across the boundary rather than printing "10.0G".
        assert_eq!(format_bytes(9 * GIB + 1000 * MIB), "10G");
    }

    #[test]
    fn swap_is_hidden_until_it_is_worth_reading() {
        assert_eq!(format_mem(&mem(12 * GIB, 0), false), "12G ");
        assert_eq!(format_mem(&mem(12 * GIB, 200 * MIB), false), "12G ");
        assert_eq!(format_mem(&mem(12 * GIB, 460 * MIB), false), "12G+460M ");
    }

    #[test]
    fn thresholds_pick_escalating_colors() {
        assert_eq!(color_for(&mem(24 * GIB, 0)), NORMAL);
        assert_eq!(color_for(&mem(4 * GIB, 0)), NORMAL);
        assert_eq!(color_for(&mem(4 * GIB - 1, 0)), WARM);
        assert_eq!(color_for(&mem(GIB, 0)), WARM);
        assert_eq!(color_for(&mem(GIB - 1, 0)), HOT);
    }

    #[test]
    fn swap_past_the_floor_warms_an_otherwise_healthy_machine() {
        assert_eq!(color_for(&mem(24 * GIB, SWAP_FLOOR)), WARM);
        assert_eq!(color_for(&mem(24 * GIB, SWAP_FLOOR - 1)), NORMAL);
        // Headroom still wins when both would fire.
        assert_eq!(color_for(&mem(0, 8 * GIB)), HOT);
    }

    #[test]
    fn colored_output_restores_the_surrounding_style() {
        assert_eq!(
            format_mem(&mem(512 * MIB, 0), true),
            "#[fg=colour167]512M#[fg=colour246] "
        );
        assert!(format_mem(&mem(24 * GIB, 0), true).ends_with("#[fg=colour246] "));
    }
}
