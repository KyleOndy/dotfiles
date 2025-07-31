(
  self: super:
  let
    nvim-treesitter-sexp = super.vimUtils.buildVimPlugin {
      name = "nvim-treesitter-sexp";
      src = super.fetchFromGitHub {
        owner = "PaterJason";
        repo = "nvim-treesitter-sexp";
        rev = "32509f4071f9c8ba5655bf2e1ccf1f1cd8447da0";
        hash = "sha256-ehpGvHnY28Ym55B7ituwcvZmGmLt1x92J5M+m8j1ytU=";
      };
      meta.homepage = "https://github.com/PaterJason/nvim-treesitter-sexp/";
    };
  in
  {
    vimPlugins = super.vimPlugins // {
      inherit nvim-treesitter-sexp;
    };
  }
)
