(ns nix-closure-diff.git
  "Git operations for nix closure comparison"
  (:require
    [babashka.fs :as fs]
    [clojure.string :as str]
    [common.process :as proc]))


(defn validate-commit
  "Validate that a commit exists in the repository"
  [commit]
  (try
    (let [result (proc/run-command ["git" "rev-parse" "--verify" (str commit "^{commit}")])]
      (zero? (:exit result)))
    (catch Exception _
      false)))


(defn get-repo-root
  "Get the root directory of the git repository"
  []
  (-> (proc/run-command ["git" "rev-parse" "--show-toplevel"])
      :out
      str/trim))


(defn has-git-crypt?
  "Check if the repository uses git-crypt by looking for .gitattributes"
  [repo-path]
  (let [gitattributes-path (str (fs/path repo-path ".gitattributes"))]
    (and (fs/exists? gitattributes-path)
         (str/includes? (slurp gitattributes-path) "filter=git-crypt"))))


(defn git-crypt-unlocked?
  "Check if git-crypt is already unlocked in a directory"
  [repo-path]
  (try
    (let [result (proc/run-command ["git-crypt" "status"] :dir repo-path :throw? false)]
      (and (zero? (:exit result))
           (not (str/includes? (:out result) "encrypted"))))
    (catch Exception _
      false)))


(defn unlock-git-crypt
  "Unlock git-crypt in the specified directory"
  [repo-path]
  (when (has-git-crypt? repo-path)
    (println (str "Checking git-crypt status in " repo-path))
    ;; First check if already unlocked
    (if (git-crypt-unlocked? repo-path)
      (println "git-crypt already unlocked")
      (do
        (println (str "Unlocking git-crypt in " repo-path))
        ;; Try to unlock - git-crypt should work if GPG keys are available
        (let [result (proc/run-command ["git-crypt" "unlock"] :dir repo-path :throw? false)]
          (if (zero? (:exit result))
            (println "git-crypt unlock successful")
            (println (str "Warning: git-crypt unlock failed: " (:err result)))))))))


(defn create-worktree
  "Create a git worktree for the specified commit"
  [commit temp-dir]
  (let [worktree-path (fs/path temp-dir (str "worktree-" commit))
        main-repo-path (get-repo-root)]
    (println (str "Creating worktree for commit " commit " at " worktree-path))

    ;; Create worktree without checkout initially
    (proc/run-command ["git" "worktree" "add" "--no-checkout" (str worktree-path) commit])

    ;; Copy git-crypt state from main repo if it exists
    (when (has-git-crypt? main-repo-path)
      (let [main-git-crypt-dir (fs/path main-repo-path ".git" "git-crypt")
            ;; Get the actual git directory for the worktree
            worktree-git-dir (-> (proc/run-command ["git" "rev-parse" "--git-dir"] :dir (str worktree-path))
                                 :out str/trim)]
        (when (fs/exists? main-git-crypt-dir)
          (println "Copying git-crypt state to worktree")
          (proc/run-command ["cp" "-r" (str main-git-crypt-dir) worktree-git-dir]))))

    ;; Now checkout all files
    (proc/run-command ["git" "checkout" commit] :dir (str worktree-path))

    (str worktree-path)))


(defn remove-worktree
  "Remove a git worktree"
  [worktree-path]
  (when (fs/exists? worktree-path)
    (println (str "Removing worktree at " worktree-path))
    (proc/run-command ["git" "worktree" "remove" "--force" (str worktree-path)] :throw? false)))


(defn with-worktrees
  "Execute a function with worktrees for the specified commits"
  [commit-old commit-new f]
  (let [temp-dir (fs/create-temp-dir {:prefix "nix-closure-diff"})
        worktree-old-path (create-worktree commit-old temp-dir)
        worktree-new-path (create-worktree commit-new temp-dir)]
    (try
      (f worktree-old-path worktree-new-path)
      (finally
        (remove-worktree worktree-old-path)
        (remove-worktree worktree-new-path)
        (fs/delete-tree temp-dir)))))


(defn ensure-clean-state
  "Ensure the repository is in a clean state"
  []
  (let [status-result (proc/run-command ["git" "status" "--porcelain"])]
    (when (not (str/blank? (:out status-result)))
      (throw (ex-info "Repository has uncommitted changes. Please commit or stash changes before running comparison."
                      {:status (:out status-result)})))))


(defn validate-commits
  "Validate that both commits exist"
  [commit-old commit-new]
  (when-not (validate-commit commit-old)
    (throw (ex-info (str "Invalid old commit: " commit-old) {:commit commit-old})))
  (when-not (validate-commit commit-new)
    (throw (ex-info (str "Invalid new commit: " commit-new) {:commit commit-new}))))
