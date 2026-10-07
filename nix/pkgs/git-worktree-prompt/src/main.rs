//! Branch, or worktree and branch, for the starship prompt. Reads the files
//! git keeps rather than running git, except in a reftable repository.
//!
//! Prints nothing outside a repository, and nothing on error: a broken git
//! state must not break the shell. `--debug` puts the error on stderr.

use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Icons {
    worktree: String,
    branch: String,
}

fn main() {
    let debug = env::args().any(|a| a == "--debug");
    let icons = Icons {
        worktree: env::var("GIT_WORKTREE_PROMPT_WORKTREE_ICON").unwrap_or_else(|_| "🌳".into()),
        branch: env::var("GIT_WORKTREE_PROMPT_BRANCH_ICON").unwrap_or_else(|_| "⎇".into()),
    };
    let result = env::current_dir()
        .map_err(|e| format!("current directory: {e}"))
        .and_then(|cwd| {
            run(
                &cwd,
                env::var_os("GIT_DIR"),
                env::var_os("GIT_WORK_TREE"),
                &icons,
            )
        });
    match result {
        Ok(Some(text)) => print!("{text}"),
        Ok(None) => {}
        Err(e) if debug => eprintln!("git-worktree-prompt: {e}"),
        Err(_) => {}
    }
}

/// The prompt for `cwd`, or None outside a repository. `git_dir` and
/// `work_tree` are GIT_DIR and GIT_WORK_TREE, relative to `cwd` as git reads
/// them.
fn run(
    cwd: &Path,
    git_dir: Option<OsString>,
    work_tree: Option<OsString>,
    icons: &Icons,
) -> Result<Option<String>, String> {
    let (git_dir, work_dir) = match git_dir {
        Some(dir) => (
            cwd.join(dir),
            work_tree.map_or_else(|| cwd.to_path_buf(), |w| cwd.join(w)),
        ),
        None => match discover(cwd)? {
            Some(found) => found,
            None => return Ok(None),
        },
    };

    // The layout this exists for is a bare clone in `.bare` with one worktree
    // per branch beside it. A repository belongs to it when its common
    // directory is that `.bare`, which a clone or a submodule nested inside a
    // worktree never is.
    let common = common_dir(&git_dir)?;
    if common.file_name().is_none_or(|n| n != ".bare") {
        return Ok(Some(format!(
            "{} {}",
            icons.branch,
            branch(&git_dir, &work_dir)?
        )));
    }
    let root = common.parent().ok_or("`.bare` has no parent")?;
    let work_dir = canonical(&work_dir)?;
    // A worktree added outside the root has no place in the layout to name.
    let Ok(name) = work_dir.strip_prefix(root) else {
        return Ok(Some(format!(
            "{} {}",
            icons.branch,
            branch(&git_dir, &work_dir)?
        )));
    };
    let name = name.to_string_lossy().into_owned();
    if name.is_empty() {
        return Ok(Some(format!("{} [bare]", icons.worktree)));
    }
    Ok(Some(worktree(&name, &branch(&git_dir, &work_dir)?, icons)))
}

/// The git directory and work tree for `cwd`, walking up as git does. An
/// empty `.git` directory is not a repository and the walk goes on past it;
/// a `.git` file is taken at its word, as git does.
fn discover(cwd: &Path) -> Result<Option<(PathBuf, PathBuf)>, String> {
    for dir in cwd.ancestors() {
        let dot_git = dir.join(".git");
        if dot_git.is_file() {
            return Ok(Some((gitdir_from_file(&dot_git)?, dir.to_path_buf())));
        }
        if dot_git.join("HEAD").is_file() {
            return Ok(Some((dot_git, dir.to_path_buf())));
        }
    }
    Ok(None)
}

/// A `.git` file holds `gitdir: <path>`, relative to the file's directory.
fn gitdir_from_file(file: &Path) -> Result<PathBuf, String> {
    let text = read(file)?;
    let target = text
        .strip_prefix("gitdir: ")
        .ok_or_else(|| format!("{}: no gitdir line", file.display()))?;
    Ok(file.parent().unwrap_or(Path::new("/")).join(target.trim()))
}

/// A linked worktree's `commondir` names the repository it belongs to,
/// relative to its own git directory; without one the git directory is its
/// own common directory.
fn common_dir(git_dir: &Path) -> Result<PathBuf, String> {
    let common = match fs::read_to_string(git_dir.join("commondir")) {
        Ok(rel) => git_dir.join(rel.trim()),
        Err(_) => git_dir.to_path_buf(),
    };
    canonical(&common)
}

fn canonical(path: &Path) -> Result<PathBuf, String> {
    fs::canonicalize(path).map_err(|e| format!("{}: {e}", path.display()))
}

fn read(path: &Path) -> Result<String, String> {
    fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
}

/// The branch, or for a detached HEAD the first seven hex digits of the
/// commit. Anything else in HEAD is an error, as it is to git.
fn branch(git_dir: &Path, work_dir: &Path) -> Result<String, String> {
    let head_path = git_dir.join("HEAD");
    let head = read(&head_path)?;
    let head = head.trim();
    // The reftable backend leaves this fixed stub in HEAD (git v2.54.0,
    // refs.c), so only git itself can say where HEAD points.
    if head == "ref: refs/heads/.invalid" {
        return branch_from_git(work_dir);
    }
    if let Some(name) = head.strip_prefix("ref: refs/") {
        return Ok(name.strip_prefix("heads/").unwrap_or(name).to_owned());
    }
    // 40 hex digits for SHA-1, 64 for SHA-256.
    if matches!(head.len(), 40 | 64) && head.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Ok(head[..7].to_owned());
    }
    Err(format!(
        "{}: neither a ref nor an object id",
        head_path.display()
    ))
}

fn branch_from_git(work_dir: &Path) -> Result<String, String> {
    let git = |args: &[&str]| {
        let out = Command::new("git")
            .args(args)
            .current_dir(work_dir)
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        (out.status.success() && !text.is_empty()).then_some(text)
    };
    git(&["symbolic-ref", "-q", "--short", "HEAD"])
        .or_else(|| git(&["rev-parse", "--short", "HEAD"]))
        .ok_or_else(|| format!("git cannot resolve HEAD in {}", work_dir.display()))
}

/// The branch is left off when the worktree is named after it, exactly or
/// with its slashes flattened to hyphens.
fn worktree(name: &str, branch: &str, icons: &Icons) -> String {
    if name == branch || name.replace('/', "-") == branch {
        format!("{} {name}", icons.worktree)
    } else {
        format!("{} {name} → {} {branch}", icons.worktree, icons.branch)
    }
}

#[cfg(test)]
mod tests;
