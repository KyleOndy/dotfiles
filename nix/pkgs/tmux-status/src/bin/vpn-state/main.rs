//! Which WireGuard tunnel is up, formatted for a tmux status bar.
//!
//! macOS never signals this on its own. wg-quick captures the default route
//! with a `0.0.0.0/1` and `128.0.0.0/1` pair rather than replacing
//! `0.0.0.0/0`, so the tunnel is invisible to the system's own VPN
//! bookkeeping and `scutil --nc list` comes back empty. This segment is the
//! only indication a full tunnel is on, which is the state worth catching: it
//! reroutes every application on the machine, browsers included.
//!
//! Unlike the metric segments, this one never collapses on a host that has
//! tunnels configured; it renders "off" instead. A segment that appeared only
//! while connected would move every segment to its left twice per session.
//! Absence of `/etc/wireguard` is settled once per host, the same shape of
//! test the hardware segments make, so tiger and cogsworth show nothing.

use std::fs;
use std::path::{Path, PathBuf};
use std::process;

use tmux_status::{colors_enabled, styled, HOT, NORMAL, WARM};

/// Where the nix-darwin wg-quick module writes its configs, and the first of
/// the directories wg-quick searches (wireguard-tools 1.0.20250521,
/// `CONFIG_SEARCH_PATHS`).
const CONFIG_DIR: &str = "/etc/wireguard";

/// wg-quick records the utun device it claimed under the profile's name here
/// and removes the file on teardown, so its presence is what "up" means.
const RUN_DIR: &str = "/var/run/wireguard";

fn main() {
    let state = active_profile().map(|p| describe(&p));

    // Bare label, no resting state: the prompt is redrawn per command, and a
    // starship module carries one colour, so case is what escalates a full
    // tunnel there.
    if std::env::args().any(|a| a == "--prompt") {
        let Some((name, full)) = state else {
            process::exit(1);
        };
        print!("VPN {}", if full { name.to_uppercase() } else { name });
        return;
    }

    if !any_tunnel_configured() {
        process::exit(1);
    }
    print!("{}", render(state, colors_enabled()));
}

fn any_tunnel_configured() -> bool {
    let Ok(entries) = fs::read_dir(CONFIG_DIR) else {
        return false;
    };
    entries.flatten().any(|e| {
        e.path()
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("conf"))
    })
}

/// At most one, because `vpn` refuses to raise a second profile over a live
/// one. Taking the first is only a tiebreak for a tunnel brought up by hand.
fn active_profile() -> Option<String> {
    let mut names: Vec<String> = fs::read_dir(RUN_DIR)
        .ok()?
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "name"))
        .filter_map(|e| e.path().file_stem()?.to_str().map(str::to_owned))
        .collect();
    names.sort();
    names.into_iter().next()
}

/// Loudness is read off AllowedIPs rather than matched against a known
/// profile name: the name is a label, the routes are what decide whether
/// every application on the machine is now going somewhere else.
fn describe(profile: &str) -> (String, bool) {
    let conf = PathBuf::from(CONFIG_DIR).join(format!("{profile}.conf"));
    (short_name(profile), carries_default_route(&conf))
}

fn carries_default_route(conf: &Path) -> bool {
    fs::read_to_string(conf).is_ok_and(|text| {
        text.lines()
            .filter_map(|l| l.split_once('='))
            .filter(|(k, _)| k.trim().eq_ignore_ascii_case("allowedips"))
            .any(|(_, v)| v.split(',').any(|cidr| cidr.trim() == "0.0.0.0/0"))
    })
}

fn short_name(profile: &str) -> String {
    profile.strip_prefix("wg-").unwrap_or(profile).to_owned()
}

/// Padded so the three states are the same width. The colour carries the
/// alarm; the label only says which profile.
fn render(state: Option<(String, bool)>, color: bool) -> String {
    let (label, hue) = match state {
        Some((name, true)) => (name, HOT),
        Some((name, false)) => (name, WARM),
        None => ("off".to_owned(), NORMAL),
    };
    let body = format!("VPN {label:<4}");
    if color {
        styled(hue, &body)
    } else {
        body
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_three_states_are_the_same_width() {
        let off = render(None, false);
        let split = render(Some(("home".into(), false)), false);
        let full = render(Some(("all".into(), true)), false);
        assert_eq!(off, "VPN off ");
        assert_eq!(split, "VPN home");
        assert_eq!(full, "VPN all ");
        assert_eq!(off.len(), split.len());
        assert_eq!(split.len(), full.len());
    }

    #[test]
    fn only_a_default_route_gets_the_hot_color() {
        assert!(render(Some(("all".into(), true)), true).contains(HOT));
        assert!(render(Some(("home".into(), false)), true).contains(WARM));
        assert!(render(None, true).contains(NORMAL));
    }

    #[test]
    fn colored_output_carries_the_separator_back() {
        assert!(render(None, true).ends_with(" \u{e0b3} "));
    }

    #[test]
    fn the_wg_prefix_is_dropped_but_other_names_survive() {
        assert_eq!(short_name("wg-home"), "home");
        assert_eq!(short_name("wg-all"), "all");
        assert_eq!(short_name("corp"), "corp");
    }

    #[test]
    fn a_default_route_is_recognised_among_other_cidrs() {
        let dir = std::env::temp_dir().join("vpn-state-test-full");
        fs::create_dir_all(&dir).unwrap();
        let conf = dir.join("wg-all.conf");

        fs::write(&conf, "[Peer]\nAllowedIPs = 0.0.0.0/0\n").unwrap();
        assert!(carries_default_route(&conf));

        fs::write(&conf, "[Peer]\nAllowedIPs = ::/0,0.0.0.0/0\n").unwrap();
        assert!(carries_default_route(&conf));

        fs::write(
            &conf,
            "[Peer]\nAllowedIPs = 10.24.89.0/24,10.25.89.0/24,192.168.5.0/24\n",
        )
        .unwrap();
        assert!(!carries_default_route(&conf));

        fs::write(&conf, "[Peer]\nAllowedIPs = 10.0.0.0/0.0.0.0/0x\n").unwrap();
        assert!(!carries_default_route(&conf));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_missing_config_is_not_a_full_tunnel() {
        assert!(!carries_default_route(Path::new(
            "/nonexistent/wg-nope.conf"
        )));
    }
}
