//! One-minute load average for the tmux status bar. getloadavg(3) is the same
//! call on darwin and linux, so there is no per-OS module.
//!
//! Shows the one minute figure only. The 5 and 15 minute values cost ten
//! columns on a bar that is nearly full, and they are rarely the reason
//! anyone looks.

use std::os::raw::{c_int, c_long};

use tmux_status::{colors_enabled, emit, paint, rising, Res};

// unistd.h. glibc and musl agree on 84 for every linux architecture.
#[cfg(target_os = "macos")]
const SC_NPROCESSORS_ONLN: c_int = 58;
#[cfg(not(target_os = "macos"))]
const SC_NPROCESSORS_ONLN: c_int = 84;

unsafe extern "C" {
    // Returns the number of samples written, or -1.
    fn getloadavg(loadavg: *mut f64, nelem: c_int) -> c_int;
    fn sysconf(name: c_int) -> c_long;
}

/// A bare load figure means nothing without the core count: 4.0 is idle on
/// trex and on fire on a two core VM. Thresholds are per core.
const WARM_PER_CORE: f64 = 1.0;
const HOT_PER_CORE: f64 = 2.0;

fn main() {
    emit(one_minute().map(|load| format_load(load, cores(), colors_enabled())));
}

fn one_minute() -> Res<f64> {
    let mut out = [0f64; 3];
    let got = unsafe { getloadavg(out.as_mut_ptr(), 3) };
    if got < 1 || !out[0].is_finite() || out[0] < 0.0 {
        return Err(format!("getloadavg returned {got} samples, first {}", out[0]).into());
    }
    Ok(out[0])
}

/// Online CPUs, deliberately not `available_parallelism`: that applies cgroup
/// quotas and affinity on linux, while the load average is machine-wide, so
/// one divided by the other would misread a container.
fn cores() -> f64 {
    let n = unsafe { sysconf(SC_NPROCESSORS_ONLN) };
    if n >= 1 {
        n as f64
    } else {
        1.0
    }
}

/// Nine columns up to 99.99. The brackets are what make it read as load at
/// a glance.
fn format_load(load: f64, cores: f64, colored: bool) -> String {
    let shown = (load * 100.0).round() / 100.0;
    paint(
        &format!("[ {shown:>5.2} ]"),
        rising(shown / cores, WARM_PER_CORE, HOT_PER_CORE),
        colored,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use tmux_status::{HOT, NORMAL, WARM};

    fn painted(load: f64, cores: f64) -> &'static str {
        let out = format_load(load, cores, true);
        [HOT, WARM, NORMAL]
            .into_iter()
            .find(|c| out.starts_with(&format!("#[fg={c}]")))
            .unwrap()
    }

    #[test]
    fn renders_two_decimals_right_aligned_inside_the_brackets() {
        assert_eq!(format_load(2.951, 10.0, false), "[  2.95 ] \u{e0b3} ");
        assert_eq!(format_load(12.5, 10.0, false), "[ 12.50 ] \u{e0b3} ");
    }

    #[test]
    fn width_is_constant_below_a_hundred() {
        let widths: Vec<usize> = [0.0, 9.99, 10.0, 99.99]
            .iter()
            .map(|&l| format_load(l, 10.0, false).chars().count())
            .collect();
        assert!(widths.windows(2).all(|w| w[0] == w[1]), "{widths:?}");
    }

    #[test]
    fn thresholds_scale_with_the_core_count() {
        assert_eq!(painted(4.0, 10.0), NORMAL);
        assert_eq!(painted(4.0, 4.0), WARM);
        assert_eq!(painted(4.0, 2.0), HOT);
        assert_eq!(painted(9.99, 10.0), NORMAL);
        assert_eq!(painted(10.0, 10.0), WARM);
        assert_eq!(painted(20.0, 10.0), HOT);
    }

    /// 20472/2048, a value the kernel's 1/2048 fixed point can produce, prints
    /// as 10.00 and must colour like it.
    #[test]
    fn the_color_follows_the_printed_figure() {
        assert!(format_load(9.996_093_75, 10.0, false).starts_with("[ 10.00 ]"));
        assert_eq!(painted(9.996_093_75, 10.0), WARM);
    }

    /// Affinity and quotas only ever lower `available_parallelism`, so the
    /// online count can never be below it.
    #[test]
    fn the_machine_reports_a_plausible_load_and_core_count() {
        let load = one_minute().expect("getloadavg");
        assert!((0.0..10_000.0).contains(&load), "load was {load}");
        assert!(cores() as usize >= std::thread::available_parallelism().unwrap().get());
    }
}
