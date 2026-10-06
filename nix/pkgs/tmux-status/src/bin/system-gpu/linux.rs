//! GPU utilization on Intel i915, from RC6 residency.
//!
//! i915 publishes no utilization figure, and its engine-busy counters are a
//! perf PMU that `perf_event_paranoid=2` closes to an unprivileged user.
//! `rc6_residency_ms` is world-readable: the milliseconds a GT has spent in
//! its idle power state. The share of a short window spent outside RC6 is the
//! share the GT was awake, which bounds busy from above and climbs with
//! transcoding.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use tmux_status::Res;

/// Long enough for the millisecond counter to resolve under half a percent,
/// short enough for a status job.
const WINDOW: Duration = Duration::from_millis(250);

pub fn busy_percent() -> Res<u8> {
    busy_in(Path::new("/sys/class/drm"))
}

fn busy_in(drm: &Path) -> Res<u8> {
    let before = residencies(drm);
    if before.is_empty() {
        return Err(format!("no GT under {} exposes rc6_residency_ms", drm.display()).into());
    }
    let start = Instant::now();
    std::thread::sleep(WINDOW);
    let after = residencies(drm);
    let elapsed_ms = start.elapsed().as_millis() as u64;

    before
        .iter()
        .filter_map(|(gt, idle_before)| Some(awake(*idle_before, *after.get(gt)?, elapsed_ms)))
        .max()
        .ok_or_else(|| "every GT vanished during the sample".into())
}

/// RC6 residency in ms for every GT with RC6 enabled. A GT with RC6 off never
/// accrues residency and would read as permanently busy.
fn residencies(drm: &Path) -> BTreeMap<PathBuf, u64> {
    let mut out = BTreeMap::new();
    let Ok(cards) = fs::read_dir(drm) else {
        return out;
    };
    // Connectors and render nodes have no gt directory and fall through.
    for card in cards.flatten() {
        let Ok(gts) = fs::read_dir(card.path().join("gt")) else {
            continue;
        };
        for gt in gts.flatten() {
            let dir = gt.path();
            if read_u64(&dir.join("rc6_enable")) == Some(0) {
                continue;
            }
            if let Some(ms) = read_u64(&dir.join("rc6_residency_ms")) {
                out.insert(dir, ms);
            }
        }
    }
    out
}

fn read_u64(path: &Path) -> Option<u64> {
    fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// Percent of `elapsed_ms` not spent in RC6, rounded.
fn awake(idle_before_ms: u64, idle_after_ms: u64, elapsed_ms: u64) -> u8 {
    let elapsed = elapsed_ms.max(1);
    let idle = idle_after_ms.saturating_sub(idle_before_ms).min(elapsed);
    (100 - (idle * 100 + elapsed / 2) / elapsed) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn awake_is_the_share_of_the_window_outside_rc6() {
        assert_eq!(awake(1000, 1250, 250), 0);
        assert_eq!(awake(1000, 1000, 250), 100);
        assert_eq!(awake(1000, 1195, 250), 22);
        // The counter can run a tick ahead of the clock.
        assert_eq!(awake(1000, 1260, 250), 0);
        // A counter that went backwards counts as no idle time.
        assert_eq!(awake(1000, 900, 250), 100);
    }

    #[test]
    fn reads_every_gt_with_rc6_on_and_skips_the_rest() {
        let drm = std::env::temp_dir().join(format!("system-gpu-{}", std::process::id()));
        let _ = fs::remove_dir_all(&drm);
        let gt = |card: &str, gt: &str, enable: &str, ms: &str| {
            let dir = drm.join(card).join("gt").join(gt);
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("rc6_enable"), format!("{enable}\n")).unwrap();
            fs::write(dir.join("rc6_residency_ms"), format!("{ms}\n")).unwrap();
        };
        gt("card1", "gt0", "1", "5000");
        gt("card2", "gt0", "0", "0");
        fs::create_dir_all(drm.join("card1-DP-1")).unwrap();
        fs::create_dir_all(drm.join("renderD128")).unwrap();

        let found = residencies(&drm);
        assert_eq!(found.len(), 1);
        assert_eq!(found.values().next(), Some(&5000));

        assert!(busy_in(&drm.join("absent")).is_err());
        fs::remove_dir_all(&drm).ok();
    }
}
