//! Which WireGuard tunnel is up, for the tmux status bar and, with `--prompt`,
//! the starship prompt. macOS only: it reads wg-quick's darwin bookkeeping,
//! and on linux it exits 1 so both callers collapse.
//!
//! macOS never signals this on its own. wg-quick captures the default route
//! with a `0.0.0.0/1` and `128.0.0.0/1` pair rather than replacing
//! `0.0.0.0/0`, so the tunnel is invisible to the system's VPN bookkeeping and
//! `scutil --nc list` comes back empty. This is the only indication a full
//! tunnel is on, which is the state worth catching: it reroutes every
//! application on the machine.
//!
//! The tmux segment never collapses on a host with tunnels configured; it
//! renders "off" instead, padded to the longest profile name, so connecting
//! does not move the segments to its left.

use std::fs;
use std::io;
use std::os::raw::{c_char, c_uint};
use std::path::Path;
use std::time::{Duration, SystemTime};

use tmux_status::{colors_enabled, paint, HOT, NORMAL, WARM};

/// Where the nix-darwin wg-quick module writes its configs, and the first of
/// the directories wg-quick searches.
const CONFIG_DIR: &str = "/etc/wireguard";
const RUN_DIR: &str = "/var/run/wireguard";

unsafe extern "C" {
    fn if_nametoindex(name: *const c_char) -> c_uint;
}

fn main() {
    if !cfg!(target_os = "macos") {
        eprintln!("vpn-state reads wg-quick's darwin bookkeeping only");
        std::process::exit(1);
    }

    let state = loudest(
        active(Path::new(RUN_DIR))
            .iter()
            .map(|profile| describe(Path::new(CONFIG_DIR), profile)),
    );
    let out = if std::env::args().any(|a| a == "--prompt") {
        prompt(state)
    } else {
        tmux(state, configured(Path::new(CONFIG_DIR)), colors_enabled())
    };
    match out {
        Some(text) => print!("{text}"),
        None => std::process::exit(1),
    }
}

/// Profiles with a live tunnel. wireguard-go writes `<profile>.name` and
/// `utunN.sock` together when it starts and nothing removes the `.name` if it
/// dies, so a profile counts only while some socket written within two
/// seconds of its `.name` still has its utun interface. That pairing is the
/// test wg-quick's get_real_interface makes (wireguard-tools v1.0.20250521,
/// darwin.bash), less reading the `.name` itself, which is 0400 root.
fn active(run: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(run) else {
        return Vec::new();
    };
    let mut names = Vec::new();
    let mut sockets = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let (Some(stem), Some(ext)) = (
            path.file_stem().and_then(|s| s.to_str()),
            path.extension().and_then(|s| s.to_str()),
        ) else {
            continue;
        };
        let Ok(written) = entry.metadata().and_then(|m| m.modified()) else {
            continue;
        };
        match ext {
            "name" => names.push((stem.to_owned(), written)),
            "sock" if interface_exists(stem) => sockets.push(written),
            _ => {}
        }
    }
    names
        .into_iter()
        .filter(|(_, at)| {
            sockets
                .iter()
                .any(|s| apart(*at, *s) < Duration::from_secs(2))
        })
        .map(|(name, _)| name)
        .collect()
}

fn apart(a: SystemTime, b: SystemTime) -> Duration {
    a.duration_since(b)
        .or_else(|_| b.duration_since(a))
        .unwrap_or_default()
}

fn interface_exists(name: &str) -> bool {
    std::ffi::CString::new(name).is_ok_and(|c| unsafe { if_nametoindex(c.as_ptr()) } != 0)
}

/// The profile's short name and whether it carries a default route. Loudness
/// comes from AllowedIPs rather than the name: the routes are what decide
/// whether every application is now going somewhere else.
fn describe(config_dir: &Path, profile: &str) -> (String, bool) {
    let conf = config_dir.join(format!("{profile}.conf"));
    (short_name(profile), carries_default_route(&conf))
}

