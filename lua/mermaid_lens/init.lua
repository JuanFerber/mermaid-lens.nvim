--- @module mermaid_lens
--- Architectural Layer: Facade / Application Controller
--- Parent: Neovim user configuration (`require("mermaid_lens").setup(...)`)
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.parser.scanner`,
---           `mermaid_lens.renderer.compiler`, `mermaid_lens.renderer.ascii`,
---           `mermaid_lens.ui.modal`, `mermaid_lens.ui.picker`
--- Single Responsibility: Expose the public plugin API, merge user configuration,
--- register user commands/keymaps, and preload the Telescope extension.

local constants = require("mermaid_lens.config.constants")
local scanner = require("mermaid_lens.parser.scanner")
local compiler = require("mermaid_lens.renderer.compiler")
local ascii = require("mermaid_lens.renderer.ascii")
local modal = require("mermaid_lens.ui.modal")

local M = {}

M.config = vim.deepcopy(constants.DEFAULT_CONFIG)

--- Compiles and previews the Mermaid diagram under the cursor (or the current `.mmd` buffer).
--- @param opts { theme?: "light"|"dark", force_ascii?: boolean }|nil
function M.preview(opts)
	opts = opts or {}
	if opts.force_ascii then
		ascii.notify_coming_soon()
		return
	end

	local diagram = scanner.get_diagram_under_cursor(0)
	if not diagram then
		vim.notify("MermaidLens: No Mermaid diagram found under cursor or in current buffer.", vim.log.levels.WARN)
		return
	end

	local current_theme = opts.theme or M.config.theme or "light"

	compiler.compile(diagram, { theme = current_theme }, function(artifact)
		modal.open(artifact, {
			theme = current_theme,
			backdrop = M.config.backdrop,
			backdrop_blend = M.config.backdrop_blend,
			diagram = diagram,
		})
	end)
end

--- Displays the "Coming soon" notice for ASCII rendering mode.
function M.preview_ascii()
	ascii.notify_coming_soon()
end

--- Opens the project-wide Telescope diagram picker.
--- @param opts table|nil
function M.search(opts)
	local ok, picker = pcall(require, "mermaid_lens.ui.picker")
	if ok and picker.find then
		picker.find(opts)
	else
		vim.notify("MermaidLens: Failed to load Telescope picker (" .. tostring(picker) .. ").", vim.log.levels.ERROR)
	end
end

--- Initializes `mermaid_lens` with user options, commands, keymaps, and Telescope integration.
--- @param opts table|nil
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(constants.DEFAULT_CONFIG), opts or {})

	vim.api.nvim_create_user_command("MermaidLensPreview", function()
		M.preview({ force_ascii = false })
	end, { desc = "Render Mermaid diagram in interactive Kitty modal" })

	vim.api.nvim_create_user_command("MermaidLensASCII", function()
		M.preview_ascii()
	end, { desc = "Render Mermaid diagram in ASCII mode (Coming soon)" })

	vim.api.nvim_create_user_command("MermaidLensTelescope", function()
		M.search()
	end, { desc = "Search workspace Mermaid diagrams in Telescope" })

	if M.config.keymaps then
		if M.config.keymaps.preview then
			vim.keymap.set("n", M.config.keymaps.preview, M.preview, { desc = "MermaidLens: Preview" })
		end
		if M.config.keymaps.ascii then
			vim.keymap.set(
				"n",
				M.config.keymaps.ascii,
				M.preview_ascii,
				{ desc = "MermaidLens: Preview ASCII (Coming soon)" }
			)
		end
		if M.config.keymaps.search then
			vim.keymap.set("n", M.config.keymaps.search, M.search, { desc = "MermaidLens: Telescope Search" })
		end
	end

	package.preload["telescope._extensions.mermaid_lens"] = function()
		local telescope = require("telescope")
		local picker = require("mermaid_lens.ui.picker")
		return telescope.register_extension({
			exports = {
				mermaid_lens = picker.find,
				diagrams = picker.find,
			},
		})
	end
	pcall(function()
		require("telescope").load_extension("mermaid_lens")
	end)
end

return M
