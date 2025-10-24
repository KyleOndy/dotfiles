-- Debug Adapter Protocol (DAP) configuration

-- nvim-dap-ui setup
require("dapui").setup()

-- Auto-open/close dapui when debugging starts/stops
local dap, dapui = require("dap"), require("dapui")
dap.listeners.after.event_initialized["dapui_config"] = function()
  dapui.open()
end
dap.listeners.before.event_terminated["dapui_config"] = function()
  dapui.close()
end
dap.listeners.before.event_exited["dapui_config"] = function()
  dapui.close()
end

-- Load telescope-dap extension
require("telescope").load_extension("dap")

-- nvim-dap-virtual-text for inline variable display
require("nvim-dap-virtual-text").setup()

-- DAP keybindings via which-key (simplified for SRE work)
require("which-key").add({
  { "<leader>d", group = "debug" },
  { "<leader>db", '<cmd>lua require"dap".toggle_breakpoint()<CR>', desc = "Toggle breakpoint" },
  { "<leader>dc", '<cmd>lua require"dap".continue()<CR>', desc = "Continue/Run" },
  { "<leader>di", '<cmd>lua require"dap".step_into()<CR>', desc = "Step into" },
  { "<leader>do", '<cmd>lua require"dap".step_out()<CR>', desc = "Step out" },
  { "<leader>dv", '<cmd>lua require"dap".step_over()<CR>', desc = "Step over" },
  { "<leader>dr", '<cmd>lua require"dap".repl.open()<CR>', desc = "Open REPL" },
  { "<leader>du", '<cmd>lua require"dapui".toggle()<CR>', desc = "Toggle debug UI" },
})
