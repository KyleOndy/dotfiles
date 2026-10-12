{
  description = "Stub work configuration (no-op). Override with --override-input work-config path:/path/to/work/repo/nix on work machines.";
  inputs = { };
  outputs =
    { ... }:
    {
      darwinModule = { ... }: { };
      # work-mac's `--profile work` names the linear bundle, and the wrapper
      # refuses unknown bundles at evaluation, so the stub has to carry the
      # name for a build without the real work-config (and for `make check`,
      # which evaluates work-mac against this stub). Every list stays empty:
      # naming the bundle grants nothing.
      homeManagerModule =
        { ... }:
        {
          hmFoundry.dev.alamode.sandbox.bundles.linear = { };
        };
    };
}
