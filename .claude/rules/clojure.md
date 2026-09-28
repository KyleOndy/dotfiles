---
paths: ["**/*.clj", "**/*.cljc", "**/*.bb", "deps.edn"]
---

# Clojure

`clojure -M:nrepl` starts an nREPL on port 7888. `clj-nrepl-eval -p 7888
'(+ 1 1)'` evaluates against it statelessly, and takes a heredoc for
multi-line forms. It and `clj-paren-repair` are on PATH only inside this
repo's devShell (`.envrc`). No hook config registers
`clj-paren-repair-claude-hook`, so nothing repairs delimiters after an edit;
run `clj-paren-repair <file>` by hand.