/// Read the way wg's config.c does: everything from `#` dropped, whitespace
/// removed. A config that cannot be read counts as full, because the hot
/// colour is the one that must not be lost.
fn carries_default_route(conf: &Path) -> bool {
    let Ok(text) = fs::read_to_string(conf) else {
        return true;
    };
    text.lines()
        .filter_map(|line| {
            let line: String = line.split('#').next()?.split_whitespace().collect();
            let (key, value) = line.split_once('=')?;
            key.eq_ignore_ascii_case("allowedips")
                .then(|| value.to_owned())
        })
        .any(|value| {
            value
                .split(',')
                .any(|cidr| cidr == "0.0.0.0/0" || cidr == "::/0")
        })
}

fn short_name(profile: &str) -> String {
    profile.strip_prefix("wg-").unwrap_or(profile).to_owned()
}

/// A full tunnel first, so a second split tunnel cannot hide it; then by name.
fn loudest(states: impl Iterator<Item = (String, bool)>) -> Option<(String, bool)> {
    states.min_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)))
}

/// Short names of every profile in `config_dir`.
fn configured(config_dir: &Path) -> io::Result<Vec<String>> {
    Ok(fs::read_dir(config_dir)?
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            if !path
                .extension()
                .is_some_and(|x| x.eq_ignore_ascii_case("conf"))
            {
                return None;
            }
            Some(short_name(path.file_stem()?.to_str()?))
        })
        .collect())
}

/// A bare label: a starship module carries one colour, so case is what
/// escalates a full tunnel. None, and exit 1, when nothing is up.
fn prompt(state: Option<(String, bool)>) -> Option<String> {
    let (name, full) = state?;
    Some(format!(
        "VPN {}",
        if full { name.to_uppercase() } else { name }
    ))
}

