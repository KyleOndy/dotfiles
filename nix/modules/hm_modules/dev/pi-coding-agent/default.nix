# pi.dev coding agent with optional OS-level sandboxing.
#
# Sandbox wrapper flags (prepend before pi args):
#   --allow HOST           add domain to network allowlist (repeatable)
#   --allow-write PATH     add extra FS write path (repeatable)
#   --allow-read PATH      add extra FS read path (repeatable)
#   --web                  network unrestricted; reads and writes stay on
#                          the strict-mode allowlist
#   --no-sandbox           bypass sandbox entirely (with warning)
#   --allow-git-write      grant git-dir write on any branch (agent can commit)
#   --no-git-write         withhold it on every branch
#   --allow-nix            nix daemon socket + channel search path, eval cache
#                          and profile; asks the daemon whether this client is
#                          trusted and warns loudly when it is, since a trusted
#                          client builds as root outside the sandbox
#   --allow-docker         docker daemon socket + ~/.docker
#   --allow-ssh-agent      ssh-agent socket + ~/.ssh/{config,known_hosts,*.pub},
#                          so ssh authenticates without the private keys ever
#                          becoming readable
#   --allow-<toolchain>    go / rust / node / python / java / clojure: that
#                          toolchain's registries, plus for java and clojure
#                          the package caches under $HOME (~/.m2, ~/.clojure,
#                          ~/.gitlibs) that default-deny would otherwise hide
#   --allow-kagi           kagi.com, so `kagi search` and `kagi read` work.
#                          Reading a page goes through Kagi's extractor, so
#                          this covers research without --web
#   --allow-flake          github.com, codeload.github.com, gitlab.com and
#                          flakehub: the hosts flake inputs fetch from.
#                          Pairs with --allow-nix, since input fetching
#                          happens in the client, behind the proxy
#
# Every --allow-* grant is also recorded in the exported PI_GRANTS var, which
# extensions/grants.ts turns into per-grant system prompt sections from
# sourceDir/grants/<name>.md, so the agent learns what a grant costs at the
# moment it gains it.
#
# Strict mode uses pkgs.llm-agents.sandbox-runtime (srt) on both platforms:
# bwrap on Linux, sandbox-exec on macOS; proxy-based network allowlist.
# Both network AND filesystem reads are default-deny: the allowlist starts
# empty, and reads are denied from "/" down, leaving CWD, ~/.pi, the per-platform
# system paths in pi-wrapper's defaultSystemReadPaths, and
# sandbox.allowedReadPaths / --allow-read. That covers the temp trees a $HOME-only
# deny leaves open (/private/tmp, /private/var/folders, /Volumes), which carry
# $HOME content often enough to matter. Add toolchain read paths (~/.gitconfig,
# ~/.cargo, ...) as needed.
#
# Hardening defaults applied in every mode (see wrapper.sh), all overridable
# via sandbox.envVars:
#   - git: commit/tag signing off, core.hooksPath=/dev/null, fsmonitor/sshCommand
#     off (a hostile repo's hooks/config can't run code under the agent's git).
#     denyWrite also traps hooks, config and .gitmodules in strict mode, on the
#     git dirs as `git rev-parse` resolves them, so the traps still land in a
#     worktree layout where $PWD/.git is only a pointer file. Those dirs are
#     always readable (git is unusable otherwise) and writable only per
#     `sandbox.gitWrite`.
#   - supply chain: npm/yarn lifecycle scripts blocked (npm_config_ignore_scripts);
#     NODE_OPTIONS stripped of code-injection flags (--require/--import/...).
#   - secrets: env vars whose names look secret-bearing (*_TOKEN/_SECRET/...) are
#     scrubbed unless injected via the wrapper's envFromCommands, sandbox.envVars,
#     or a known provider key.
#   - caches: GOCACHE/CARGO_HOME/npm_config_cache/... redirected under
#     ~/.pi/sandbox-cache so default-deny FS doesn't break compilers (cold caches
#     are the tradeoff; for warm caches add the real dir to the wrapper's
#     default{Read,Write}Paths).
#
# Web mode (no domain restriction) bypasses srt, since srt forbids wildcard domains.
# Linux: bwrap directly (FS isolation, no --unshare-net).
# macOS: sandbox-exec FS profile (network unrestricted).
#
# Wrapper implementation lives in nix/pkgs/pi-wrapper so it can be reused by
# the flake check at nix/checks/pi-coding-agent.nix.
#
# Extension, agent, theme, keybinding and AGENTS.md sources at
# nix/modules/hm_modules/dev/pi/ are symlinked via mkOutOfStoreSymlink into
# ~/.pi/agent/, not copied into the nix store. Pi's /reload hot-swaps extensions/skills/keybindings at runtime, it
# reloads the active theme file on write, and any file pi writes round-trips
# back into git. sourceDir defaults to the worktree you ran `make` from. See
# DOTFILES_WORKTREE in Makefile and the dotfilesWorktree binding in flake.nix.
# Each worktree symlinks to its own tree, so branch-based edits surface
# immediately without colliding.
{
  lib,
  pkgs,
  config,
  inputs,
  dotfiles-worktree,
  ...
}:
let
  cfg = config.hmFoundry.dev.pi-coding-agent;

  piPackage =
    if cfg.sandbox.enable then
      # The knobs a host actually turns; the wrapper's own defaults cover
      # the rest. trustd stays off, as do --allow-nix and --allow-docker.
      # Widen those at nix/pkgs/pi-wrapper/default.nix, or per-invocation
      # with the wrapper's --allow-trustd / --allow-nix / --allow-docker.
      #
      # sourceDir is always readable: srt checks a symlink's resolved
      # target, and the extension and theme links below resolve into a
      # worktree that the blanket $HOME deny would otherwise hide.
      pkgs.pi-wrapper.override {
        defaultDomains = cfg.sandbox.allowedDomains;
        defaultEnvVars = cfg.sandbox.envVars;
        defaultPiArgs = cfg.sandbox.defaultArgs;
        defaultAllowLoopback = cfg.sandbox.allowLocalBinding;
        defaultReadPaths = cfg.sandbox.allowedReadPaths ++ [ cfg.sourceDir ];
        defaultWritePaths = cfg.sandbox.allowedWritePaths;
        gitWriteMode = cfg.sandbox.gitWrite;
        protectedBranches = cfg.sandbox.protectedBranches;
        networkBundles = cfg.sandbox.networkBundles;
        envFromCommands = cfg.sandbox.envFromCommands;
        gitAuthorName = cfg.sandbox.gitIdentity.name;
        gitAuthorEmail = cfg.sandbox.gitIdentity.email;
      }
    else
      pkgs.llm-agents.pi;

  defaultSourceDir =
    if dotfiles-worktree != null then
      "${dotfiles-worktree}/nix/modules/hm_modules/dev/pi"
    else
      throw ''
        hmFoundry.dev.pi-coding-agent: cannot resolve sourceDir.
        DOTFILES_WORKTREE is unset (or the flake is being evaluated in
        pure mode). Build via the Makefile targets (which export it and
        pass --impure), or set
        `hmFoundry.dev.pi-coding-agent.sourceDir` explicitly.
      '';

  claudeCfg = config.hmFoundry.dev.claude-code;
  sharedSkillsDir = ../claude-code/skills;

  # Sourced from the flake input rather than sharedSkillsDir, matching how the
  # claude-code module installs it.
  flakeSkills = {
    ".pi/agent/skills/ponytail/SKILL.md".source =
      "${inputs.claude-skills-ponytail}/skills/ponytail/SKILL.md";
    ".pi/agent/skills/ponytail-audit/SKILL.md".source =
      "${inputs.claude-skills-ponytail}/skills/ponytail-audit/SKILL.md";
    ".pi/agent/skills/ponytail-debt/SKILL.md".source =
      "${inputs.claude-skills-ponytail}/skills/ponytail-debt/SKILL.md";
    ".pi/agent/skills/ponytail-gain/SKILL.md".source =
      "${inputs.claude-skills-ponytail}/skills/ponytail-gain/SKILL.md";
    ".pi/agent/skills/ponytail-review/SKILL.md".source =
      "${inputs.claude-skills-ponytail}/skills/ponytail-review/SKILL.md";
  };

  repoSkills =
    lib.mapAttrs'
      (
        fname: _: lib.nameValuePair ".pi/agent/skills/${fname}" { source = "${sharedSkillsDir}/${fname}"; }
      )
      (
        lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir sharedSkillsDir)
      );

  hostSkills = lib.listToAttrs (
    map (
      skill:
      if skill.isFile then
        lib.nameValuePair ".pi/agent/skills/${skill.name}/SKILL.md" { source = skill.source; }
      else
        lib.nameValuePair ".pi/agent/skills/${skill.name}" { source = skill.source; }
    ) claudeCfg.skills
  );
