//! One-minute load average, formatted for a tmux status bar.
//!
//! Replaces a six process shell pipeline that ran on every status refresh:
//!
//! ```text
//! uptime | rev | cut -d':' -f1 | rev | xargs | sed -e 's/,//g'
//! ```
//!
//! That existed to paper over `uptime` printing a different shape on darwin
//! than on linux. getloadavg(3) is one call and is on both, so the whole
//! problem goes away and there is no per-OS module here.
//!
//! Shows the one minute figure only. The 5 and 15 minute values cost ten
//! columns on a bar that is nearly full, and they are rarely the reason
//! anyone looks.

use std::os::raw::c_int;
use std::process;

// stdlib.h: int getloadavg(double [], int);
unsafe extern "C" {
    fn getloadavg(loadavg: *mut f64, nelem: c_int) -> c_int;
}

use tmux_status::{colors_enabled, HOT, NORMAL, SEP, WARM};

/// A bare load figure means nothing without knowing the core count: 4.0 is
/// idle on trex and on fire on a two core VM. Thresholds are per core.
const WARM_PER_CORE: f64 = 1.0;
const HOT_PER_CORE: f64 = 2.0;

fn main() {
    match one_minute() {
        Ok(load) => print!("{}", format_load(load, cores(), colors_enabled())),
        Err(_) => process::exit(1),
    }
}

fn one_minute() -> Result<f64, Box<dyn std::error::Error>> {
    let mut out = [0f64; 3];
    // Returns the number of samples actually retrieved, or -1.
    let got = unsafe { getloadavg(out.as_mut_ptr(), 3) };
    if got < 1 {
        return Err("getloadavg reported no samples".into());
    }
    if !out[0].is_finite() || out[0] < 0.0 {
        return Err("getloadavg returned a nonsense value".into());
    }
    Ok(out[0])
}

/// Respects cgroup limits on linux, unlike a raw processor count, so a
/// container reports the cores it may actually use.
fn cores() -> f64 {
    std::thread::available_parallelism()
        .map(|n| n.get() as f64)
        .unwrap_or(1.0)
}

fn color_for(load: f64, cores: f64) -> &'static str {
    let per_core = load / cores;
    if per_core >= HOT_PER_CORE {
        HOT
    } else if per_core >= WARM_PER_CORE {
        WARM
    } else {
        NORMAL
    }
}

/// The brackets are what made this segment recognisable as load at a glance,
/// so they stay even though only one number is left inside them.
fn format_load(load: f64, cores: f64, color: bool) -> String {
    if color {
        format!(
            "#[fg={}][ {:.2} ]#[fg={}]{SEP}",
            color_for(load, cores),
            load,
            NORMAL
        )
    } else {
        format!("[ {load:.2} ]{SEP}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_two_decimals_inside_the_brackets() {
        assert_eq!(format_load(2.951, 10.0, false), format!("[ 2.95 ]{SEP}"));
        assert_eq!(format_load(0.0, 10.0, false), format!("[ 0.00 ]{SEP}"));
        assert_eq!(format_load(12.5, 10.0, false), format!("[ 12.50 ]{SEP}"));
    }

    /// The whole point of scaling by core count: the same figure is fine on a
    /// laptop and alarming on a small VM.
    #[test]
    fn thresholds_scale_with_the_core_count() {
        assert_eq!(color_for(4.0, 10.0), NORMAL);
        assert_eq!(color_for(4.0, 4.0), WARM);
        assert_eq!(color_for(4.0, 2.0), HOT);
    }

    #[test]
    fn thresholds_pick_escalating_colors() {
        assert_eq!(color_for(9.9, 10.0), NORMAL);
        assert_eq!(color_for(10.0, 10.0), WARM);
        assert_eq!(color_for(19.9, 10.0), WARM);
        assert_eq!(color_for(20.0, 10.0), HOT);
    }

    #[test]
    fn colored_output_restores_the_surrounding_style() {
        assert_eq!(
            format_load(30.0, 10.0, true),
            format!("#[fg=colour167][ 30.00 ]#[fg=colour246]{SEP}")
        );
        assert!(format_load(1.0, 10.0, true).ends_with(&format!("#[fg=colour246]{SEP}")));
    }

    #[test]
    fn the_machine_reports_a_plausible_load() {
        let load = one_minute().expect("getloadavg");
        assert!(load >= 0.0 && load < 10_000.0, "load was {load}");
        assert!(cores() >= 1.0);
    }
}
