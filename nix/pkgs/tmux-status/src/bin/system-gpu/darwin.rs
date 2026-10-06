//! GPU utilization on darwin, from `Device Utilization %` in each
//! accelerator's `PerformanceStatistics` registry property. IOReport, where
//! macmon reads GPU residency, costs about 2.4s per process to subscribe to.
//!
//! The key is undocumented and reading it resets it: the value covers only the
//! time since the previous read by any process, and a read within about 2 ms
//! of another returns 0 at full load (measured on an M5 under a Metal compute
//! loop; the AGX driver is closed source). Two attached tmux clients refresh
//! in the same pass, so readers serialise on a lock around a cache file and
//! reuse any reading less than a second old.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, Write};
use std::time::{SystemTime, UNIX_EPOCH};

use tmux_status::{cache_file, iokit, Res};

const FRESH_MS: u128 = 1000;

pub fn busy_percent() -> Res<u8> {
    let Some(mut cache) = cache_file("gpu").and_then(|path| open_locked(&path)) else {
        return read_registry();
    };
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis();
    let mut text = String::new();
    cache.read_to_string(&mut text)?;
    if let Some(pct) = fresh(&text, now) {
        return Ok(pct);
    }
    let pct = read_registry()?;
    // Best effort: a failed write costs the next reader a fresh read, nothing more.
    let _ = cache
        .set_len(0)
        .and_then(|()| cache.rewind())
        .and_then(|()| write!(cache, "{now} {pct}"));
    Ok(pct)
}

/// The lock is released when the file closes.
fn open_locked(path: &std::path::Path) -> Option<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .ok()?;
    file.lock().ok()?;
    Some(file)
}

/// The cached reading, if it was taken less than `FRESH_MS` before `now_ms`.
/// The cache holds `<unix ms> <percent>`.
fn fresh(cache: &str, now_ms: u128) -> Option<u8> {
    let (at, pct) = cache.trim().split_once(' ')?;
    let age = now_ms.checked_sub(at.parse().ok()?)?;
    if age >= FRESH_MS {
        return None;
    }
    pct.parse().ok()
}

/// Busiest accelerator.
fn read_registry() -> Res<u8> {
    iokit::services("IOAccelerator")?
        .filter_map(|gpu| gpu.int_in("PerformanceStatistics", "Device Utilization %"))
        .max()
        .map(|pct| pct.clamp(0, 100) as u8)
        .ok_or_else(|| "no IOAccelerator reports Device Utilization %".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reading_is_reused_for_under_a_second() {
        assert_eq!(fresh("1000 42", 1000), Some(42));
        assert_eq!(fresh("1000 42", 1999), Some(42));
        assert_eq!(fresh("1000 42", 2000), None);
    }

    #[test]
    fn an_empty_garbled_or_future_cache_is_not_fresh() {
        assert_eq!(fresh("", 1000), None);
        assert_eq!(fresh("garbage", 1000), None);
        assert_eq!(fresh("1000 lots", 1000), None);
        assert_eq!(fresh("5000 42", 1000), None);
    }
}
