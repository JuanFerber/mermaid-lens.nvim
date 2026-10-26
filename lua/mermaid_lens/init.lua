--- @module mermaid_lens
--- Architectural Layer: Facade / Application Controller
--- Parent: Neovim user configuration (`require("mermaid_lens").setup(...)`)
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.parser.scanner`,
---           `mermaid_lens.renderer.compiler`, `mermaid_lens.renderer.ascii`,
---           `mermaid_lens.ui.modal`, `mermaid_lens.ui.input`, `mermaid_lens.ui.picker`
--- Single Responsibility: Expose the public plugin API, merge user configuration,
--- register user commands/keymaps, configure WhichKey groups, and hot-reload on Lazy updates.

local constants = require("mermaid_lens.config.constants")
local scanner = require("mermaid_lens.parser.scanner")
local compiler = require("mermaid_lens.renderer.compiler")
local ascii = require("mermaid_lens.renderer.ascii")
local modal = require("mermaid_lens.ui.modal")
local input = require("mermaid_lens.ui.input")

local M = {}

M.config = vim.deepcopy(constants.DEFAULT_CONFIG)

--- Extracts the shared leader/group prefix (e.g., `<leader>m`) from a keymap lhs.
--- @param lhs string|string[]|boolean|nil
--- @return string|nil
local function extract_group_prefix(lhs)
	local key = type(lhs) == "table" and lhs[1] or lhs
	if type(key) ~= "string" or #key < 2 then
		return nil
	end
	return key:sub(1, #key - 1)
end

--- Registers the `MermaidLens` keymap group in `which-key.nvim` (supports v3 and v2).
--- If `which-key` is lazy-loaded on `VeryLazy`, defers registration until it is ready.
--- @param km table
local function register_which_key_group(km)
	local prefix = extract_group_prefix(km.preview)
		or extract_group_prefix(km.search)
		or extract_group_prefix(km.search_buffer)
		or extract_group_prefix(km.ascii)

	if not prefix then
		return
	end

	local function apply_wk()
		local ok, wk = pcall(require, "which-key")
		if not ok or type(wk) ~= "table" then
			return false
		end
		if type(wk.add) == "function" then
			pcall(wk.add, {
				{ prefix, group = "MermaidLens" },
			})
			return true
		elseif type(wk.register) == "function" then
			pcall(wk.register, {
				[prefix] = { name = "+MermaidLens" },
			})
			return true
		end
		return false
	end

	if not apply_wk() then
		local wk_group = vim.api.nvim_create_augroup("MermaidLensWhichKey", { clear = true })
		vim.api.nvim_create_autocmd("User", {
			group = wk_group,
			pattern = "VeryLazy",
			once = true,
			callback = function()
				apply_wk()
			end,
		})
	end
end

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

--- Purges all cached `mermaid_lens` Lua modules from memory and re-initializes the plugin
--- with the active user configuration so updates pulled via LazyVim apply immediately.
function M.reload()
	local saved_config = vim.deepcopy(M.config)

	for mod_name in pairs(package.loaded) do
		if mod_name:match("^mermaid_lens") or mod_name:match("^telescope%._extensions%.mermaid_lens") then
			package.loaded[mod_name] = nil
		end
	end

	local ok, fresh = pcall(require, "mermaid_lens")
	if ok and fresh and type(fresh.setup) == "function" then
		fresh.setup(saved_config)
	end
end

--- Initializes `mermaid_lens` with user options, commands, keymaps, WhichKey group,
--- Telescope extension, and automatic hot-reload hooks for `lazy.nvim`.
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

	vim.api.nvim_create_user_command("MermaidLensReload", function()
		M.reload()
		vim.notify("MermaidLens: Plugin modules reloaded.", vim.log.levels.INFO)
	end, { desc = "Reload all MermaidLens Lua modules in place" })

	if M.config.keymaps and M.config.keymaps ~= false then
		local km = M.config.keymaps
		register_which_key_group(km)
		input.bind("n", km.preview, M.preview, { desc = "Preview" })
		input.bind("n", km.ascii, M.preview_ascii, { desc = "Preview ASCII (Coming soon)" })
		input.bind("n", km.search, M.search, { desc = "Workspace Search" })
		input.bind("n", km.search_buffer, M.search_buffer, { desc = "Buffer Search" })
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

	-- Automatically hot-reload plugin modules in place after `:Lazy update` / `:Lazy sync`
	local reload_group = vim.api.nvim_create_augroup("MermaidLensAutoReload", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = reload_group,
		pattern = { "LazyUpdate", "LazySync", "LazyReload" },
		callback = function()
			vim.schedule(function()
				M.reload()
			end)
		end,
	})
end

return M
