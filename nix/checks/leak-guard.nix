# Flake check for leak-guard (nix/pkgs/leak-guard): the matcher's three forms,
# token boundaries, the commit-msg and pre-push hooks through real git, the
# deny-list's freshness rule and grow-only refresh.
#
# The fixtures name a made-up provider and model. The public names
# (claude-sonnet-4-5, gpt-4.1, google/gemini-3.1-pro-preview) are in pi's
# built-in catalog, which is the point of using them.
{ pkgs }:
pkgs.runCommand "leak-guard-check"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.leak-guard
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail
    fail() {
      echo "FAIL: $*" >&2
      cat "$T/out" >&2 2>/dev/null || true
      exit 1
    }

    T=$TMPDIR/lg
    export HOME=$T/home
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    mkdir -p "$HOME/.local/state/leak-guard" "$T"
    DENY=$HOME/.local/state/leak-guard/deny
    printf '%s\n' fakecloud/acme/zeta-9000 fakecloud/acme/claude-sonnet-4-5 fakecloud/gpt-4.1 \
      fakecloud/google/gemini-3.1-pro-preview >"$DENY"

    refuses() { # <entry> <message>
      printf '%s\n' "$2" >"$T/msg"
      if leak-guard msg "$T/msg" >"$T/out" 2>&1; then fail "passed: $2"; fi
      grep -q "deny-list entry $1\$" "$T/out" || fail "no entry $1 for: $2"
      if grep -qi 'zeta\|acme' "$T/out"; then fail "output names the entry: $2"; fi
    }
    passes() { # <message>
      printf '%s\n' "$1" >"$T/msg"
      leak-guard msg "$T/msg" >"$T/out" 2>&1 || fail "refused: $1"
    }

    git init -q -b main "$T/repo"
    cd "$T/repo"

    # A name pi doesn't carry matches bare, anywhere a token can end.
    refuses 1 'try zeta-9000 next'
    refuses 1 'ZETA-9000'
    refuses 1 'fakecloud/acme/zeta-9000:high'
    refuses 1 'other/zeta-9000'
    refuses 1 'ends a sentence with zeta-9000.'
    passes 'zeta-90001'
    passes 'xzeta-9000'
    passes 'zeta-9000.5'
    refuses 1 'zeta-9000.md'
    passes 'zeta-9000_b'
    refuses 1 'Zeta 9000'
    refuses 1 'zeta_9000'
    refuses 1 'zeta9000'

    # A public name matches only next to its org, or on a line that also
    # names the provider. An org/name pi carries still matches.
    passes 'claude-sonnet-4-5 is public'
    refuses 2 'acme/claude-sonnet-4-5'
    refuses 2 'Acme/Claude Sonnet 4.5'
    refuses 2 'fakecloud/claude-sonnet-4-5:xhigh'
    refuses 2 'fakecloud/other/claude-sonnet-4-5'
    refuses 2 'claude-sonnet-4-5, served by fakecloud'
    passes $'fakecloud serves it\nclaude-sonnet-4-5 is public'
    passes 'superfakecloud claude-sonnet-4-5'
    passes 'gpt-4.1 is public'
    refuses 3 'fakecloud/gpt-4.1'
    refuses 3 'fakecloud runs gpt-4.1'
    passes 'gemini-3.1-pro-preview'
    refuses 4 'google/gemini-3.1-pro-preview'

    # A comment line counts, since `commit -m` keeps it. The `commit -v` diff
    # below the scissors does not.
    refuses 1 $'subject\n# zeta-9000 in a comment'
    passes $'subject\n# ------------------------ >8 ------------------------\n-zeta-9000'

    # The staged diff: added lines, not removed ones, and the path.
    printf 'zeta-9000\n' >f.txt
    git add f.txt
    refuses 1 'clean subject'
    grep -q 'staged f.txt:1: deny-list entry 1' "$T/out" || fail "staged hit without its location"
    git commit -q --no-verify -m seed
    printf 'other\n' >f.txt
    git add f.txt
    passes 'removing it is fine'
    git commit -q --no-verify -m clean
    printf 'x\n' >zeta-9000.md
    git add zeta-9000.md
    refuses 1 'clean subject'
    git rm -q --cached zeta-9000.md
    rm zeta-9000.md

    # Binary blobs, git-crypt's included, are skipped.
    printf 'zeta-9000\0\n' >blob.bin
    git add blob.bin
    passes 'binary'
    git commit -q --no-verify -m binary

    # No list: commits go through with a warning.
    mv "$DENY" "$T/deny.saved"
    passes 'zeta-9000'
    grep -q 'no deny-list' "$T/out" || fail "no warning without a list"
    mv "$T/deny.saved" "$DENY"

    # Through the installed hooks.
    leak-guard install >/dev/null
    printf 'x\n' >g.txt
    git add g.txt
    if git commit -q -m 'zeta-9000' >"$T/out" 2>&1; then fail "commit-msg hook let it through"; fi
    git commit -q -m 'clean' >"$T/out" 2>&1 || fail "commit-msg hook refused a clean commit"
    echo foreign >"$(git rev-parse --git-path hooks)/pre-push"
    if leak-guard install >"$T/out" 2>&1; then fail "install overwrote a foreign hook"; fi
    rm "$(git rev-parse --git-path hooks)/pre-push"
    leak-guard install >/dev/null

    # pre-push: everything origin lacks, nothing it has.
    git init -q --bare "$T/origin.git"
    git remote add origin "$T/origin.git"
    git push -q --no-verify origin main 2>/dev/null
    git fetch -q origin
    pushes() { git push -q origin "$@" >"$T/out" 2>&1; }

    git switch -q -c feature
    git commit -q --no-verify --allow-empty -m 'zeta-9000 in a message'
    if pushes feature; then fail "pushed a message hit"; fi
    grep -q 'message line 1: deny-list entry 1' "$T/out" || fail "message hit without its location"
    git reset -q --hard origin/main

    printf 'zeta-9000\n' >h.txt
    git add h.txt
    git commit -q --no-verify -m add
    git rm -q h.txt
    git commit -q --no-verify -m remove
    if pushes feature; then fail "pushed an id added and removed within the push"; fi
    git reset -q --hard origin/main

    git commit -q --no-verify --allow-empty -m 'clean'
    pushes feature || fail "refused a clean push"
    git fetch -q origin

    if pushes feature:refs/heads/zeta-9000; then fail "pushed a ref name hit"; fi
    git branch -q modular
    if pushes modular; then fail "pushed a protected branch"; fi
    git branch -q -D modular

    # Freshness, only where models.json names mcloud. The baseUrl goes
    # nowhere, so every refresh fails.
    mkdir -p "$HOME/.pi/agent"
    printf '{"providers":{"mcloud":{"baseUrl":"http://127.0.0.1:9/v1","models":[]}}}\n' >"$HOME/.pi/agent/models.json"
    export MCLOUD_API_KEY=k
    git commit -q --no-verify --allow-empty -m 'clean again'
    pushes feature || fail "refused with a fresh list and no network"
    grep -q 'checking against' "$T/out" || fail "no warning about the failed refresh"
    git commit -q --no-verify --allow-empty -m 'clean, later'
    touch -d '8 days ago' "$DENY"
    if pushes feature; then fail "pushed against a stale list"; fi
    mv "$DENY" "$T/deny.saved"
    if pushes feature; then fail "pushed with no list"; fi
    mv "$T/deny.saved" "$DENY"

    # refresh grows the list and never renumbers it. Each endpoint's host
    # joins it, loopback aside.
    printf '{"providers":{"other":{"baseUrl":"http://localhost:11434/v1","models":[{"id":"zeta-9001"},{"id":"acme/zeta-9000"}]},"loop":{"baseUrl":"http://127.0.0.1:9/v1"},"fakecloud":{"baseUrl":"https://gw.fakecloud.test/v1","models":[{"id":"acme/zeta-9000"}]}}}\n' >"$HOME/.pi/agent/models.json"
    leak-guard refresh >"$T/out" 2>&1 || fail "refresh failed"
    grep -q '7 entries, 3 new' "$T/out" || fail "refresh counts: $(cat "$T/out")"
    [ "$(sed -n 1p "$DENY")" = fakecloud/acme/zeta-9000 ] || fail "refresh reordered the list"
    [ "$(sed -n 5p "$DENY")" = gw.fakecloud.test ] || fail "refresh missed the endpoint host: $(cat "$DENY")"
    if grep -q 'localhost\|127\.0\.0\.1' "$DENY"; then fail "refresh listed a loopback host"; fi
    [ "$(stat -c %a "$DENY")" = 600 ] || fail "deny-list is not 0600"
    refuses 5 'curl https://gw.fakecloud.test/v1/models'
    passes 'fakecloud.test and gw.fakecloud.testing'

    touch "$out"
  ''
