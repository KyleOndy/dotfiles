//! Hottest CPU package or GPU die temperature from hwmon sysfs.

use std::fs;
use std::path::{Path, PathBuf};

use tmux_status::Res;

/// CPU hwmon chips in preference order, each with the label of its package
/// sensor. An empty label takes the max of every sensor on the chip.
const CPU_CHIPS: [(&str, &str); 6] = [
    ("k10temp", "Tctl"),          // AMD Zen
    ("zenpower", "Tdie"),         // AMD Zen, out-of-tree driver
    ("coretemp", "Package id 0"), // Intel
    ("cpu_thermal", ""),          // Raspberry Pi and most ARM SoCs
    ("soc_thermal", ""),
    ("acpitz", ""),
];

/// GPU hwmon chips. Every temperature they expose is a die, package or
/// memory reading, so each takes the max of all of them.
const GPU_CHIPS: [&str; 4] = ["i915", "xe", "amdgpu", "nouveau"];

pub fn hottest() -> Res<f32> {
    hottest_in(Path::new("/sys/class"))
}

/// `class` stands in for /sys/class.
fn hottest_in(class: &Path) -> Res<f32> {
    let chips: Vec<(String, PathBuf)> = fs::read_dir(class.join("hwmon"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| (read(&e.path().join("name")), e.path()))
        .collect();

    let cpu = CPU_CHIPS
        .iter()
        .find_map(|&(chip, label)| dirs(&chips, chip).find_map(|dir| chip_temp(dir, label)))
        .or_else(|| read_milli(&class.join("thermal/thermal_zone0/temp")));
    let gpu = GPU_CHIPS
        .iter()
        .flat_map(|&chip| dirs(&chips, chip).filter_map(|dir| chip_temp(dir, "")))
        .reduce(f32::max);

    cpu.into_iter()
        .chain(gpu)
        .reduce(f32::max)
        .ok_or_else(|| "no usable thermal sensor".into())
}

fn dirs<'a>(chips: &'a [(String, PathBuf)], chip: &'a str) -> impl Iterator<Item = &'a Path> + 'a {
    chips
        .iter()
        .filter(move |(name, _)| name == chip)
        .map(|(_, dir)| dir.as_path())
}

fn read(path: &Path) -> String {
    fs::read_to_string(path)
        .unwrap_or_default()
        .trim()
        .to_owned()
}

/// Millidegrees in, celsius out. Zero, negative and 130+ are drivers
/// reporting an absent sensor rather than a temperature.
fn read_milli(path: &Path) -> Option<f32> {
    let milli: f32 = read(path).parse().ok()?;
    let c = milli / 1000.0;
    (c > 0.0 && c < 130.0).then_some(c)
}

/// With a label, only the input carrying it is read: on coretemp each read
/// past the driver's one second cache is an IPI to that core.
fn chip_temp(dir: &Path, want_label: &str) -> Option<f32> {
    let mut best: Option<f32> = None;
    for entry in fs::read_dir(dir).ok()?.flatten() {
        let name = entry.file_name();
        let Some(stem) = name
            .to_str()
            .and_then(|n| n.strip_suffix("_input"))
            .filter(|s| s.starts_with("temp"))
        else {
            continue;
        };
        if !want_label.is_empty() {
            if read(&dir.join(format!("{stem}_label"))) == want_label {
                return read_milli(&entry.path());
            }
            continue;
        }
        if let Some(v) = read_milli(&entry.path()) {
            best = Some(best.map_or(v, |b| b.max(v)));
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    fn class(test: &str, chips: &[(&str, &[(&str, &str)])]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("system-temp-{}-{test}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for (i, (name, files)) in chips.iter().enumerate() {
            let dir = root.join(format!("hwmon/hwmon{i}"));
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("name"), format!("{name}\n")).unwrap();
            for (file, value) in *files {
                fs::write(dir.join(file), format!("{value}\n")).unwrap();
            }
        }
        root
    }

    #[test]
    fn a_hotter_gpu_wins_over_the_cpu_package() {
        let root = class(
            "gpu",
            &[
                ("nvme", &[("temp1_input", "70000")]),
                (
                    "k10temp",
                    &[("temp1_input", "40875"), ("temp1_label", "Tctl")],
                ),
                ("i915", &[("temp1_input", "48000")]),
            ],
        );
        assert_eq!(hottest_in(&root).unwrap(), 48.0);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn the_labelled_package_sensor_is_the_cpu_reading() {
        let root = class(
            "label",
            &[(
                "coretemp",
                &[
                    ("temp1_input", "41000"),
                    ("temp1_label", "Package id 0"),
                    ("temp2_input", "99000"),
                    ("temp2_label", "Core 0"),
                ],
            )],
        );
        assert_eq!(hottest_in(&root).unwrap(), 41.0);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn falls_back_to_the_first_thermal_zone() {
        let root = class("zone", &[]);
        let zone = root.join("thermal/thermal_zone0");
        fs::create_dir_all(&zone).unwrap();
        fs::write(zone.join("temp"), "62800\n").unwrap();
        assert_eq!(hottest_in(&root).unwrap(), 62.8);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn implausible_and_unreadable_inputs_are_skipped() {
        let root = class(
            "junk",
            &[(
                "amdgpu",
                &[
                    ("temp1_input", "0"),
                    ("temp2_input", "N/A"),
                    ("temp3_input", "51000"),
                ],
            )],
        );
        assert_eq!(hottest_in(&root).unwrap(), 51.0);
        assert!(hottest_in(&root.join("absent")).is_err());
        fs::remove_dir_all(root).ok();
    }
}
