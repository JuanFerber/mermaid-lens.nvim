--- @module mermaid_lens
--- Architectural Layer: Facade / Application Controller
--- Parent: Neovim user configuration (`require("mermaid_lens").setup(...)`)
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.parser.scanner`,
---           `mermaid_lens.renderer.compiler`, `mermaid_lens.renderer.ascii`,
---           `mermaid_lens.ui.modal`, `mermaid_lens.ui.input`, `mermaid_lens.ui.picker`
--- Single Responsibility: Expose the public plugin API, merge user configuration,
--- register user commands/keymaps, and preload the Telescope extension.

local constants = require("mermaid_lens.config.constants")
local scanner = require("mermaid_lens.parser.scanner")
local compiler = require("mermaid_lens.renderer.compiler")
local ascii = require("mermaid_lens.renderer.ascii")
local modal = require("mermaid_lens.ui.modal")
local input = require("mermaid_lens.ui.input")

local M = {}

M.config = vim.deepcopy(constants.DEFAULT_CONFIG)

--- Compiles and previews the Mermaid diagram under the cursor (or the current `.mmd` buffer).
--- @param opts { theme?: "light"|"dark", force_ascii?: boolean }|nil
function M.preview(opts)
	opts = opts or {}

	local diagram = scanner.get_diagram_under_cursor(0)
	if not diagram then
		vim.notify("MermaidLens: No Mermaid diagram found under cursor or in current buffer.", vim.log.levels.WARN)
		return
	end

	local current_theme = opts.theme or M.config.theme or "light"

	compiler.compile(diagram, {
		theme = current_theme,
		scale = M.config.scale,
		force_ascii = opts.force_ascii,
		fallback_to_code = M.config.fallback_to_code,
	}, function(artifact)
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

--- Opens the Telescope diagram picker (defaults to `config.picker_scope`).
--- @param opts { scope?: "project"|"buffer" }|nil
function M.search(opts)
	local ok, picker = pcall(require, "mermaid_lens.ui.picker")
	if ok and picker.find then
		picker.find(opts)
	else
		vim.notify("MermaidLens: Failed to load Telescope picker (" .. tostring(picker) .. ").", vim.log.levels.ERROR)
	end
end

--- Opens the Telescope diagram picker scoped exclusively to the current buffer.
--- @param opts table|nil
function M.search_buffer(opts)
	M.search(vim.tbl_extend("force", opts or {}, { scope = "buffer" }))
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

	vim.api.nvim_create_user_command("MermaidLensTelescope", function(cmd_opts)
		local arg = vim.trim(cmd_opts.args or "")
		local scope = (arg == "buffer" or arg == "project") and arg or nil
		M.search({ scope = scope })
	end, {
		nargs = "?",
		complete = function()
			return { "project", "buffer" }
		end,
		desc = "Search Mermaid diagrams in Telescope (project or buffer)",
	})

	vim.api.nvim_create_user_command("MermaidLensBuffer", function()
		M.search_buffer()
	end, { desc = "Search Mermaid diagrams within the current file in Telescope" })

	if M.config.keymaps and M.config.keymaps ~= false then
		local km = M.config.keymaps
		input.bind("n", km.preview, M.preview, { desc = "MermaidLens: Preview" })
		input.bind("n", km.ascii, M.preview_ascii, { desc = "MermaidLens: Preview ASCII (Coming soon)" })
		input.bind("n", km.search, M.search, { desc = "MermaidLens: Telescope Workspace Search" })
		input.bind("n", km.search_buffer, M.search_buffer, { desc = "MermaidLens: Telescope Buffer Search" })
	end

	package.preload["telescope._extensions.mermaid_lens"] = function()
		local telescope = require("telescope")
		local picker = require("mermaid_lens.ui.picker")
		return telescope.register_extension({
			exports = {
				mermaid_lens = picker.find,
				diagrams = picker.find,
				buffer = picker.find_buffer,
			},
		})
	end
	pcall(function()
		require("telescope").load_extension("mermaid_lens")
	end)
end

return M
