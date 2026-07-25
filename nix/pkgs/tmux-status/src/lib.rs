//! The pieces every tmux status segment in this crate shares.
//!
//! The segments were five separate crates and each carried its own copy of
//! these constants, its own `colors_enabled`, and its own spelling of the
//! colour-wrapping format string. They live here instead so the palette and
//! the separator can only be changed in one place.

/// tmux colours, matching the gruvbox palette already used in tmux.nix.
pub const NORMAL: &str = "colour246";
pub const WARM: &str = "colour214";
pub const HOT: &str = "colour167";

/// U+E0B3, the powerline thin separator, matching the one the clock segment
/// already puts between the date and the time. The left-pointing variants
/// (E0B2 solid, E0B3 thin) are the ones for the right of the bar; the window
/// tabs use the right-pointing E0B0/E0B1 for the same reason.
///
/// Each segment carries it as a trailing suffix rather than tmux.nix writing
/// it between the segments: every metric segment can collapse to nothing, and
/// a separator owned by tmux.nix would outlive its segment and leave `│ │`.
pub const SEP: &str = " \u{e0b3} ";

/// Honours the NO_COLOR convention, which is also what the tests use to get at
/// the plain rendering.
pub fn colors_enabled() -> bool {
    std::env::var_os("NO_COLOR").is_none()
}

/// Paint a rendered body and hand the surrounding style back, separator
/// included.
///
/// tmux re-expands the stdout of a `#()` job through its format parser, so the
/// `#[fg=...]` written here is honoured (tmux 3.6a, format.c
/// `format_job_get`). Restoring NORMAL at the end matters because the segment
/// is embedded in a `#[fg=colour246,bg=colour239]` run in tmux.nix that the
/// next segment expects to still be in force.
pub fn styled(color: &str, body: &str) -> String {
    format!("#[fg={color}]{body}#[fg={NORMAL}]{SEP}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn styling_restores_the_surrounding_color_and_carries_the_separator() {
        assert_eq!(styled(HOT, "5%"), "#[fg=colour167]5%#[fg=colour246] \u{e0b3} ");
        assert!(styled(NORMAL, "anything").ends_with("#[fg=colour246] \u{e0b3} "));
    }
}
