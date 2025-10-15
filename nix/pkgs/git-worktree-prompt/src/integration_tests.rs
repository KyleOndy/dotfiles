use crate::*;
use serial_test::serial;
use std::env;
use std::fs;
use std::process::Command;
use tempfile::TempDir;

fn create_test_repo() -> TempDir {
    let dir = TempDir::new().unwrap();
    let path = dir.path();

    Command::new("git")
        .args(["init"])
        .current_dir(path)
        .output()
        .unwrap();

    Command::new("git")
        .args(["config", "user.name", "Test"])
        .current_dir(path)
        .output()
        .unwrap();

    Command::new("git")
        .args(["config", "user.email", "test@example.com"])
        .current_dir(path)
        .output()
        .unwrap();

    fs::write(path.join("test.txt"), "test").unwrap();

    Command::new("git")
        .args(["add", "."])
        .current_dir(path)
        .output()
        .unwrap();

    Command::new("git")
        .args(["commit", "-m", "initial"])
        .current_dir(path)
        .output()
        .unwrap();

    dir
}

#[test]
#[serial]
fn test_regular_repo_on_main() {
    let repo_dir = create_test_repo();
    let original_dir = env::current_dir().unwrap();

    env::set_current_dir(repo_dir.path()).unwrap();
    let result = run();
    env::set_current_dir(original_dir).unwrap();

    assert!(result.is_ok(), "run() should succeed in a git repository");
    let output = result.unwrap();
    assert!(
        output.is_some(),
        "run() should return Some output for a git repository"
    );

    let branch = output.unwrap();
    assert!(
        branch == "⎇ main" || branch == "⎇ master",
        "Expected branch '⎇ main' or '⎇ master', got '{}'",
        branch
    );
}

#[test]
#[serial]
fn test_non_git_directory() {
    let temp_dir = TempDir::new().unwrap();
    let original_dir = env::current_dir().unwrap();

    env::set_current_dir(temp_dir.path()).unwrap();
    let result = run();
    env::set_current_dir(original_dir).unwrap();

    assert!(result.is_ok(), "run() should succeed in non-git directory");
    let output = result.unwrap();
    assert!(
        output.is_none(),
        "run() should return None for non-git directory"
    );
}

#[test]
#[serial]
fn test_detached_head_state() {
    let repo_dir = create_test_repo();
    let path = repo_dir.path();

    let hash_output = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(path)
        .output()
        .unwrap();
    let full_hash = String::from_utf8(hash_output.stdout).unwrap();
    let full_hash = full_hash.trim();
    let expected_short_hash = &full_hash[..7];

    Command::new("git")
        .args(["checkout", full_hash])
        .current_dir(path)
        .output()
        .unwrap();

    let original_dir = env::current_dir().unwrap();
    env::set_current_dir(path).unwrap();
    let result = run();
    env::set_current_dir(original_dir).unwrap();

    assert!(
        result.is_ok(),
        "run() should succeed in detached HEAD state"
    );
    let output = result.unwrap();
    assert!(
        output.is_some(),
        "run() should return Some output for detached HEAD"
    );

    let branch = output.unwrap();
    // Output format is "⎇ <7-char-hash>" which is 11 chars total (3-byte icon + space + 7 chars)
    assert_eq!(
        branch.len(),
        11,
        "Detached HEAD should show '⎇ <hash>' (11 chars), got '{}'",
        branch
    );
    let expected_output = format!("⎇ {}", expected_short_hash);
    assert_eq!(
        branch, expected_output,
        "Expected '{}', got '{}'",
        expected_output, branch
    );
}

#[test]
#[serial]
fn test_log_error_creates_file_and_directory() {
    let temp_dir = TempDir::new().unwrap();
    let original_xdg = env::var("XDG_STATE_HOME").ok();

    unsafe {
        env::set_var("XDG_STATE_HOME", temp_dir.path());
    }

    let error = Error::from_str("Test error message");
    log_error(&error);

    let expected_dir = temp_dir.path().join(APP_STATE_DIR);
    assert!(expected_dir.exists(), "Log directory should be created");
    assert!(expected_dir.is_dir(), "Log path should be a directory");

    let expected_log = expected_dir.join(ERROR_LOG_FILE);
    assert!(expected_log.exists(), "Log file should be created");
    assert!(expected_log.is_file(), "Log path should be a file");

    let content = fs::read_to_string(&expected_log).unwrap();
    assert!(
        content.contains("Test error message"),
        "Log should contain error message"
    );
    assert!(content.contains("["), "Log should contain timestamp prefix");
    assert!(content.contains("]"), "Log should contain timestamp suffix");

    unsafe {
        match original_xdg {
            Some(val) => env::set_var("XDG_STATE_HOME", val),
            None => env::remove_var("XDG_STATE_HOME"),
        }
    }
}

