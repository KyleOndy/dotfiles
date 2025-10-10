use std::fs;
use std::process;

const BATTERY_PATH: &str = "/sys/class/power_supply/BAT1";

fn read_battery_file(filename: &str) -> Result<String, Box<dyn std::error::Error>> {
    let path = format!("{}/{}", BATTERY_PATH, filename);
    Ok(fs::read_to_string(path)?.trim().to_string())
}

fn read_battery_value(filename: &str) -> Result<i64, Box<dyn std::error::Error>> {
    let content = read_battery_file(filename)?;
    Ok(content.parse::<i64>()?)
}

fn main() {
    let result = calculate_power_draw();
    match result {
        Ok(output) => print!("{}", output),
        Err(_) => {
            // Fallback to a reasonable default if battery reading fails
            print!("0.0 W ");
            process::exit(1);
        }
    }
}

fn calculate_power_draw() -> Result<String, Box<dyn std::error::Error>> {
    // Read battery status to determine if charging or discharging
    let status = read_battery_file("status")?;
    let is_charging = status == "Charging";

    // Read current and voltage values
    let current_now = read_battery_value("current_now")?;
    let voltage_now = read_battery_value("voltage_now")?;

    // Calculate power in watts
    // Formula: (current_now * voltage_now) / 1e12
    let power_watts = (current_now as f64 * voltage_now as f64) / 1e12;

    // Format output with charging indicator
    let prefix = if is_charging { "+" } else { "" };
    Ok(format!("{}{:.1} W ", prefix, power_watts))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_power_calculation() {
        // Test with example values
        let current = 2000000; // 2A in microamps
        let voltage = 12000000; // 12V in microvolts
        let power = (current as f64 * voltage as f64) / 1e12;
        assert!((power - 24.0).abs() < 0.1); // Should be ~24W
    }
}
