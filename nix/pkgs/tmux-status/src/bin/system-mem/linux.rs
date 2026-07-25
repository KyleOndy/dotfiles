//! Memory headroom from /proc/meminfo.
//!
//! MemAvailable is the kernel's own estimate of what a new allocation can get
//! without swapping, accounting for the reclaimable share of page cache and
//! slab. That is exactly the question the bar asks, so there is nothing to
//! compute here beyond a unit conversion.

use crate::Memory;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

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

pub fn sample() -> Res<Memory> {
    parse(&std::fs::read_to_string("/proc/meminfo")?)
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
}
