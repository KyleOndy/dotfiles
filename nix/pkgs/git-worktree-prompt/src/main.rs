use std::env;
use std::error::Error as StdError;
use std::fmt;
use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

// ============================================================================
// Error Handling
// ============================================================================

/// Custom error type for git operations
#[derive(Debug)]
struct Error(String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl StdError for Error {}

impl Error {
    pub(crate) fn from_str(s: &str) -> Self {
        Error(s.to_string())
    }
}

impl From<std::io::Error> for Error {
    fn from(err: std::io::Error) -> Self {
        Error(err.to_string())
    }
}

// ============================================================================
// Configuration Constants
// ============================================================================

/// Maximum depth to search for .git directory when walking up the tree
const MAX_GIT_SEARCH_DEPTH: usize = 32;

/// Maximum depth to search for .bare directory
const MAX_BARE_SEARCH_DEPTH: usize = 4;

/// Length of commit hash to display for detached HEAD state
const DETACHED_HEAD_HASH_LENGTH: usize = 7;

/// Default icon displayed before worktree paths
const DEFAULT_WORKTREE_ICON: &str = "🌳";

/// Default icon displayed before branch names (Unicode, works without Nerd Fonts)
const DEFAULT_BRANCH_ICON: &str = "⎇";

/// Environment variable name for customizing the branch icon
const ENV_BRANCH_ICON: &str = "GIT_WORKTREE_PROMPT_BRANCH_ICON";

/// Environment variable name for customizing the worktree icon
const ENV_WORKTREE_ICON: &str = "GIT_WORKTREE_PROMPT_WORKTREE_ICON";

/// Log file name for error messages
pub(crate) const ERROR_LOG_FILE: &str = "error.log";

/// Application directory name for state storage
pub(crate) const APP_STATE_DIR: &str = "git-worktree-prompt";

// ============================================================================
// Main Entry Point
// ============================================================================

fn main() {
    // Parse args for optional --debug flag
    let args: Vec<String> = env::args().collect();
    let debug = args.contains(&"--debug".to_string());

    match run() {
        Ok(Some(output)) => print!("{}", output),
        Ok(None) => {
            if debug {
                eprintln!("[DEBUG] Not in git repo or no output needed");
            }
        }
        Err(e) => {
            log_error(&e);
            if debug {
                eprintln!("[DEBUG] Error: {}", e);
            }
        }
    }
}

// ============================================================================
// Pure Rust Git Operations
// ============================================================================

/// Main logic function - discovers git repo and formats output
pub(crate) fn run() -> Result<Option<String>, Error> {
    // 1. Find .git directory (walk up from current directory)
    let git_dir = match find_git_dir()? {
        Some(dir) => dir,
        None => return Ok(None), // Not in a git repo
    };

    // 2. Get the work directory (parent of .git if it's a directory)
    let work_dir = if git_dir.is_file() {
        // Worktree: .git is a file, work_dir is its parent
        git_dir
            .parent()
            .ok_or_else(|| Error::from_str("Invalid .git file path"))?
            .to_path_buf()
    } else {
        // Regular repo: work_dir is parent of .git directory
        git_dir
            .parent()
            .ok_or_else(|| Error::from_str("Invalid .git directory path"))?
            .to_path_buf()
    };

    // 3. Get the actual git directory (handle worktrees)
    let real_git_dir = if git_dir.is_file() {
        parse_gitdir_file(&git_dir)?
    } else {
        git_dir
    };

    // 4. Check if this is a bare repository
    if !real_git_dir.join("HEAD").exists() {
        return Ok(None); // Bare repo
    }

    // 5. Read and parse HEAD to get branch name
    let branch = read_git_head(&real_git_dir)?;

    // 6. Check if we're in a worktree setup (look for .bare parent)
    if let Some(bare_parent) = find_bare_parent(&work_dir) {
        let worktree_path = get_relative_path(&bare_parent, &work_dir)?;

        // If in bare parent directory (not in any worktree), show [bare]
        if worktree_path.is_empty() || worktree_path == "." {
            return Ok(Some(format!("{} [bare]", get_worktree_icon())));
        }

        // IN ACTUAL WORKTREE
        let output = format_output_worktree(&worktree_path, &branch);
        Ok(Some(output))
    } else {
        // REGULAR GIT REPO
        let output = format_output_regular(&branch);
        Ok(Some(output))
    }
}

/// Finds the .git directory by walking up from the current directory
/// Returns the path to .git (which might be a file or directory)
fn find_git_dir() -> Result<Option<PathBuf>, Error> {
    let mut current = env::current_dir()?;

    for _ in 0..MAX_GIT_SEARCH_DEPTH {
        let git_path = current.join(".git");
        if git_path.exists() {
            return Ok(Some(git_path));
        }

        // Move to parent directory
        current = match current.parent() {
            Some(parent) => parent.to_path_buf(),
            None => return Ok(None), // Reached filesystem root
        };
    }

    Ok(None) // Not found within max depth
}

/// Parses a .git file (used in worktrees) to get the real git directory
/// File format: "gitdir: /path/to/real/.git\n"
fn parse_gitdir_file(git_file: &Path) -> Result<PathBuf, Error> {
    let content = fs::read_to_string(git_file)?;

    // Parse "gitdir: /path" format
    if let Some(path_str) = content.strip_prefix("gitdir: ") {
        let path_str = path_str.trim();
        let path = PathBuf::from(path_str);

        // Handle relative paths (relative to .git file location)
        if path.is_absolute() {
            Ok(path)
        } else {
            let base = git_file
                .parent()
                .ok_or_else(|| Error::from_str("Invalid .git file path"))?;
            Ok(base.join(path))
        }
    } else {
        Err(Error::from_str("Invalid .git file format"))
    }
}

/// Reads and parses .git/HEAD to get the current branch name or commit hash
fn read_git_head(git_dir: &Path) -> Result<String, Error> {
    let head_path = git_dir.join("HEAD");
    let content = fs::read_to_string(head_path)?;
    let content = content.trim();

    // Case 1: Regular branch (ref: refs/heads/branch-name)
    if let Some(ref_path) = content.strip_prefix("ref: ") {
        if let Some(branch) = ref_path.strip_prefix("refs/heads/") {
            return Ok(branch.to_string());
        }
        // Other ref types (tags, remotes) - just return the ref name
        return Ok(ref_path
            .rsplit('/')
            .next()
            .unwrap_or(ref_path)
            .to_string());
    }

    // Case 2: Detached HEAD (40-character SHA-1 hash)
    if content.len() == 40 && content.chars().all(|c| c.is_ascii_hexdigit()) {
        return Ok(content[..DETACHED_HEAD_HASH_LENGTH].to_string());
    }

    // Case 3: Short hash or unknown format
    if content.len() >= DETACHED_HEAD_HASH_LENGTH {
        return Ok(content[..DETACHED_HEAD_HASH_LENGTH].to_string());
    }

    Err(Error::from_str("Unknown HEAD format"))
}

/// Searches for .bare directory up to MAX_BARE_SEARCH_DEPTH levels
/// Returns the directory containing .bare, or None for regular repos
fn find_bare_parent(work_dir: &Path) -> Option<PathBuf> {
    let mut current = work_dir;

    for _ in 0..MAX_BARE_SEARCH_DEPTH {
        let bare_path = current.join(".bare");
        if bare_path.is_dir() {
            return Some(current.to_path_buf());
        }

        current = current.parent()?;
    }

    None
}

/// Calculates worktree directory path relative to bare parent directory
fn get_relative_path(bare_parent: &Path, work_dir: &Path) -> Result<String, Error> {
    let relative = work_dir
        .strip_prefix(bare_parent)
        .map_err(|e| Error::from_str(&format!("Failed to calculate relative path: {}", e)))?;

    Ok(relative.to_string_lossy().to_string())
}

/// Gets the branch icon from environment variable or returns default
fn get_branch_icon() -> String {
    env::var(ENV_BRANCH_ICON).unwrap_or_else(|_| DEFAULT_BRANCH_ICON.to_string())
}

/// Gets the worktree icon from environment variable or returns default
fn get_worktree_icon() -> String {
    env::var(ENV_WORKTREE_ICON).unwrap_or_else(|_| DEFAULT_WORKTREE_ICON.to_string())
}

/// Formats output for regular (non-worktree) repositories
fn format_output_regular(branch: &str) -> String {
    let icon = get_branch_icon();
    format!("{} {}", icon, branch)
}

/// Formats output for worktree repositories
fn format_output_worktree(worktree_path: &str, branch: &str) -> String {
    let worktree_icon = get_worktree_icon();
    let branch_icon = get_branch_icon();
    let normalized = normalize_path(worktree_path);
    if normalized == branch {
        format!("{} {}", worktree_icon, worktree_path)
    } else {
        format!("{} {} → {} {}", worktree_icon, worktree_path, branch_icon, branch)
    }
}

/// Converts forward slashes to hyphens for path comparison
fn normalize_path(path: &str) -> String {
    path.trim_end_matches('/').replace('/', "-")
}

// ============================================================================
// Error Logging
// ============================================================================

/// Resolves the error log file path using XDG Base Directory specification
fn get_log_path() -> Option<PathBuf> {
    if let Ok(xdg_state) = env::var("XDG_STATE_HOME") {
        let mut path = PathBuf::from(xdg_state);
        path.push(APP_STATE_DIR);
        path.push(ERROR_LOG_FILE);
        return Some(path);
    }

    if let Ok(home) = env::var("HOME") {
        let mut path = PathBuf::from(home);
        path.push(".local");
        path.push("state");
        path.push(APP_STATE_DIR);
        path.push(ERROR_LOG_FILE);
        return Some(path);
    }

    None
}

/// Logs errors to XDG_STATE_HOME error log file
pub(crate) fn log_error(error: &Error) {
    let log_path = match get_log_path() {
        Some(path) => path,
        None => return,
    };

    if let Some(parent) = log_path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let timestamp = match SystemTime::now().duration_since(SystemTime::UNIX_EPOCH) {
        Ok(duration) => format!("{}", duration.as_secs()),
        Err(_) => String::from("unknown"),
    };

    let message = format!("[{}] {}\n", timestamp, error);

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_path) {
        let _ = file.write_all(message.as_bytes());
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn test_normalize_path() {
        assert_eq!(normalize_path("DEV-123/fix-thing"), "DEV-123-fix-thing");
        assert_eq!(normalize_path("feature/something"), "feature-something");
        assert_eq!(normalize_path("simple"), "simple");
    }

    #[test]
    fn test_format_output_regular() {
        assert_eq!(format_output_regular("main"), "⎇ main");
        assert_eq!(
            format_output_regular("feature/add-tests"),
            "⎇ feature/add-tests"
        );
        assert_eq!(format_output_regular("a1b2c3d"), "⎇ a1b2c3d");
    }

    #[test]
    fn test_format_output_worktree_match() {
        assert_eq!(
            format_output_worktree("DEV-123/fix-thing", "DEV-123-fix-thing"),
            "🌳 DEV-123/fix-thing"
        );
        assert_eq!(
            format_output_worktree("feature/add-tests", "feature-add-tests"),
            "🌳 feature/add-tests"
        );
        assert_eq!(format_output_worktree("simple", "simple"), "🌳 simple");
    }

    #[test]
    fn test_format_output_worktree_mismatch() {
        assert_eq!(
            format_output_worktree("DEV-123/fix-thing", "main"),
            "🌳 DEV-123/fix-thing → ⎇ main"
        );
        assert_eq!(
            format_output_worktree("feature/add-tests", "main"),
            "🌳 feature/add-tests → ⎇ main"
        );
        assert_eq!(
            format_output_worktree("DEV-123/fix-thing", "a1b2c3d"),
            "🌳 DEV-123/fix-thing → ⎇ a1b2c3d"
        );
    }

    #[test]
    #[serial]
    fn test_log_error_no_panic_without_env() {
        let home_backup = env::var("HOME").ok();
        let xdg_backup = env::var("XDG_STATE_HOME").ok();

        unsafe {
            env::remove_var("HOME");
            env::remove_var("XDG_STATE_HOME");
        }

        let error = Error::from_str("Test error");
        log_error(&error);

        unsafe {
            if let Some(home) = home_backup {
                env::set_var("HOME", home);
            }
            if let Some(xdg) = xdg_backup {
                env::set_var("XDG_STATE_HOME", xdg);
            }
        }
    }

    #[test]
    #[serial]
    fn test_custom_branch_icon() {
        let backup = env::var(ENV_BRANCH_ICON).ok();

        unsafe {
            env::set_var(ENV_BRANCH_ICON, "🔀");
        }

        assert_eq!(format_output_regular("main"), "🔀 main");
        assert_eq!(
            format_output_worktree("feature/test", "main"),
            "🌳 feature/test → 🔀 main"
        );

        unsafe {
            match backup {
                Some(val) => env::set_var(ENV_BRANCH_ICON, val),
                None => env::remove_var(ENV_BRANCH_ICON),
            }
        }
    }

    #[test]
    #[serial]
    fn test_custom_worktree_icon() {
        let backup = env::var(ENV_WORKTREE_ICON).ok();

        unsafe {
            env::set_var(ENV_WORKTREE_ICON, "📁");
        }

        assert_eq!(
            format_output_worktree("feature/test", "feature-test"),
            "📁 feature/test"
        );
        assert_eq!(
            format_output_worktree("feature/test", "main"),
            "📁 feature/test → ⎇ main"
        );

        unsafe {
            match backup {
                Some(val) => env::set_var(ENV_WORKTREE_ICON, val),
                None => env::remove_var(ENV_WORKTREE_ICON),
            }
        }
    }

    #[test]
    #[serial]
    fn test_custom_both_icons() {
        let branch_backup = env::var(ENV_BRANCH_ICON).ok();
        let worktree_backup = env::var(ENV_WORKTREE_ICON).ok();

        unsafe {
            env::set_var(ENV_BRANCH_ICON, "");
            env::set_var(ENV_WORKTREE_ICON, "→");
        }

        assert_eq!(format_output_regular("main"), " main");
        assert_eq!(
            format_output_worktree("feature/test", "main"),
            "→ feature/test →  main"
        );

        unsafe {
            match branch_backup {
                Some(val) => env::set_var(ENV_BRANCH_ICON, val),
                None => env::remove_var(ENV_BRANCH_ICON),
            }
            match worktree_backup {
                Some(val) => env::set_var(ENV_WORKTREE_ICON, val),
                None => env::remove_var(ENV_WORKTREE_ICON),
            }
        }
    }
}

#[cfg(test)]
mod integration_tests;
