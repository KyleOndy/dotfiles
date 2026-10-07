use super::*;

fn icons() -> Icons {
    Icons {
        worktree: "🌳".into(),
        branch: "⎇".into(),
    }
}

fn scratch(test: &str) -> PathBuf {
    let dir = env::temp_dir().join(format!("git-worktree-prompt-{}-{test}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    canonical(&dir).unwrap()
}

/// Runs git with no user or system config, so the host's settings (a
/// default branch name, commit signing) cannot change what the tests see.
fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?} in {}: {}",
        dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
}

fn repo(dir: &Path, extra: &[&str]) {
    fs::create_dir_all(dir).unwrap();
    git(dir, &[&["init", "-q", "-b", "main"], extra].concat());
    git(dir, &["commit", "-q", "--allow-empty", "-m", "initial"]);
}

fn prompt(cwd: &Path) -> Option<String> {
    run(cwd, None, None, &icons()).unwrap()
}

fn head(test: &str, contents: &str) -> Result<String, String> {
    let dir = scratch(test);
    fs::write(dir.join("HEAD"), contents).unwrap();
    let got = branch(&dir, &dir);
    fs::remove_dir_all(dir).ok();
    got
}

#[test]
fn head_holds_a_branch_any_ref_or_an_object_id() {
    assert_eq!(
        head("branch", "ref: refs/heads/feature/x\n").unwrap(),
        "feature/x"
    );
    assert_eq!(
        head("remote", "ref: refs/remotes/origin/feat/deep\n").unwrap(),
        "remotes/origin/feat/deep"
    );
    assert_eq!(
        head("sha1", &format!("{}\n", "a1".repeat(20))).unwrap(),
        "a1a1a1a"
    );
    assert_eq!(head("sha256", &"b2".repeat(32)).unwrap(), "b2b2b2b");
}

#[test]
fn anything_else_in_head_is_an_error_not_a_hash_or_a_panic() {
    for contents in [
        "bad\n",
        "this is not a ref\n",
        "abcdeféxyz\n",
        "\0\0\0\0\0\0\0\0",
    ] {
        assert!(head("junk", contents).is_err(), "{contents:?}");
    }
}

#[test]
fn a_worktree_named_after_its_branch_shows_it_once() {
    let i = icons();
    assert_eq!(
        worktree("feature/cool-api", "feature/cool-api", &i),
        "🌳 feature/cool-api"
    );
    assert_eq!(
        worktree("DEV-123/fix-thing", "DEV-123-fix-thing", &i),
        "🌳 DEV-123/fix-thing"
    );
    assert_eq!(
        worktree("DEV-123/fix-thing", "main", &i),
        "🌳 DEV-123/fix-thing → ⎇ main"
    );
    let custom = Icons {
        worktree: "📁".into(),
        branch: String::new(),
    };
    assert_eq!(
        worktree("feature/test", "main", &custom),
        "📁 feature/test →  main"
    );
}

#[test]
fn a_plain_repository_shows_its_branch_from_any_subdirectory() {
    let dir = scratch("plain");
    repo(&dir, &[]);
    fs::create_dir_all(dir.join("a/b")).unwrap();
    assert_eq!(prompt(&dir).unwrap(), "⎇ main");
    assert_eq!(prompt(&dir.join("a/b")).unwrap(), "⎇ main");

    // An empty .git directory is not a repository, so the walk goes past it.
    fs::create_dir_all(dir.join("a/.git")).unwrap();
    assert_eq!(prompt(&dir.join("a/b")).unwrap(), "⎇ main");
    fs::remove_dir_all(dir).ok();
}

#[test]
fn outside_a_repository_there_is_nothing_to_show() {
    let dir = scratch("none");
    assert_eq!(prompt(&dir), None);
    fs::remove_dir_all(dir).ok();
}

#[test]
fn a_detached_head_shows_the_short_hash() {
    let dir = scratch("detached");
    repo(&dir, &[]);
    git(&dir, &["checkout", "-q", "--detach"]);
    let full = fs::read_to_string(dir.join(".git/HEAD")).unwrap();
    assert_eq!(prompt(&dir).unwrap(), format!("⎇ {}", &full[..7]));
    fs::remove_dir_all(dir).ok();
}

#[test]
fn a_reftable_repository_asks_git_for_the_branch() {
    let dir = scratch("reftable");
    repo(&dir, &["--ref-format=reftable"]);
    git(&dir, &["checkout", "-q", "-b", "feature/reftable"]);
    assert_eq!(prompt(&dir).unwrap(), "⎇ feature/reftable");
    fs::remove_dir_all(dir).ok();
}

#[test]
fn git_dir_from_the_environment_is_used() {
    let dir = scratch("env");
    repo(&dir.join("repo"), &[]);
    let out = run(&dir, Some("repo/.git".into()), None, &icons()).unwrap();
    assert_eq!(out.unwrap(), "⎇ main");
    fs::remove_dir_all(dir).ok();
}

#[test]
fn the_bare_layout_names_worktrees_and_nothing_else() {
    let root = scratch("bare");
    git(&root, &["init", "-q", "--bare", "-b", "main", ".bare"]);
    fs::write(root.join(".git"), "gitdir: .bare\n").unwrap();
    git(&root, &["worktree", "add", "-q", "main"]);
    git(
        &root.join("main"),
        &["commit", "-q", "--allow-empty", "-m", "initial"],
    );
    git(
        &root,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "feat-work-config",
            "feat/work-config",
        ],
    );
    git(
        &root,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "feature/cool-api",
            "feature/cool-api",
        ],
    );
    git(&root, &["worktree", "add", "-q", "-b", "x", "a/b/c/deep"]);
    fs::create_dir_all(root.join("feat/work-config/nix/deep")).unwrap();
    let elsewhere = scratch("bare-elsewhere").join("wt");
    git(
        &root,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "elsewhere",
            elsewhere.to_str().unwrap(),
        ],
    );
    repo(&root.join("main/scratch/other"), &[]);
    git(
        &root.join("main/scratch/other"),
        &["checkout", "-q", "-b", "other"],
    );

    assert_eq!(prompt(&root).unwrap(), "🌳 [bare]");
    assert_eq!(prompt(&root.join(".bare")).unwrap(), "🌳 [bare]");
    assert_eq!(prompt(&root.join("main")).unwrap(), "🌳 main");
    assert_eq!(
        prompt(&root.join("feat/work-config/nix/deep")).unwrap(),
        "🌳 feat/work-config"
    );
    assert_eq!(
        prompt(&root.join("feature/cool-api")).unwrap(),
        "🌳 feature/cool-api"
    );
    assert_eq!(
        prompt(&root.join("a/b/c/deep")).unwrap(),
        "🌳 a/b/c/deep → ⎇ x"
    );
    assert_eq!(prompt(&root.join("main/scratch/other")).unwrap(), "⎇ other");
    assert_eq!(prompt(&elsewhere).unwrap(), "⎇ elsewhere");
    fs::remove_dir_all(root).ok();
    fs::remove_dir_all(elsewhere.parent().unwrap()).ok();
}
