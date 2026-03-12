use battery::units::power::watt;
use battery::units::ratio::percent;
use battery::State;
use std::process;

fn main() {
    match calculate_power_draw() {
        Ok(output) => print!("{}", output),
        Err(_) => process::exit(1),
    }
}

fn calculate_power_draw() -> Result<String, Box<dyn std::error::Error>> {
    let manager = battery::Manager::new()?;
    let battery = manager.batteries()?.next().ok_or("no battery found")??;

    let capacity = battery.state_of_charge().get::<percent>().round() as i64;
    let is_charging = battery.state() == State::Charging;

    let power_display = {
        let watts = battery.energy_rate().get::<watt>();
        if watts > 0.0 {
            let prefix = if is_charging { "+" } else { "" };
            format!(" {}{:.1}W", prefix, watts)
        } else {
            String::new()
        }
    };

    Ok(format!("{}%{} ", capacity, power_display))
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_power_format_discharging() {
        let watts: f64 = 12.5;
        let prefix = "";
        let result = format!(" {}{:.1}W", prefix, watts);
        assert_eq!(result, " 12.5W");
    }

    #[test]
    fn test_power_format_charging() {
        let watts: f64 = 12.5;
        let prefix = "+";
        let result = format!(" {}{:.1}W", prefix, watts);
        assert_eq!(result, " +12.5W");
    }
}