#[test]
#[serial]
fn test_log_error_appends_multiple_entries() {
    let temp_dir = TempDir::new().unwrap();
    let original_xdg = env::var("XDG_STATE_HOME").ok();

    unsafe {
        env::set_var("XDG_STATE_HOME", temp_dir.path());
    }

    let error1 = Error::from_str("First error");
    log_error(&error1);

    let error2 = Error::from_str("Second error");
    log_error(&error2);

    let expected_log = temp_dir.path().join(APP_STATE_DIR).join(ERROR_LOG_FILE);
    let content = fs::read_to_string(&expected_log).unwrap();

    assert!(
        content.contains("First error"),
        "Log should contain first error"
    );
    assert!(
        content.contains("Second error"),
        "Log should contain second error"
    );

    let open_brackets = content.matches('[').count();
    assert!(
        open_brackets >= 2,
        "Should have at least 2 timestamp entries"
    );

    unsafe {
        match original_xdg {
            Some(val) => env::set_var("XDG_STATE_HOME", val),
            None => env::remove_var("XDG_STATE_HOME"),
        }
    }
}

#[test]
#[serial]
fn test_log_error_uses_home_fallback() {
    let temp_dir = TempDir::new().unwrap();
    let original_home = env::var("HOME").ok();
    let original_xdg = env::var("XDG_STATE_HOME").ok();

    unsafe {
        env::remove_var("XDG_STATE_HOME");
        env::set_var("HOME", temp_dir.path());
    }

    let error = Error::from_str("Fallback test error");
    log_error(&error);

    let expected_log = temp_dir
        .path()
        .join(".local")
        .join("state")
        .join(APP_STATE_DIR)
        .join(ERROR_LOG_FILE);

    assert!(
        expected_log.exists(),
        "Log file should be created in HOME/.local/state"
    );

    let content = fs::read_to_string(&expected_log).unwrap();
    assert!(
        content.contains("Fallback test error"),
        "Log should contain error message"
    );

    unsafe {
        match original_home {
            Some(val) => env::set_var("HOME", val),
            None => env::remove_var("HOME"),
        }
        match original_xdg {
            Some(val) => env::set_var("XDG_STATE_HOME", val),
            None => env::remove_var("XDG_STATE_HOME"),
        }
    }
}

#[test]
#[serial]
fn test_bare_adjacent_directory() {
    // Create a worktree-style setup with .bare directory
    let temp_dir = TempDir::new().unwrap();
    let path = temp_dir.path();

    // Create .bare directory and initialize as bare repo
    let bare_dir = path.join(".bare");
    fs::create_dir(&bare_dir).unwrap();

    Command::new("git")
        .args(["init", "--bare"])
        .current_dir(&bare_dir)
        .output()
        .unwrap();

    // Create a .git file pointing to .bare (simulating worktree setup)
    fs::write(path.join(".git"), "gitdir: .bare").unwrap();

    // Create an initial worktree to have a valid HEAD
    let worktree_dir = path.join("main");
    Command::new("git")
        .args(["worktree", "add", "main"])
        .current_dir(path)
        .output()
        .unwrap();

    // Configure git in the worktree
    Command::new("git")
        .args(["config", "user.name", "Test"])
        .current_dir(&worktree_dir)
        .output()
        .unwrap();

    Command::new("git")
        .args(["config", "user.email", "test@example.com"])
        .current_dir(&worktree_dir)
        .output()
        .unwrap();

    // Create initial commit
    fs::write(worktree_dir.join("test.txt"), "test").unwrap();
    Command::new("git")
        .args(["add", "."])
        .current_dir(&worktree_dir)
        .output()
        .unwrap();

    Command::new("git")
        .args(["commit", "-m", "initial"])
        .current_dir(&worktree_dir)
        .output()
        .unwrap();

    // Now test from the bare parent directory (not in any worktree)
    let original_dir = env::current_dir().unwrap();
    env::set_current_dir(path).unwrap();
    let result = run();
    env::set_current_dir(original_dir).unwrap();

    assert!(
        result.is_ok(),
        "run() should succeed in bare parent directory"
    );
    let output = result.unwrap();
    assert!(
        output.is_some(),
        "run() should return Some output for bare parent directory"
    );

    let output_text = output.unwrap();
    assert_eq!(
        output_text, "🌳 [bare]",
        "Expected '🌳 [bare]' in bare parent directory, got '{}'",
        output_text
    );
}

