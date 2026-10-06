//! Battery charge and power from /sys/class/power_supply, summed across every
//! system battery.

use std::fs;
use std::path::Path;

use tmux_status::Res;

use crate::Charge;

pub fn sample() -> Res<Charge> {
    sample_in(Path::new("/sys/class/power_supply"))
}

fn sample_in(dir: &Path) -> Res<Charge> {
    let (mut now, mut full, mut watts) = (0.0, 0.0, 0.0);
    for entry in fs::read_dir(dir)?.flatten() {
        let supply = entry.path();
        // scope=Device marks a peripheral's battery, a mouse or a headset.
        if text(&supply, "type").as_deref() != Some("Battery")
            || text(&supply, "scope").as_deref() == Some("Device")
        {
            continue;
        }
        let Some((n, f)) = level(&supply) else {
            continue;
        };
        now += n;
        full += f;
        watts += power(&supply);
    }
    if full <= 0.0 {
        return Err(format!("no battery in {}", dir.display()).into());
    }
    Ok(Charge {
        percent: now * 100.0 / full,
        watts,
    })
}

fn text(supply: &Path, file: &str) -> Option<String> {
    fs::read_to_string(supply.join(file))
        .ok()
        .map(|s| s.trim().to_owned())
}

fn number(supply: &Path, file: &str) -> Option<f64> {
    text(supply, file)?.parse().ok()
}

/// Charge now and when full, in µWh, µAh or percent, whichever the driver
/// offers; only the ratio is used.
fn level(supply: &Path) -> Option<(f64, f64)> {
    let pair = |now, full| number(supply, now).zip(number(supply, full));
    pair("energy_now", "energy_full")
        .or_else(|| pair("charge_now", "charge_full"))
        .or_else(|| Some((number(supply, "capacity")?, 100.0)))
}

/// Watts into the battery, negative while it drains. Drivers disagree on the
/// sign: the sysfs ABI has current_now negative while discharging, and many
/// drivers report magnitudes only, so `status` decides the direction as well.
fn power(supply: &Path) -> f64 {
    let current = number(supply, "current_now");
    // power_now is µW; current_now (µA) times voltage_now (µV) is pW.
    let micro_watts = number(supply, "power_now")
        .or_else(|| Some(current? * number(supply, "voltage_now")? / 1e6))
        .unwrap_or(0.0);
    let watts = micro_watts.abs() / 1e6;
    let draining = text(supply, "status").as_deref() == Some("Discharging")
        || current.is_some_and(|c| c < 0.0);
    if draining {
        -watts
    } else {
        watts
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tree(test: &str, supplies: &[(&str, &[(&str, &str)])]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("battery-draw-{}-{test}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for (name, files) in supplies {
            let dir = root.join(name);
            fs::create_dir_all(&dir).unwrap();
            for (file, value) in *files {
                fs::write(dir.join(file), format!("{value}\n")).unwrap();
            }
        }
        root
    }

    #[test]
    fn unsigned_power_takes_its_direction_from_status() {
        let root = tree(
            "status",
            &[(
                "BAT0",
                &[
                    ("type", "Battery"),
                    ("status", "Discharging"),
                    ("energy_now", "30000000"),
                    ("energy_full", "60000000"),
                    ("power_now", "12500000"),
                ],
            )],
        );
        let c = sample_in(&root).unwrap();
        assert_eq!(c.percent, 50.0);
        assert_eq!(c.watts, -12.5);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn negative_current_drains_whatever_status_says() {
        let root = tree(
            "current",
            &[(
                "BAT0",
                &[
                    ("type", "Battery"),
                    ("status", "Charging"),
                    ("capacity", "40"),
                    ("current_now", "-1000000"),
                    ("voltage_now", "12000000"),
                ],
            )],
        );
        assert_eq!(sample_in(&root).unwrap().watts, -12.0);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn batteries_are_summed_and_peripherals_and_mains_ignored() {
        let root = tree(
            "sum",
            &[
                (
                    "BAT0",
                    &[
                        ("type", "Battery"),
                        ("energy_now", "10"),
                        ("energy_full", "40"),
                    ],
                ),
                (
                    "BAT1",
                    &[
                        ("type", "Battery"),
                        ("energy_now", "30"),
                        ("energy_full", "40"),
                    ],
                ),
                (
                    "hid-mouse",
                    &[("type", "Battery"), ("scope", "Device"), ("capacity", "5")],
                ),
                ("AC", &[("type", "Mains"), ("online", "1")]),
            ],
        );
        assert_eq!(sample_in(&root).unwrap().percent, 50.0);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn no_system_battery_is_an_error() {
        let root = tree("none", &[("AC", &[("type", "Mains")])]);
        assert!(sample_in(&root).is_err());
        fs::remove_dir_all(root).ok();
    }
}
