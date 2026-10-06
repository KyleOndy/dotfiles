//! What every tmux status segment in this crate shares. Each segment hands
//! `rising` or `falling` the reading as printed, rounded the same way, so the
//! colour never disagrees with the number on screen.

#[cfg(target_os = "macos")]
pub mod iokit;

use std::path::{Path, PathBuf};

pub type Res<T> = Result<T, Box<dyn std::error::Error>>;

/// The gruvbox palette tmux.nix already uses.
pub const NORMAL: &str = "colour246";
pub const WARM: &str = "colour214";
pub const HOT: &str = "colour167";

/// U+E0B3, the thin powerline separator the clock segment also uses. Each
/// segment carries it as a suffix rather than tmux.nix writing it between
/// them, because a segment can collapse and a separator owned by tmux.nix
/// would outlive it.
pub const SEP: &str = " \u{e0b3} ";

/// https://no-color.org: colour is off only when NO_COLOR is set and not empty.
pub fn colors_enabled() -> bool {
    std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty())
}

/// Higher is worse. Inclusive: a reading equal to `warm` is warm.
pub fn rising<T: PartialOrd>(reading: T, warm: T, hot: T) -> &'static str {
    if reading >= hot {
        HOT
    } else if reading >= warm {
        WARM
    } else {
        NORMAL
    }
}

/// Lower is worse. Exclusive: a reading equal to `warm` is still normal.
pub fn falling<T: PartialOrd>(reading: T, warm: T, hot: T) -> &'static str {
    if reading < hot {
        HOT
    } else if reading < warm {
        WARM
    } else {
        NORMAL
    }
}

/// The separator is layout, not colour, so it is there with colour off too.
/// Ending on NORMAL hands back the `#[fg=colour246]` tmux.nix wraps every
/// segment in, which tmux honours because it re-parses a `#()` job's output
/// (tmux 3.6a, format.c `format_job_get`).
pub fn paint(body: &str, color: &str, colored: bool) -> String {
    if colored {
        format!("#[fg={color}]{body}#[fg={NORMAL}]{SEP}")
    } else {
        format!("{body}{SEP}")
    }
}

/// On error, nothing on stdout and exit 1, which collapses the segment. tmux
/// points a status job's stderr at /dev/null (tmux 3.6a, job.c `job_run`), so
/// the reason costs the bar nothing and is there when run by hand.
pub fn emit(segment: Res<String>) {
    match segment {
        Ok(text) => print!("{text}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

/// `$XDG_CACHE_HOME/tmux-status/<name>` or `~/.cache/tmux-status/<name>`, its
/// directory created. None when there is nowhere to put it.
pub fn cache_file(name: &str) -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| Path::new(&h).join(".cache")))?;
    let dir = base.join("tmux-status");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join(name))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn painting_restores_the_surrounding_color_and_keeps_the_separator() {
        assert_eq!(
            paint("5%", HOT, true),
            "#[fg=colour167]5%#[fg=colour246] \u{e0b3} "
        );
        assert_eq!(paint("5%", HOT, false), "5% \u{e0b3} ");
    }

    #[test]
    fn rising_thresholds_are_inclusive() {
        assert_eq!(rising(79, 80, 95), NORMAL);
        assert_eq!(rising(80, 80, 95), WARM);
        assert_eq!(rising(94, 80, 95), WARM);
        assert_eq!(rising(95, 80, 95), HOT);
    }

    #[test]
    fn falling_thresholds_are_exclusive() {
        assert_eq!(falling(25, 25, 10), NORMAL);
        assert_eq!(falling(24, 25, 10), WARM);
        assert_eq!(falling(10, 25, 10), WARM);
        assert_eq!(falling(9, 25, 10), HOT);
    }
}
