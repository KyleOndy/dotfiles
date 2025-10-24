-- Conjure configuration for Clojure REPL integration

-- Use K for documentation
vim.g["conjure#mapping#doc_word"] = "K"

-- HUD configuration
-- Width of HUD as percentage of the editor width (0.0 to 1.0)
vim.g["conjure#log#hud#width"] = 1

-- Disable HUD display (prefer botright log)
vim.g["conjure#log#hud#enabled"] = false

-- HUD corner position
vim.g["conjure#log#hud#anchor"] = "SE"

-- Open log at bottom using full width
vim.g["conjure#log#botright"] = true

-- Lines from top of file to check for ns form for evaluation context
-- Use b:conjure#context to override for specific buffers
vim.g["conjure#extract#context_header_lines"] = 100
