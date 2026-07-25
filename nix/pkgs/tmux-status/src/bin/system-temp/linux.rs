//! CPU package temperature from hwmon sysfs.
//!
//! Every read here is an ordinary file read, so no caching is warranted.

use std::path::Path;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

/// hwmon chip names in preference order, paired with the label that identifies
/// the package sensor on that chip. An empty label means take the max of every
/// sensor the chip exposes.
const CHIPS: [(&str, &str); 6] = [
    ("k10temp", "Tctl"),          // AMD Zen
    ("zenpower", "Tdie"),         // AMD Zen, out-of-tree driver
    ("coretemp", "Package id 0"), // Intel
    ("cpu_thermal", ""),          // Raspberry Pi and most ARM SoCs
    ("soc_thermal", ""),
    ("acpitz", ""),
];

fn read_milli(path: &Path) -> Option<f32> {
    let raw = std::fs::read_to_string(path).ok()?;
    let milli: f32 = raw.trim().parse().ok()?;
    let c = milli / 1000.0;
    (c > 0.0 && c < 130.0).then_some(c)
}

fn chip_temp(dir: &Path, want_label: &str) -> Option<f32> {
    let mut best: Option<f32> = None;

    for entry in std::fs::read_dir(dir).ok()? {
        let path = entry.ok()?.path();
        let name = path.file_name()?.to_str()?.to_string();
        if !name.starts_with("temp") || !name.ends_with("_input") {
            continue;
        }

        let value = match read_milli(&path) {
            Some(v) => v,
            None => continue,
        };

        if !want_label.is_empty() {
            let label_path = path.with_file_name(name.replace("_input", "_label"));
            let label = std::fs::read_to_string(label_path).unwrap_or_default();
            // An exact label match is authoritative, so return immediately.
            if label.trim() == want_label {
                return Some(value);
            }
            continue;
        }

        best = Some(best.map_or(value, |b: f32| b.max(value)));
    }

    best
}

/// Hottest CPU package sensor, in celsius.
pub fn hottest() -> Res<f32> {
    for (chip, label) in CHIPS {
        for entry in std::fs::read_dir("/sys/class/hwmon")
            .into_iter()
            .flatten()
            .flatten()
        {
            let dir = entry.path();
            let name = std::fs::read_to_string(dir.join("name")).unwrap_or_default();
            if name.trim() != chip {
                continue;
            }
            if let Some(v) = chip_temp(&dir, label) {
                return Ok(v);
            }
        }
    }

    // Containers and VMs (WSL2 included) usually expose neither, and the caller
    // treats the error as "print nothing".
    read_milli(Path::new("/sys/class/thermal/thermal_zone0/temp"))
        .ok_or_else(|| "no usable thermal sensor".into())
}
