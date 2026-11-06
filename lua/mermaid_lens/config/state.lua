--- @module mermaid_lens.config.state
--- Architectural Layer: Domain Configuration State
--- Parent: `mermaid_lens.init`, `mermaid_lens.ui.modal`, and `mermaid_lens.ui.picker`
--- Children: `mermaid_lens.config.constants`
--- Single Responsibility: Hold and provide read/write access to the active merged
--- runtime configuration without introducing circular dependencies on `init.lua`.

local constants = require("mermaid_lens.config.constants")

local M = {}

--- @type MermaidLensDefaults
local active_config = vim.deepcopy(constants.DEFAULT_CONFIG)

--- Merges user options into the default configuration schema and stores the result.
--- @param opts table|nil
--- @return MermaidLensDefaults
function M.set(opts)
	active_config = vim.tbl_deep_extend("force", vim.deepcopy(constants.DEFAULT_CONFIG), opts or {})
	return active_config
end

--- Returns the currently active plugin configuration table.
--- @return MermaidLensDefaults
function M.get()
	return active_config
end

return M