#[test]
#[serial]
fn test_corrupted_git_head() {
    let repo_dir = create_test_repo();
    let path = repo_dir.path();

    // Setup temporary log directory to capture errors
    let temp_log_dir = TempDir::new().unwrap();
    let original_xdg = env::var("XDG_STATE_HOME").ok();

    unsafe {
        env::set_var("XDG_STATE_HOME", temp_log_dir.path());
    }

    // Corrupt the .git/HEAD file with invalid content (too short to be valid)
    // Must be < 7 characters to trigger "Unknown HEAD format" error
    let head_path = path.join(".git").join("HEAD");
    fs::write(&head_path, "bad\n").unwrap();

    // Change to repo directory and run
    let original_dir = env::current_dir().unwrap();
    env::set_current_dir(path).unwrap();
    let result = run();
    env::set_current_dir(original_dir).unwrap();

    // Verify run() returns Err (graceful failure, not panic)
    assert!(
        result.is_err(),
        "run() should return Err for corrupted .git/HEAD"
    );

    // Log the error (mimicking what main() does)
    if let Err(e) = result {
        log_error(&e);
    }

    // Verify error was logged
    let expected_log = temp_log_dir
        .path()
        .join(APP_STATE_DIR)
        .join(ERROR_LOG_FILE);

    assert!(
        expected_log.exists(),
        "Error log file should be created after corruption error"
    );

    let content = fs::read_to_string(&expected_log).unwrap();
    assert!(
        !content.is_empty(),
        "Error log should contain error message"
    );
    assert!(
        content.contains("["),
        "Error log should contain timestamp prefix"
    );

    // Cleanup environment
    unsafe {
        match original_xdg {
            Some(val) => env::set_var("XDG_STATE_HOME", val),
            None => env::remove_var("XDG_STATE_HOME"),
        }
    }
}

#[test]
#[serial]
fn test_worktree_subdirectory_shows_only_worktree_name() {
    // Create a worktree-style setup with .bare directory
    let temp_dir = TempDir::new().unwrap();
    let path = temp_dir.path();

    // Create .bare directory and initialize as bare repo
    let bare_dir = path.join(".bare");
    fs::create_dir(&bare_dir).unwrap();

    Command::new("git")
        .args(["init", "--bare"])
        .current_dir(&bare_dir)
        .output()
        .unwrap();

    // Create a .git file pointing to .bare (simulating worktree setup)
    fs::write(path.join(".git"), "gitdir: .bare").unwrap();

    // Create a worktree with nested path name
    let worktree_dir = path.join("feat/work-config");
    Command::new("git")
        .args(["worktree", "add", "-b", "feat-work-config", "feat/work-config"])
        .current_dir(path)
        .output()
        .unwrap();

    // Configure git in the worktree
    Command::new("git")
        .args(["config", "user.name", "Test"])
        .current_dir(&worktree_dir)
        .output()
        .unwrap();

    Command::new("git")
        .args(["config", "user.email", "test@example.com"])
        .current_dir(&worktree_dir)
        .output()
        .unwrap();

    // Create initial commit
    fs::write(worktree_dir.join("test.txt"), "test").unwrap();
    Command::new("git")
        .args(["add", "."])
        .current_dir(&worktree_dir)
        .output()
        .unwrap();

    Command::new("git")
        .args(["commit", "-m", "initial"])
        .current_dir(&worktree_dir)
        .output()
        .unwrap();

    // Create nested subdirectories within the worktree
    let subdir = worktree_dir.join("nix").join("work-example");
    fs::create_dir_all(&subdir).unwrap();

    // Test from deep subdirectory - should show only worktree name, not full path
    let original_dir = env::current_dir().unwrap();
    env::set_current_dir(&subdir).unwrap();
    let result = run();
    env::set_current_dir(original_dir).unwrap();

    assert!(
        result.is_ok(),
        "run() should succeed in worktree subdirectory"
    );
    let output = result.unwrap();
    assert!(
        output.is_some(),
        "run() should return Some output for worktree subdirectory"
    );

    let output_text = output.unwrap();
    // Expected: Just the worktree name, NOT the subdirectory path
    // Since branch is "feat-work-config" and path is "feat/work-config",
    // they normalize to the same thing, so should show just tree icon
    assert_eq!(
        output_text, "🌳 feat/work-config",
        "Expected '🌳 feat/work-config' (worktree name only), got '{}'",
        output_text
    );
}
