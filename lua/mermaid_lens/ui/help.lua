--- @module mermaid_lens.ui.help
--- Architectural Layer: Interface Adapter / View
--- Parent: `mermaid_lens.ui.modal`
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.ui.input`
--- Single Responsibility: Manage the keyboard-driven options popup (`?`) with
--- strict input sandboxing so only closing keys are accepted while open.

local constants = require("mermaid_lens.config.constants")
local input = require("mermaid_lens.ui.input")

local M = {}

local state = {
	buf = nil,
	win = nil,
}

--- Checks whether the help overlay window is currently open.
--- @return boolean
function M.is_open()
	return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- Closes the help overlay if open and invokes `on_close`.
--- @param on_close fun()|nil
function M.close(on_close)
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	state.win = nil
	state.buf = nil
	if on_close then
		on_close()
	end
end

--- Toggles the options popup centered over `parent_win`.
--- While open, locks all keys except `?`, `q`, `<Esc>`, and `<CR>`.
--- @param parent_win integer
--- @param diagram_name string
--- @param callbacks { on_open: fun(), on_close: fun() }
function M.toggle(parent_win, diagram_name, callbacks)
	if M.is_open() then
		M.close(callbacks.on_close)
		return
	end

	if callbacks.on_open then
		callbacks.on_open()
	end

	local lines = {
		"",
		"  Keyboard & Mouse Controls                        ",
		"  ───────────────────────────────────────────────  ",
		"  hjkl / Arrows        Pan across diagram          ",
		"  Click + Drag         Freehand canvas pan         ",
		"  + / - / Wheel        Zoom in / out               ",
		"  Ctrl + Wheel         Focal zoom                  ",
		"  f / Double Click     Toggle Smart Fit / Full view",
		"  0 / Right Click      Reset camera position       ",
		"  m                    Toggle 2-finger Touchpad    ",
		"  t                    Toggle Light / Dark theme   ",
		"  a                    ASCII mode (Coming soon)    ",
		"  ? / q / Esc          Close this menu             ",
		"",
	}

	local w = 52
	local h = #lines

	local win_pos = vim.api.nvim_win_get_position(parent_win)
	local win_w = vim.api.nvim_win_get_width(parent_win)
	local win_h = vim.api.nvim_win_get_height(parent_win)
	local row = win_pos[1] + math.floor(((win_h + 2) - (h + 2)) / 2)
	local col = win_pos[2] + math.floor(((win_w + 2) - (w + 2)) / 2)

	state.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.buf].buftype = "nofile"
	vim.bo[state.buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false

	state.win = vim.api.nvim_open_win(state.buf, true, {
		relative = "editor",
		width = w,
		height = h,
		row = math.max(1, row),
		col = math.max(1, col),
		style = "minimal",
		border = "rounded",
		title = {
			{ " Options (" .. (diagram_name or "Mermaid") .. ") ", "MermaidLensTitle" },
			{ " ?: Back ", "MermaidLensKeyHint" },
		},
		title_pos = "center",
		zindex = constants.UI.HELP_ZINDEX,
	})
	vim.wo[state.win].winhl = "FloatBorder:MermaidLensBorder"

	input.lock_buffer_keys(state.buf)

	local hopts = { buffer = state.buf, silent = true, nowait = true }
	local close_fn = function()
		M.close(callbacks.on_close)
	end

	vim.keymap.set("n", "?", close_fn, hopts)
	vim.keymap.set("n", "q", close_fn, hopts)
	vim.keymap.set("n", "<Esc>", close_fn, hopts)
	vim.keymap.set("n", "<CR>", close_fn, hopts)
end

return M
