(ns nix-closure-diff.comparison
  "Package comparison logic for nix closures"
  (:require
    [clojure.set :as set]))


(defn normalize-package-key
  "Create a consistent key for package identification"
  [package]
  [(:name package) (:version package)])


(defn normalize-package-name-key
  "Create a key based only on package name"
  [package]
  (:name package))


(defn packages-to-map
  "Convert package list to a map keyed by [name version]"
  [packages]
  (into {} (map #(vector (normalize-package-key %) %) packages)))


(defn packages-by-name
  "Group packages by name"
  [packages]
  (group-by :name packages))


(defn compare-package-sets
  "Compare two sets of packages and return added/removed/changed"
  [old-packages new-packages]
  (let [old-map (packages-to-map old-packages)
        new-map (packages-to-map new-packages)
        old-keys (set (keys old-map))
        new-keys (set (keys new-map))

        added-keys (set/difference new-keys old-keys)
        removed-keys (set/difference old-keys new-keys)

        ;; For version changes, look at packages with same name but different versions
        old-by-name (packages-by-name old-packages)
        new-by-name (packages-by-name new-packages)

        all-names (set/union (set (keys old-by-name))
                             (set (keys new-by-name)))

        version-changes (for [name all-names
                              :let [old-versions (set (map :version (get old-by-name name [])))
                                    new-versions (set (map :version (get new-by-name name [])))
                                    old-pkg (first (get old-by-name name))
                                    new-pkg (first (get new-by-name name))]
                              :when (and old-pkg new-pkg
                                         (not= old-versions new-versions)
                                         ;; Only include if the package name exists in both
                                         (contains? old-by-name name)
                                         (contains? new-by-name name))]
                          {:name name
                           :old-versions old-versions
                           :new-versions new-versions
                           :old-package old-pkg
                           :new-package new-pkg})

        ;; Get names of packages that had version changes
        version-changed-names (set (map :name version-changes))

        ;; Filter out packages from added/removed that are actually version changes
        truly-added-keys (filter #(not (contains? version-changed-names (first %))) added-keys)
        truly-removed-keys (filter #(not (contains? version-changed-names (first %))) removed-keys)]

    {:added (map new-map truly-added-keys)
     :removed (map old-map truly-removed-keys)
     :version-changes version-changes
     :stats {:total-old (count old-packages)
             :total-new (count new-packages)
             :added-count (count truly-added-keys)
             :removed-count (count truly-removed-keys)
             :version-changes-count (count version-changes)}}))


(defn compare-systems
  "Compare package data between two system builds"
  [old-data new-data systems]
  (into {}
        (for [system systems
              :let [old-system-data (get old-data system)
                    new-system-data (get new-data system)]
              :when (and old-system-data new-system-data)]
          [system (if (and (:error old-system-data) (:error new-system-data))
                    {:error "Both builds failed"
                     :old-error (:error old-system-data)
                     :new-error (:error new-system-data)}
                    (if (:error old-system-data)
                      {:error "Old build failed" :details (:error old-system-data)}
                      (if (:error new-system-data)
                        {:error "New build failed" :details (:error new-system-data)}
                        (compare-package-sets (:packages old-system-data)
                                              (:packages new-system-data)))))])))


(defn calculate-summary-stats
  "Calculate summary statistics across all systems"
  [comparison-data]
  (let [successful-comparisons (filter #(not (:error (val %))) comparison-data)
        total-added (reduce + 0 (map #(get-in (val %) [:stats :added-count] 0) successful-comparisons))
        total-removed (reduce + 0 (map #(get-in (val %) [:stats :removed-count] 0) successful-comparisons))
        total-version-changes (reduce + 0 (map #(get-in (val %) [:stats :version-changes-count] 0) successful-comparisons))
        systems-with-errors (count (filter #(:error (val %)) comparison-data))]
    {:total-systems (count comparison-data)
     :successful-systems (count successful-comparisons)
     :systems-with-errors systems-with-errors
     :total-packages-added total-added
     :total-packages-removed total-removed
     :total-version-changes total-version-changes}))
