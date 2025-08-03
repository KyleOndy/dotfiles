(ns nix-closure-diff.nix
  "Nix build and closure operations"
  (:require
    [cheshire.core :as json]
    [clojure.string :as str]
    [common.process :as proc]))


(defn build-system-closure
  "Build the closure for a specific system configuration from a git commit"
  [repo-path commit system]
  (println (str "Building closure for system: " system " from commit " commit))
  (let [flake-ref (str "git+file://" repo-path "?ref=" commit "#nixosConfigurations." system ".config.system.build.toplevel")
        build-result (proc/run-command ["nix" "build" "--no-link" "--print-out-paths" flake-ref]
                                       :timeout 300000)] ; 5 minute timeout
    (if (zero? (:exit build-result))
      (str/trim (:out build-result))
      (throw (ex-info (str "Failed to build system: " system " from commit " commit)
                      {:system system
                       :commit commit
                       :exit-code (:exit build-result)
                       :stderr (:err build-result)})))))


(defn get-closure-paths
  "Get all paths in the closure of a built system"
  [system-path]
  (println (str "Getting closure paths for: " system-path))
  (let [result (proc/run-command ["nix" "path-info" "-r" system-path])]
    (if (zero? (:exit result))
      (str/split-lines (:out result))
      (throw (ex-info "Failed to get closure paths"
                      {:system-path system-path
                       :exit-code (:exit result)
                       :stderr (:err result)})))))


(defn parse-store-path
  "Parse a Nix store path to extract package name and version"
  [store-path]
  (let [basename (last (str/split store-path #"/"))
        ;; Handle paths like /nix/store/hash-name-version
        ;; Remove the hash prefix (32 chars + dash)
        without-hash (if (and (> (count basename) 33)
                              (= (nth basename 32) \-))
                       (subs basename 33)
                       basename)
        ;; Try to split name and version
        parts (str/split without-hash #"-")
        ;; Find version-like parts (contain digits)
        version-idx (first (keep-indexed
                             #(when (re-find #"\d" %2) %1)
                             parts))
        name (if version-idx
               (str/join "-" (take version-idx parts))
               without-hash)
        version (if version-idx
                  (str/join "-" (drop version-idx parts))
                  "unknown")]
    {:store-path store-path
     :name (if (str/blank? name) without-hash name)
     :version (if (str/blank? version) "unknown" version)
     :full-name without-hash}))


(defn get-system-packages
  "Get package information for a system from a git commit"
  [repo-path commit system]
  (try
    (let [system-path (build-system-closure repo-path commit system)
          closure-paths (get-closure-paths system-path)
          packages (map parse-store-path closure-paths)]
      {:system system
       :commit commit
       :system-path system-path
       :package-count (count packages)
       :packages packages})
    (catch Exception e
      (println (str "Warning: Failed to process system " system " from commit " commit ": " (.getMessage e)))
      {:system system
       :commit commit
       :error (.getMessage e)
       :packages []})))


(defn get-all-systems-packages
  "Get package information for all specified systems from a git commit"
  [repo-path commit systems]
  (println (str "Processing " (count systems) " systems from commit " commit))
  (into {}
        (for [system systems]
          [system (get-system-packages repo-path commit system)])))


(defn validate-nix-available
  "Validate that Nix is available and flakes are enabled"
  []
  (try
    (proc/run-command ["nix" "--version"])
    (catch Exception _
      (throw (ex-info "Nix is not available in PATH" {})))))
