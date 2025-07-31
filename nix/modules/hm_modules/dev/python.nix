{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.python;
  python-packages =
    python-packages:
    with python-packages;
    [
      virtualenv
    ]
    ++ optionals (!stdenv.isDarwin) [
      # TOOD: packages below _should_ work on darwin, I just need to fix them and
      #       contribute upstream.
      debugpy # dap implementation
    ];
  system-python-with-packages = pkgs.python3.withPackages python-packages;
in
{
  options.hmFoundry.dev.python = {
    enable = mkEnableOption "python";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      pyright
      poetry
      ruff
      system-python-with-packages
    ];
    programs.neovim = {
      plugins = [
        {
          plugin = pkgs.hello; # just a nop so we can inject configuration
          type = "lua";
          config = ''
            local dap = require('dap')
            dap.adapters.python = {
              type = 'executable';
              command = "${system-python-with-packages}/bin/python";
              args = { '-m', 'debugpy.adapter' };
            }

            dap.configurations.python = {
              {
                -- The first three options are required by nvim-dap
                type = 'python'; -- the type here established the link to the adapter definition: `dap.adapters.python`
                request = 'launch';
                name = "Launch file";

                -- Options below are for debugpy, see https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings for supported options

                program = "''${file}"; -- This configuration will launch the current file if used.
                pythonPath = function()
                  -- debugpy supports launching an application with a different interpreter then the one used to launch debugpy itself.
                  -- The code below looks for a `venv` or `.venv` folder in the current directly and uses the python within.
                  -- You could adapt this - to for example use the `VIRTUAL_ENV` environment variable.
                  local cwd = vim.fn.getcwd()
                  if vim.fn.executable(cwd .. '/venv/bin/python') == 1 then
                    return cwd .. '/venv/bin/python'
                  elseif vim.fn.executable(cwd .. '/.venv/bin/python') == 1 then
                    return cwd .. '/.venv/bin/python'
                  else
                    return '/usr/bin/python'
                  end
                end;
              },
            }
          '';
        }
      ];
    };
  };
}
