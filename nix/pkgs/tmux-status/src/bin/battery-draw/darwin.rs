//! Battery charge and power from the AppleSmartBattery registry entry.

use tmux_status::{iokit, Res};

use crate::Charge;

pub fn sample() -> Res<Charge> {
    let battery = iokit::services("AppleSmartBattery")?
        .next()
        .ok_or("no AppleSmartBattery in the IORegistry")?;
    let read = |key: &str| {
        battery
            .int(key)
            .ok_or_else(|| format!("AppleSmartBattery has no {key}"))
    };
    charge(
        read("CurrentCapacity")?,
        read("MaxCapacity")?,
        read("Amperage")?,
        read("Voltage")?,
    )
}

/// Capacities are percent on Apple Silicon and mAh on Intel; only the ratio is
/// used. Amperage is signed mA, negative while the battery drains even when a
/// charger is attached and IsCharging is set. Voltage is mV.
fn charge(current: i64, max: i64, milliamps: i64, millivolts: i64) -> Res<Charge> {
    if max <= 0 {
        return Err(format!("AppleSmartBattery MaxCapacity is {max}").into());
    }
    Ok(Charge {
        percent: current as f64 * 100.0 / max as f64,
        watts: (milliamps * millivolts) as f64 / 1e6,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negative_amperage_is_draining_power() {
        let c = charge(98, 100, -1167, 12972).unwrap();
        assert_eq!(c.percent, 98.0);
        assert!((c.watts + 15.138).abs() < 0.001, "{}", c.watts);
    }

    #[test]
    fn intel_capacities_in_mah_still_give_a_percentage() {
        assert_eq!(charge(2500, 5000, 0, 12000).unwrap().percent, 50.0);
    }

    #[test]
    fn a_zero_max_capacity_is_an_error() {
        assert!(charge(50, 0, 0, 12000).is_err());
    }
}
