-- LSP configuration
local nvim_lsp = require("lspconfig")

-- Diagnostic keymaps (global)
local opts = { noremap = true, silent = true }
vim.keymap.set("n", "<leader>ce", vim.diagnostic.open_float, opts)
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, opts)
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, opts)
vim.keymap.set("n", "<leader>cl", vim.diagnostic.setloclist, opts)

-- Document global diagnostic keybindings
require("which-key").add({
  { "<leader>c", group = "code/LSP" },
  { "<leader>ce", desc = "Show diagnostic float" },
  { "<leader>cl", desc = "Send diagnostics to location list" },
  { "[d", desc = "Previous diagnostic" },
  { "]d", desc = "Next diagnostic" },
})

local on_attach = function(client, bufnr)
  -- Enable completion triggered by <c-x><c-o>
  vim.bo[bufnr].omnifunc = "v:lua.vim.lsp.omnifunc"

  -- Buffer-local keymaps
  local bufopts = { noremap = true, silent = true, buffer = bufnr }
  vim.keymap.set("n", "gD", vim.lsp.buf.declaration, bufopts)
  vim.keymap.set("n", "gd", vim.lsp.buf.definition, bufopts)
  vim.keymap.set("n", "K", vim.lsp.buf.hover, bufopts)
  vim.keymap.set("n", "gi", vim.lsp.buf.implementation, bufopts)
  vim.keymap.set("n", "<C-k>", vim.lsp.buf.signature_help, bufopts)
  vim.keymap.set("n", "<leader>cd", vim.lsp.buf.type_definition, bufopts)
  vim.keymap.set("n", "<leader>cr", vim.lsp.buf.rename, bufopts)
  vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, bufopts)
  vim.keymap.set("n", "gr", vim.lsp.buf.references, bufopts)
  vim.keymap.set("n", "<leader>cf", function()
    vim.lsp.buf.format({ async = true })
  end, bufopts)

  -- Document buffer-local LSP keybindings in which-key
  require("which-key").add({
    { "gD", desc = "Go to declaration", buffer = bufnr },
    { "gd", desc = "Go to definition", buffer = bufnr },
    { "K", desc = "Hover documentation", buffer = bufnr },
    { "gi", desc = "Go to implementation", buffer = bufnr },
    { "<C-k>", desc = "Signature help", buffer = bufnr },
    { "<leader>cd", desc = "Go to type definition", buffer = bufnr },
    { "<leader>cr", desc = "Rename symbol", buffer = bufnr },
    { "<leader>ca", desc = "Code action", buffer = bufnr },
    { "gr", desc = "Show references", buffer = bufnr },
    { "<leader>cf", desc = "Format buffer", buffer = bufnr },
  })
end

-- Configure YAML Language Server with schema support
nvim_lsp.yamlls.setup({
  on_attach = on_attach,
  settings = {
    yaml = {
      -- Enable schema validation
      validate = true,
      -- Enable hover documentation
      hover = true,
      -- Enable completion
      completion = true,
      -- Schema store configuration
      schemaStore = {
        -- Use built-in schema store (provides 600+ schemas)
        enable = true,
        -- Additional schema store URL
        url = "https://www.schemastore.org/api/json/catalog.json",
      },
      -- Custom schemas for specific file patterns
      schemas = {
        -- Kubernetes schemas (all versions)
        kubernetes = {
          "/*.yaml",
          "/*.yml",
        },
        -- GitHub Workflows
        ["https://json.schemastore.org/github-workflow.json"] = ".github/workflows/*.{yml,yaml}",
        -- GitHub Actions
        ["https://json.schemastore.org/github-action.json"] = ".github/action.{yml,yaml}",
        -- Docker Compose
        ["https://raw.githubusercontent.com/compose-spec/compose-spec/master/schema/compose-spec.json"] = {
          "docker-compose*.{yml,yaml}",
          "compose.{yml,yaml}",
        },
        -- Ansible
        ["https://raw.githubusercontent.com/ansible/ansible-lint/main/src/ansiblelint/schemas/ansible.json#/$defs/playbook"] = {
          "playbooks/*.{yml,yaml}",
          "**/playbooks/*.{yml,yaml}",
          "playbook.{yml,yaml}",
        },
        -- GitLab CI
        ["https://json.schemastore.org/gitlab-ci.json"] = ".gitlab-ci.{yml,yaml}",
        -- pre-commit
        ["https://json.schemastore.org/pre-commit-config.json"] = ".pre-commit-config.{yml,yaml}",
        -- Helm Chart.yaml
        ["https://json.schemastore.org/helmfile.json"] = "helmfile.{yml,yaml}",
        ["https://json.schemastore.org/chart.json"] = "Chart.{yml,yaml}",
      },
      -- Format settings
      format = {
        enable = true,
        singleQuote = false,
        bracketSpacing = true,
      },
      -- Customize YAML tags/types
      customTags = {
        -- CloudFormation tags
        "!Ref",
        "!Sub",
        "!GetAtt",
        "!Join",
        "!Select",
        "!FindInMap",
        "!Base64",
        "!Cidr",
        "!ImportValue",
        -- SOPS encrypted values
        "!sops",
      },
    },
  },
})

