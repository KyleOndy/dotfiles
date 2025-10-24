# nixCats package definitions - defines available nvim configurations
# Each package specifies settings and which categories to enable
{
  nvim =
    { pkgs, ... }:
    {
      settings = {
        wrapRc = true;
        configDirName = "nixCats-nvim";
      };
      categories = {
        general = true;
      };
    };
}