in
{
  options.hmFoundry.dev.pi-coding-agent = {
    enable = lib.mkEnableOption "pi coding agent";

    sourceDir = lib.mkOption {
      type = lib.types.str;
      default = defaultSourceDir;
      defaultText = lib.literalExpression "\${dotfiles-worktree}/nix/modules/hm_modules/dev/pi";
      description = ''
        Absolute path in the dotfiles working tree containing pi's
        symlinked config (extensions/, agents/, themes/,
        keybindings.json). mkOutOfStoreSymlink points ~/.pi/agent/extensions,
        ~/.pi/agent/agents, ~/.pi/agent/themes and
        ~/.pi/agent/keybindings.json at the matching entries, so /reload
        picks up extension, agent and keybinding edits and pi's own theme
        hot-reload picks up palette edits, all without a
        home-manager rebuild. Defaults to the worktree captured at
        make-time via DOTFILES_WORKTREE; override per-host if you need a
        different path.
      '';
    };

    sandbox = {
      enable = lib.mkEnableOption "sandbox pi via OS-level primitives" // {
        default = true;
      };

      envVars = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        example = {
          GOCACHE = "$PWD/.gocache";
          GOMODCACHE = "$PWD/.gomodcache";
        };
        description = ''
          Static env vars exported into pi's environment by the wrapper
          before sandbox dispatch. Values are bash double-quote-expanded at
          runtime, so $PWD / $HOME resolve to the user's CWD-at-invocation
          and home directory.

          Use this to redirect tool caches (Go, Rust, npm) into CWD-relative
          paths the sandbox's allowWrite already covers, instead of
          broadening allowWrite to $HOME/Library/Caches/* directories.

          Distinct from the wrapper's own envFromCommands: envVars are
          literal strings (only bash double-quote expansion runs), where
          envFromCommands resolves a command's stdout. Secrets belong in
          envFromCommands, plain config here.
        '';
      };

      envFromCommands = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        example = {
          OPENROUTER_API_KEY = "security find-generic-password -s pi -a openrouter -w";
        };
        description = ''
          Env vars resolved by the wrapper outside the sandbox before pi
          execs. Each value is a shell command; its stdout (trailing newline
          stripped by command substitution) becomes the env var, exported
          into pi's environment.

          Use this to inject API keys from macOS Keychain, pass, sops, etc.,
          so pi's models.json can reference them via "!printenv VAR" without
          granting the sandbox read access to credential paths or network
          access to a secrets backend.

          Resolver failure (non-zero exit) aborts pi startup with a
          diagnostic on stderr. Resolvers are not cached; keep them cheap
          (Keychain lookups are sub-10ms; avoid kubectl-per-run).

          Note: macOS Keychain "Always Allow" entries are keyed to the
          caller binary path, which changes on every pi-wrapper rebuild, so
          a fresh allow-prompt fires once after each rebuild.
        '';
      };

      allowedReadPaths = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "~/.gitconfig"
          "/Users/me/private-config/files"
        ];
        description = ''
          Paths re-allowed for reading in strict mode, which denies all of
          $HOME. $PWD, ~/.pi and `sourceDir` are always readable; this list
          adds more. Leading `~` expands to $HOME. Runtime --allow-read
          extends it.

          srt matches the path as written, not its target, so a symlink
          under $HOME needs its target listed here too. That covers
          out-of-store symlinks placed in ~/.pi by another module:
          models.json or AGENTS.md pointing into a working tree resolve to
          a path outside the allowlist, and pi reports the file as missing
          rather than as denied:

          ```
          Error: Model "provider/some-model" not found.
          ```

          A home-manager symlink into /nix/store hits the same rule, since
          the link itself sits under $HOME.
        '';
      };

      allowedWritePaths = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [ "~/.kube/configs" ];
        description = ''
          Paths added to allowWrite in strict mode, which otherwise grants
          only $PWD and ~/.pi. Leading `~` expands to $HOME. Runtime
          --allow-write extends it.

          A path listed here is not automatically readable; add it to
          `allowedReadPaths` too if the tool reads back what it wrote.

          Prefer redirecting a tool at a directory already inside the grant
          (the wrapper does this for GOCACHE, CARGO_HOME and friends) over
          opening its default location, which is usually somewhere broad
          like ~/Library/Caches.
        '';
      };

      gitWrite = lib.mkOption {
        type = lib.types.enum [
          "branch-gated"
          "always"
          "off"
        ];
        default = "branch-gated";
        description = ''
          Whether the agent may write the repo's git directories, which is
          what lets it `git commit`. Reading them is unconditional and not a
          knob: in a worktree layout `$PWD/.git` is a pointer file into a
          `.bare` directory, so without the read grant every git command in
          the workspace fails with `not a git repository`.

          - `branch-gated` grants write when HEAD is a branch outside
            `protectedBranches`. A detached HEAD counts as protected.
          - `always` grants it on every branch.
          - `off` never grants it, and denies the git dir even where it sits
            inside the writable workspace.

          Per-invocation `--allow-git-write` / `--no-git-write` override.

          The grant is the whole git common directory, so an agent that can
          commit can also move refs other than its own; `protectedBranches`
          fences off the ones that matter. There is no narrower srt grant:
          a commit touches the index in the per-worktree dir, new objects and
          the branch ref in the common dir.
        '';
      };

      protectedBranches = lib.mkOption {
        type = with lib.types; listOf str;
        default = [
          "main"
          "master"
        ];
        example = [
          "main"
          "release"
        ];
        description = ''
          Branches `gitWrite = "branch-gated"` refuses to grant write for.
          Their refs and reflogs (`refs/heads/<branch>`,
          `logs/refs/heads/<branch>`) also stay in srt's denyWrite once write
          is granted for some other branch, so an agent committing on its own
          branch cannot move these. A `git pack-refs` or `git gc` rewrite of
          the packed-refs file still can; treat this as a guardrail, not a
          boundary.
        '';
      };

      allowLocalBinding = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Permit TCP/UDP bind() and listen() on 127.0.0.1 / ::1 inside the
          strict sandbox by setting srt's network.allowLocalBinding=true.
          Required for httptest.NewServer, local dev servers (vite, air,
          rails s, etc.), and integration tests that stand up an in-process
          server.

          Does not open external network egress, srt's domain filter still
          applies, only loopback addresses are unblocked. Runtime
          --allow-loopback extends this per-invocation.
        '';
      };

      allowedDomains = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "openrouter.ai"
          "api.anthropic.com"
          "github.com"
        ];
        description = ''
          Base network allowlist. Empty by default; each host configures
          exactly the provider endpoints pi needs. Runtime --allow extends
          this. srt passes these through its filtering proxy; programs not
          respecting HTTP_PROXY/HTTPS_PROXY can bypass the filter.
        '';
      };

      networkBundles = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options = {
              domains = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Network hosts added to the allowlist when this bundle is invoked.";
              };
              trustd = lib.mkOption {
                type = bool;
                default = false;
                description = ''
                  Whether this bundle requires `com.apple.trustd.agent`
                  access (srt's `enableWeakerNetworkIsolation` toggle).
                  Set true for languages whose HTTPS client uses macOS
                  Security framework for cert verification, Go is the
                  known case. Cargo, npm, pip and the JVM honor their own
                  CA stores and do NOT need this.
                '';
              };
              readPaths = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = ''
                  Paths re-allowed for reading when this bundle is invoked,
                  on top of strict mode's default-deny from `/` down. A
                  leading `~` is expanded by the wrapper. For a toolchain's
                  config and package cache: `~/.m2`, `~/.clojure`.
                '';
              };
              writePaths = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = ''
                  Paths added to `allowWrite` when this bundle is invoked.
                  A package cache usually wants both this and `readPaths`,
                  since resolving a dependency it does not already hold
                  writes into it.
                '';
              };
            };
          });
        default = { };
        description = ''
          Named bundles enabling per-invocation `--allow-<name>` CLI flags
          that extend the strict-mode network allowlist and (optionally)
          flip security loosenings the language needs.

          The go / rust / node / python bundles are supplied by this
          module's own config rather than by this default, because the
          module system applies an option's default only when nothing
          defines the option at all. As a definition they merge with a
          host's, so adding `sandbox.networkBundles.linear` keeps the
          language bundles and setting `sandbox.networkBundles.go.domains`
          overrides that list while leaving `go.trustd` alone. Naming them
          in the default would instead have discarded all four the moment
          a host added a fifth.

          Unknown `--allow-<name>` at the CLI fails fast with the
          known-bundles list on stderr.

          A bundle also carries `readPaths` / `writePaths`, so a toolchain
          whose caches live under the denied `$HOME` is one flag rather than
          a flag plus two `--allow-read`s. Env stays out: the cache redirects
          in the wrapper's hardening list are unconditional, since pointing
          a cache somewhere writable costs nothing in a session that never
          runs that toolchain.
        '';
      };

      defaultArgs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "--model"
          "anthropic/claude-sonnet-4"
        ];
        description = ''
          Args prepended to every `pi` invocation, before any user-supplied
          args. Use this to pin a default model/provider so you don't have
          to type --model on every command. User args still win on repeated
          flags; pi takes the last occurrence of --model, --provider, etc.
        '';
      };

      gitIdentity = {
        name = lib.mkOption {
          type = lib.types.str;
          default = "Kyle's Daemon";
          description = ''
            Name stamped on any git commit pi makes. Forwarded to the
            wrapper, which exports GIT_AUTHOR_NAME / GIT_COMMITTER_NAME in
            pi's process tree only, repo and global git config are never
            touched. Default is intentionally non-human so agent commits
            stand out in `git log`; override per-host if you want a
            different label. Signing is unconditionally disabled on agent
            commits (see wrapper.sh), that's not a knob.
          '';
        };
        email = lib.mkOption {
          type = lib.types.str;
          default = "ai-daemon@noreply.ondy.org";
          description = ''
            Email paired with `gitIdentity.name`. Same scoping rules,
            exported into pi's process tree, never written to config.
          '';
        };
      };

    };

    modelsJson = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          providers.local = {
            baseUrl = "http://127.0.0.1:8770/v1";
            api = "openai-completions";
            apiKey = "local-no-key";
            compat.supportsDeveloperRole = false;
            models = [
              {
                id = "qwen3-coder";
                name = "Qwen3 Coder (local, mlx)";
                reasoning = false;
                input = [ "text" ];
                cost = {
                  input = 0;
                  output = 0;
                  cacheRead = 0;
                  cacheWrite = 0;
                };
                contextWindow = 128000;
                maxTokens = 8192;
              }
            ];
          };
        }
      '';
      description = ''
        Contents of ~/.pi/agent/models.json, rendered verbatim via
        builtins.toJSON. Empty by default (pi ships built-in providers;
        this option only exists to register additional ones, custom
        OpenAI-compatible endpoints such as a local mlx-openai-server,
        Ollama, vLLM, or a proxy).

        See pi's custom-provider docs:
        https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/custom-provider.md

        This option owns the whole file, home-manager overwrites
        ~/.pi/agent/models.json on every activation, so a manually edited
        file (e.g. providers added by hand before this option existed) will
        be clobbered. Fold any such providers into this option's value
        first.

        Select a configured model per-invocation with `pi --model
        <provider>/<model-id>`, or pin one host-wide with the wrapper's
        defaultPiArgs.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    # pi has no web tool and no MCP, so search and page-reading are a CLI the
    # bash tool reaches. Both halves are Kagi endpoints, which is what lets
    # the kagi bundle below grant one domain instead of the wildcard egress
    # that reading arbitrary pages would otherwise need.
    home.packages = [
      piPackage
      pkgs.kagi
    ];

    home.sessionVariables = {
      PI_TELEMETRY = "0";
      PI_SKIP_VERSION_CHECK = "1";
    };

    # A definition, not the option's default, so a host adding its own bundle
    # merges with these four instead of replacing them. See the option's
    # description for why the distinction matters.
    hmFoundry.dev.pi-coding-agent.sandbox.networkBundles =
      let
        # Maven Central under both names poms are written against.
        mavenDomains = [
          "repo1.maven.org"
          "repo.maven.apache.org"
        ];
        # Read and write: resolving a dependency the cache does not hold
        # writes it there, so read-only fails the first cold build.
        mavenPaths = [ "~/.m2" ];
      in
      {
        go = {
          domains = [
            "proxy.golang.org"
            "sum.golang.org"
          ];
          trustd = true;
        };
        rust = {
          domains = [
            "crates.io"
            "static.crates.io"
            "index.crates.io"
          ];
        };
        node = {
          domains = [ "registry.npmjs.org" ];
        };
        python = {
          domains = [
            "pypi.org"
            "files.pythonhosted.org"
          ];
        };
        # No trustd: the JVM verifies TLS against its own cacerts rather than
        # Security framework.
        java = {
          domains = mavenDomains;
          readPaths = mavenPaths;
          writePaths = mavenPaths;
        };
        # Self-sufficient rather than layered on java, because `clj` resolves
        # through maven itself and needing two flags to run one test suite is a
        # papercut that buys no isolation. ~/.clojure holds deps.edn and the
        # user-level .cpcache; ~/.gitlibs holds :git/sha deps, which cogsworth
        # has one of. github.com and codeload are what fetches those.
        clojure = {
          domains = mavenDomains ++ [
            "repo.clojars.org"
            "github.com"
            "codeload.github.com"
          ];
          readPaths = mavenPaths ++ [
            "~/.clojure"
            "~/.gitlibs"
          ];
          writePaths = mavenPaths ++ [
            "~/.clojure"
            "~/.gitlibs"
          ];
        };
        # Not a toolchain, but the same flag mechanism. Kagi's /extract
        # returns any page as markdown from kagi.com, so fetching one costs
        # the same single domain as searching and never needs the wildcard
        # egress srt refuses to express. Reaching a page directly would, which
        # is why `pi --web` and not this bundle is what a raw curl needs.
        kagi = {
          domains = [ "kagi.com" ];
        };
        # Inputs fetch in the nix client, before anything reaches the daemon,
        # so --allow-nix alone still dies at the proxy on the first cold
        # input: gitlab.com carries NUR's rycee firefox-addons, github and
        # flakehub the rest of flake.lock. Substitution is daemon-side, which
        # --allow-nix already covers, so these five are everything eval
        # fetches. Not named "nix" because the wrapper's --allow-nix
        # exact-match case shadows a bundle by that name.
        flake = {
          domains = [
            "github.com"
            "codeload.github.com"
            "gitlab.com"
            "api.flakehub.com"
            "flakehub.com"
          ];
        };
      };

    # A real writable file, not the usual store symlink: pi writes this file
    # itself (it stamps lastChangelogVersion on first start, and /settings and
    # `pi install` persist here). The repo copy is the source of truth, so
    # runtime edits to it survive only until the next home-manager switch. A
    # dropped lastChangelogVersion is read as a fresh install, stamped silently
    # rather than replaying the changelog.
    #
    # retry.maxRetries 6 against the default 2s base: pi's agent-level backoff
    # is baseDelayMs * 2^(attempt-1) with no jitter and no ceiling, so the
    # budget is 126s and the longest single sleep is 64s. The default 3 gives up
    # after 14s, which mcloud outranks on a routine overload; past 6 the
    # doubling buys minutes of silent sleep that reads as a hang, with nothing
    # on screen to say the session is only waiting.
    home.activation.piSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run install -D -m 0644 ${./settings.json} "$HOME/.pi/agent/settings.json"
    '';

    # pi reads bare .md files at the root of ~/.pi/agent/skills/ as individual
    # skills, so claude-code's flat sources need no restructuring. Store
    # sources, matching claude-code, so /reload cannot see skill edits until
    # the next home-manager switch.
    home.file = {
      ".pi/agent/extensions".source = config.lib.file.mkOutOfStoreSymlink "${cfg.sourceDir}/extensions";
      # getAgentDir() is ~/.pi/agent (pi's core/config.ts), so task.ts reads
      # its roster from this directory.
      ".pi/agent/agents".source = config.lib.file.mkOutOfStoreSymlink "${cfg.sourceDir}/agents";
      ".pi/agent/themes".source = config.lib.file.mkOutOfStoreSymlink "${cfg.sourceDir}/themes";
      # Per-grant prompt guidance, read by extensions/grants.ts off
      # PI_GRANTS the wrapper exports. Out-of-store like the extensions so
      # grant prose is hot-reloadable rather than baked into a store path.
      ".pi/agent/grants".source = config.lib.file.mkOutOfStoreSymlink "${cfg.sourceDir}/grants";

      # Out-of-store because pi does write this file: startup's
      # migrateKeybindingsConfigFile() rewrites it whenever an action id it
      # holds has been renamed upstream. Namespaced ids do not trigger that,
      # but if a future pi renames one, the rewrite lands in the worktree
      # instead of failing against a read-only store path.
      ".pi/agent/keybindings.json".source =
        config.lib.file.mkOutOfStoreSymlink "${cfg.sourceDir}/keybindings.json";

      # Phase discipline and the Assert rule, out-of-store like the extensions
      # so an edit lands without a rebuild. mkDefault yields to a host or a
      # private module shipping its own AGENTS.md, which would otherwise
      # collide on this path rather than override it.
      ".pi/agent/AGENTS.md".source = lib.mkDefault (
        config.lib.file.mkOutOfStoreSymlink "${cfg.sourceDir}/AGENTS.md"
      );

      ".pi/agent/models.json" = lib.mkIf (cfg.modelsJson != { }) {
        text = builtins.toJSON cfg.modelsJson;
      };
    }
    // repoSkills
    // flakeSkills
    // lib.optionalAttrs claudeCfg.enable hostSkills;
  };
}
