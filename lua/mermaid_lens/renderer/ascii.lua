--- @module mermaid_lens.renderer.ascii
--- Architectural Layer: Application Service (Stub)
--- Parent: `mermaid_lens.init`, `mermaid_lens.renderer.compiler`, `mermaid_lens.ui.modal`
--- Children: None (Leaf module).
--- Single Responsibility: Provide a clean placeholder contract for the upcoming
--- terminal ASCII/Unicode rendering engine.

local M = {}

--- Notifies the user that the ASCII rendering mode is currently under development.
function M.notify_coming_soon()
	vim.notify("MermaidLens: ASCII rendering mode is coming soon.", vim.log.levels.INFO)
end

return M
