//! Memory headroom from /proc/meminfo, plus the ZFS ARC where there is one.
//!
//! MemAvailable is the kernel's own estimate of what a new allocation can get
//! without swapping. OpenZFS reports the ARC as none of the reclaimable
//! categories that estimate counts, yet shrinks it to c_min under pressure, so
//! a ZFS host reads as nearly full without adding it back (htop 3.4.1,
//! linux/Platform.c, does the same).

use std::fs;

use tmux_status::Res;

use crate::Memory;

/// Every value in /proc/meminfo is labelled kB but is really KiB.
fn field(raw: &str, want: &str) -> Option<u64> {
    raw.lines()
        .find(|line| line.split(':').next() == Some(want))
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u64>().ok())
        .map(|kib| kib * 1024)
}

fn parse(raw: &str) -> Res<Memory> {
    // MemAvailable has been present since 3.14 (2014). The fallback is the
    // pre-3.14 approximation, kept for containers that synthesise a trimmed
    // meminfo; it overestimates, since not all page cache is reclaimable.
    let available = match field(raw, "MemAvailable") {
        Some(v) => v,
        None => {
            field(raw, "MemFree").ok_or("no MemAvailable or MemFree in /proc/meminfo")?
                + field(raw, "Buffers").unwrap_or(0)
                + field(raw, "Cached").unwrap_or(0)
        }
    };

    // Absent entirely on a kernel built without swap support.
    let swap_used = match (field(raw, "SwapTotal"), field(raw, "SwapFree")) {
        (Some(total), Some(free)) => total.saturating_sub(free),
        _ => 0,
    };

    Ok(Memory {
        available,
        swap_used,
    })
}

/// ARC bytes above c_min, in bytes. arcstats rows are `name type value`.
fn arc_reclaimable(arcstats: &str) -> u64 {
    let stat = |want: &str| {
        arcstats.lines().find_map(|line| {
            let mut cols = line.split_whitespace();
            if cols.next()? != want {
                return None;
            }
            cols.nth(1)?.parse::<u64>().ok()
        })
    };
    stat("size")
        .zip(stat("c_min"))
        .map_or(0, |(size, min)| size.saturating_sub(min))
}

pub fn sample() -> Res<Memory> {
    let mut mem = parse(&fs::read_to_string("/proc/meminfo")?)?;
    if let Ok(arcstats) = fs::read_to_string("/proc/spl/kstat/zfs/arcstats") {
        mem.available += arc_reclaimable(&arcstats);
    }
    Ok(mem)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\
MemTotal:       32791528 kB
MemFree:         1204380 kB
MemAvailable:   24518904 kB
Buffers:          312044 kB
Cached:         21903112 kB
SwapCached:        11284 kB
SwapTotal:       8388604 kB
SwapFree:        7917052 kB
";

    const ARCSTATS: &str = "\
13 1 0x01 147 39984 4128410093 1293815542862437
name                            type data
hits                            4    211294520
c_min                           4    2104641024
c_max                           4    33674264576
size                            4    9414533640
";

    fn without(label: &str) -> String {
        SAMPLE
            .lines()
            .filter(|l| !l.starts_with(label))
            .map(|l| format!("{l}\n"))
            .collect()
    }

    #[test]
    fn parses_kibibytes_into_bytes() {
        let mem = parse(SAMPLE).unwrap();
        assert_eq!(mem.available, 24518904 * 1024);
        assert_eq!(mem.swap_used, (8388604 - 7917052) * 1024);
    }

    /// SwapCached starts with "Swap" too, so a prefix match would pick the
    /// wrong line for SwapTotal depending on ordering.
    #[test]
    fn field_names_match_whole_labels_not_prefixes() {
        assert_eq!(field(SAMPLE, "Swap"), None);
        assert_eq!(field(SAMPLE, "Mem"), None);
        assert_eq!(field(SAMPLE, "SwapCached"), Some(11284 * 1024));
    }

    #[test]
    fn falls_back_when_memavailable_is_missing() {
        let mem = parse(&without("MemAvailable")).unwrap();
        assert_eq!(mem.available, (1204380 + 312044 + 21903112) * 1024);
    }

    #[test]
    fn a_swapless_kernel_reports_no_swap_rather_than_failing() {
        let raw = without("SwapTotal");
        let mem = parse(&raw).unwrap();
        assert_eq!(mem.swap_used, 0);
        assert_eq!(mem.available, 24518904 * 1024);
    }

    #[test]
    fn a_meminfo_with_nothing_usable_is_an_error() {
        assert!(parse("Committed_AS:  123 kB\n").is_err());
    }

    #[test]
    fn the_arc_above_its_floor_is_headroom() {
        assert_eq!(arc_reclaimable(ARCSTATS), 9414533640 - 2104641024);
    }

    #[test]
    fn an_arc_at_or_below_its_floor_or_unreadable_adds_nothing() {
        assert_eq!(arc_reclaimable("c_min 4 100\nsize 4 50\n"), 0);
        assert_eq!(arc_reclaimable("hits 4 1\n"), 0);
        assert_eq!(arc_reclaimable(""), 0);
    }
}
