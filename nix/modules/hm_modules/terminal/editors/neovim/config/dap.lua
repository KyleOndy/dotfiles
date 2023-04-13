require("which-key").register({
  ["<leader>d"] = {
    name = "+debug",
    b = {
      name = "+breakpoint",
      b = { '<cmd>lua require"dap".toggle_breakpoint()<CR>', "Toggle Breakpoint" },
      m = {
        '<cmd>lua require"dap".set_breakpoint(nil, nil, vim.fn.input("Log point message: "))<CR>',
        "Breakpoint (msg)",
      },
      c = {
        '<cmd>lua require"dap".set_breakpoint(vim.fn.input("Breakpoint condition: "))<CR>',
        "Breakpoint (condition)",
      },
    },
    v = {
      name = "+select",
      b = { '<cmd>lua require"telescope".extensions.dap.list_breakpoints{}<CR>', "Select Breakpoint" },
      c = { '<cmd>lua require"telescope".extensions.dap.commands{}<CR>', "Select Command" },
      f = { '<cmd>lua require"telescope".extensions.dap.frames{}<CR>', "Select Frame" },
      g = { '<cmd>lua require"telescope".extensions.dap.configurations{}<CR>', "Select configuration" },
      v = { '<cmd>lua require"telescope".extensions.dap.variables{}<CR>', "Select Variable" },
    },
    s = {
      name = "+step",
      i = { '<cmd>lua require"dap".step_into()<CR>', "Step Into" },
      o = { '<cmd>lua require"dap".step_out()<CR>', "Step Out" },
      v = { '<cmd>lua require"dap".step_over()<CR>', "Step Over" },
    },
    r = {
      name = "+run",
      e = { '<cmd>lua require"dap".repl.open()<CR>', "Open REPL" },
      l = { '<cmd>lua require"dap".repl.run_last()<CR>', "Run Last" },
      r = { '<cmd>lua require"dap".continue()<CR>', "Continue / Run" },
    },
    u = {
      name = "+ui",
      h = { '<cmd>lua require"dap.ui.widgets".hover()<CR>', "Widget hover?" },
      j = { '<cmd>lua require"dap.ui.variables".hover()<CR>', "Hover?" },
      s = { '<cmd>lua require"dap.ui.variables".scopes()<CR>', "Scope?" },
      u = {
        "<cmd>lua local widgets=require'dap.ui.widgets';widgets.centered_float(widgets.scopes)<CR>",
        "Floating widget?",
      },
      v = { '<cmd>lua require"dap.ui.variables".visual_hover()<CR>', "Hover Visual?" },
    },
  },
})
