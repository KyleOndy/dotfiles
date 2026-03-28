{
  description = "Stub work configuration (no-op). Override with --override-input work-config path:/path/to/work/repo on work machines.";
  inputs = { };
  outputs =
    { ... }:
    {
      darwinModule = { ... }: { };
      homeManagerModule = { ... }: { };
    };
}