/// None, which collapses the segment, only when nothing is up and the host has
/// no profiles. An unreadable config directory still renders.
fn tmux(
    state: Option<(String, bool)>,
    configs: io::Result<Vec<String>>,
    colored: bool,
) -> Option<String> {
    let names = match configs {
        Ok(names) => names,
        Err(e) if e.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(_) => vec!["off".to_owned()],
    };
    if state.is_none() && names.is_empty() {
        return None;
    }
    let (label, color) = match state {
        Some((name, true)) => (name, HOT),
        Some((name, false)) => (name, WARM),
        None => ("off".to_owned(), NORMAL),
    };
    // wg-quick limits names to 15 ASCII characters, so chars are columns.
    let width = names
        .iter()
        .chain([&label])
        .map(|n| n.chars().count())
        .max()
        .unwrap_or(0)
        .max(3);
    Some(paint(&format!("VPN {label:<width$}"), color, colored))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn scratch(test: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("vpn-state-{}-{test}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn names(list: &[&str]) -> io::Result<Vec<String>> {
        Ok(list.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn every_state_is_as_wide_as_the_longest_profile() {
        let profiles = || names(&["home", "all"]);
        let off = tmux(None, profiles(), false).unwrap();
        let split = tmux(Some(("home".into(), false)), profiles(), false).unwrap();
        let full = tmux(Some(("all".into(), true)), profiles(), false).unwrap();
        assert_eq!(off, "VPN off  \u{e0b3} ");
        assert_eq!(split, "VPN home \u{e0b3} ");
        assert_eq!(full, "VPN all  \u{e0b3} ");

        let long = || names(&["office", "all"]);
        assert_eq!(
            tmux(None, long(), false).unwrap().len(),
            tmux(Some(("office".into(), false)), long(), false)
                .unwrap()
                .len()
        );
    }

    #[test]
    fn each_state_gets_its_own_color() {
        let painted = |state| tmux(state, names(&["home"]), true).unwrap();
        assert!(painted(Some(("all".into(), true))).starts_with("#[fg=colour167]VPN all"));
        assert!(painted(Some(("home".into(), false))).starts_with("#[fg=colour214]VPN home"));
        assert!(painted(None).starts_with("#[fg=colour246]VPN off"));
    }

    #[test]
    fn collapses_only_with_nothing_up_and_no_profiles() {
        let missing = || Err(io::Error::from(io::ErrorKind::NotFound));
        let denied = || Err(io::Error::from(io::ErrorKind::PermissionDenied));
        assert_eq!(tmux(None, missing(), false), None);
        assert_eq!(tmux(None, names(&[]), false), None);
        assert_eq!(tmux(None, denied(), false).unwrap(), "VPN off \u{e0b3} ");
        assert!(tmux(Some(("corp".into(), false)), missing(), false).is_some());
    }

    #[test]
    fn the_prompt_is_bare_and_shouts_a_full_tunnel() {
        assert_eq!(prompt(None), None);
        assert_eq!(prompt(Some(("home".into(), false))).unwrap(), "VPN home");
        assert_eq!(prompt(Some(("all".into(), true))).unwrap(), "VPN ALL");
    }

    #[test]
    fn a_full_tunnel_wins_over_a_split_one_whatever_the_names() {
        let both = [("lab".to_owned(), false), ("vpn".to_owned(), true)];
        assert_eq!(loudest(both.into_iter()), Some(("vpn".to_owned(), true)));
        let splits = [("home".to_owned(), false), ("b".to_owned(), false)];
        assert_eq!(loudest(splits.into_iter()), Some(("b".to_owned(), false)));
    }

    #[test]
    fn the_wg_prefix_is_dropped_but_other_names_survive() {
        assert_eq!(short_name("wg-home"), "home");
        assert_eq!(short_name("corp"), "corp");
    }

    #[test]
    fn allowed_ips_are_read_the_way_wg_reads_them() {
        let dir = scratch("conf");
        let conf = dir.join("wg-all.conf");
        let full = |text: &str| {
            fs::write(&conf, text).unwrap();
            carries_default_route(&conf)
        };
        assert!(full("[Peer]\nAllowedIPs = 0.0.0.0/0\n"));
        assert!(full("[Peer]\nallowedips=10.0.0.0/8, 0.0.0.0/0\r\n"));
        assert!(full("[Peer]\nAllowedIPs = ::/0\n"));
        assert!(full("[Peer]\nAllowedIPs = 0.0.0.0/0 # everything\n"));
        assert!(full(
            "[Peer]\nAllowedIPs = 10.0.0.0/8\n[Peer]\nAllowedIPs = 0.0.0.0/0\n"
        ));
        assert!(!full("[Peer]\nAllowedIPs = 10.0.0.0/8 #, 0.0.0.0/0\n"));
        assert!(!full("[Peer]\n#AllowedIPs = 0.0.0.0/0\n"));
        assert!(!full("[Peer]\nAllowedIPs = 10.24.89.0/24,192.168.5.0/24\n"));
        assert!(carries_default_route(&dir.join("absent.conf")));
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn configured_lists_short_names_of_conf_files() {
        let dir = scratch("configured");
        fs::write(dir.join("wg-home.conf"), "").unwrap();
        fs::write(dir.join("wg-all.CONF"), "").unwrap();
        fs::write(dir.join("notes.txt"), "").unwrap();
        let mut found = configured(&dir).unwrap();
        found.sort();
        assert_eq!(found, ["all", "home"]);
        assert_eq!(
            configured(&dir.join("absent")).unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
        fs::remove_dir_all(dir).ok();
    }

    /// lo0 stands in for a live utun; utun999 for one whose wireguard-go died.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_name_counts_only_beside_a_live_socket_written_with_it() {
        let dir = scratch("run");
        fs::write(dir.join("wg-all.name"), "").unwrap();
        fs::write(dir.join("lo0.sock"), "").unwrap();
        assert_eq!(active(&dir), ["wg-all"]);

        fs::remove_file(dir.join("lo0.sock")).unwrap();
        fs::write(dir.join("utun999.sock"), "").unwrap();
        assert!(active(&dir).is_empty());

        assert!(active(&dir.join("absent")).is_empty());
        fs::remove_dir_all(dir).ok();
    }
}
