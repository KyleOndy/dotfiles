//! GPU utilization from sysfs.
//!
//! amdgpu publishes `gpu_busy_percent` per card and that is the whole job.
//! i915 has no equivalent, and nvidia needs nvidia-smi, which costs more than
//! the rest of the status bar put together. Both of those report nothing and
//! the segment collapses, which is the right answer for a headless box anyway.

use std::path::Path;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

fn read_percent(path: &Path) -> Option<u8> {
    let raw = std::fs::read_to_string(path).ok()?;
    let pct: u16 = raw.trim().parse().ok()?;
    (pct <= 100).then_some(pct as u8)
}

/// Busiest card, as a percentage.
pub fn busy_percent() -> Res<u8> {
    let mut best: Option<u8> = None;

    // /sys/class/drm holds connectors and render nodes alongside the cards, so
    // rather than pattern match the names just try the path on each and let
    // the misses fall through.
    for entry in std::fs::read_dir("/sys/class/drm")?.flatten() {
        let path = entry.path().join("device/gpu_busy_percent");
        if let Some(pct) = read_percent(&path) {
            best = Some(best.map_or(pct, |b: u8| b.max(pct)));
        }
    }

    best.ok_or_else(|| "no drm device exposes gpu_busy_percent".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_percentage_and_rejects_nonsense() {
        let dir = std::env::temp_dir().join("system-gpu-test");
        std::fs::create_dir_all(&dir).unwrap();

        let good = dir.join("good");
        std::fs::write(&good, "42\n").unwrap();
        assert_eq!(read_percent(&good), Some(42));

        // amdgpu has been seen to report a bare 0 with no newline.
        let bare = dir.join("bare");
        std::fs::write(&bare, "0").unwrap();
        assert_eq!(read_percent(&bare), Some(0));

        let silly = dir.join("silly");
        std::fs::write(&silly, "9999\n").unwrap();
        assert_eq!(read_percent(&silly), None);

        let words = dir.join("words");
        std::fs::write(&words, "N/A\n").unwrap();
        assert_eq!(read_percent(&words), None);

        assert_eq!(read_percent(&dir.join("absent")), None);
        std::fs::remove_dir_all(&dir).ok();
    }
}
