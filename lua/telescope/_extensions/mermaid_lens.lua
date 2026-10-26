--- @module telescope._extensions.mermaid_lens
--- Architectural Layer: Interface Adapter Bridge
--- Parent: `telescope.nvim` extension loader
--- Children: `mermaid_lens.ui.picker`
--- Single Responsibility: Register `mermaid_lens` exports (`diagrams` and `buffer`)
--- with Telescope's native extension system.

local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
	return
end

local picker = require("mermaid_lens.ui.picker")

return telescope.register_extension({
	exports = {
		mermaid_lens = picker.find,
		diagrams = picker.find,
		buffer = picker.find_buffer,
	},
})