-- Configure gopls (Go Language Server)
nvim_lsp.gopls.setup({
  on_attach = on_attach,
  settings = {
    gopls = {
      analyses = {
        unusedparams = true,
        shadow = true,
      },
      staticcheck = true,
      gofumpt = true,
    },
  },
})

-- Configure bashls (Bash Language Server)
nvim_lsp.bashls.setup({
  on_attach = on_attach,
  settings = {
    bashIde = {
      -- Enable shellcheck integration
      shellcheckPath = "shellcheck",
      -- Glob pattern for .env files
      globPattern = "*@(.sh|.inc|.bash|.command)",
    },
  },
})

-- Configure terraform-ls (Terraform Language Server)
nvim_lsp.terraformls.setup({
  on_attach = on_attach,
  settings = {
    terraform = {
      -- Enable validation on save
      validate = {
        enable = true,
      },
    },
  },
})

-- Configure pyright (Python Language Server)
nvim_lsp.pyright.setup({
  on_attach = on_attach,
  settings = {
    python = {
      analysis = {
        -- Use workspace python environment
        autoSearchPaths = true,
        diagnosticMode = "workspace",
        useLibraryCodeForTypes = true,
        -- Type checking mode (off, basic, strict)
        typeCheckingMode = "basic",
      },
    },
  },
})

-- Configure nixd (Nix Language Server with full nixpkgs integration)
nvim_lsp.nixd.setup({
  on_attach = on_attach,
  settings = {
    nixd = {
      formatting = {
        command = { "nixfmt" },
      },
      nixpkgs = {
        -- This enables nixpkgs lib.* and pkgs.* documentation
        expr = "import <nixpkgs> { }",
      },
      options = {
        -- Enable NixOS options documentation
        nixos = {
          expr = '(builtins.getFlake "/home/kyle/src/dotfiles/odds-and-ends").nixosConfigurations.dino.options',
        },
      },
    },
  },
})

-- Configure lua_ls (Lua Language Server)
nvim_lsp.lua_ls.setup({
  on_attach = on_attach,
  settings = {
    Lua = {
      runtime = {
        -- Tell the language server which version of Lua you're using
        version = "LuaJIT",
      },
      diagnostics = {
        -- Get the language server to recognize the `vim` global
        globals = { "vim" },
      },
      workspace = {
        -- Make the server aware of Neovim runtime files
        library = vim.api.nvim_get_runtime_file("", true),
        checkThirdParty = false,
      },
      -- Do not send telemetry data
      telemetry = {
        enable = false,
      },
      -- Format on save
      format = {
        enable = true,
        defaultConfig = {
          indent_style = "space",
          indent_size = "2",
        },
      },
    },
  },
})

-- Configure clangd (C/C++ Language Server)
nvim_lsp.clangd.setup({
  on_attach = on_attach,
  cmd = { "clangd", "--background-index", "--clang-tidy" },
})

-- Configure MLIR Language Server
nvim_lsp.mlir_lsp_server.setup({
  on_attach = on_attach,
})

-- Configure Ruff (Python linting/formatting)
nvim_lsp.ruff.setup({
  on_attach = function(client, bufnr)
    -- Disable hover to avoid conflicts with pyright
    client.server_capabilities.hoverProvider = false
    on_attach(client, bufnr)
  end,
})

-- Configure Mojo Language Server (requires mojo-lsp-server from Modular)
nvim_lsp.mojo.setup({
  on_attach = on_attach,
})

-- Set up other simple LSP servers
local servers = {
  "clojure_lsp",
}

for _, lsp in ipairs(servers) do
  nvim_lsp[lsp].setup({ on_attach = on_attach })
end
