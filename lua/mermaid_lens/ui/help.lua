--- @module mermaid_lens.ui.help
--- Architectural Layer: Interface Adapter / View
--- Parent: `mermaid_lens.ui.modal`
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.ui.input`
--- Single Responsibility: Manage the keyboard-driven options popup (`?`) with
--- dynamic user keymap labels and strict input sandboxing.

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

local function format_row(key_str, desc)
	return string.format("  %-20s %s", key_str, desc)
end

--- Toggles the options popup centered over `parent_win`.
--- Dynamically reflects any custom keybindings configured by the user.
--- @param parent_win integer
--- @param diagram_name string
--- @param modal_keys table
--- @param callbacks { on_open: fun(), on_close: fun() }
function M.toggle(parent_win, diagram_name, modal_keys, callbacks)
	if M.is_open() then
		M.close(callbacks.on_close)
		return
	end

	if callbacks.on_open then
		callbacks.on_open()
	end

	local mk = modal_keys or constants.DEFAULT_CONFIG.keymaps.modal
	local k_tab = input.format_keys(mk.toggle_code, "<Tab>")
	local k_zoom_in = input.format_keys(mk.zoom_in, "+ / =")
	local k_zoom_out = input.format_keys(mk.zoom_out, "-")
	local k_fit = input.format_keys(mk.toggle_fit, "f")
	local k_reset = input.format_keys(mk.reset, "0")
	local k_tp = input.format_keys(mk.toggle_touchpad, "m")
	local k_theme = input.format_keys(mk.toggle_theme, "t")
	local k_rerender = input.format_keys(mk.rerender, "r")
	local k_help = input.format_keys(mk.help, "?")
	local k_quit = input.format_keys(mk.quit, "q / <Esc>")

	local lines = {
		"",
		"  Preview Mode Controls                            ",
		"  ───────────────────────────────────────────────  ",
		format_row(k_tab, "Toggle Preview / Code Mode"),
		format_row("hjkl / Arrows", "Pan across diagram"),
		format_row("Click + Drag", "Freehand canvas pan"),
		format_row(k_zoom_in .. " / " .. k_zoom_out, "Zoom in / out (+ Mouse Wheel)"),
		format_row(k_fit .. " / 2-Click", "Toggle Full View / Smart Width"),
		format_row(k_reset .. " / R-Click", "Reset to full centered view"),
		format_row(k_tp, "Toggle 2-finger Touchpad mode"),
		format_row(k_theme, "Toggle Light / Dark theme"),
		format_row(k_rerender, "Force manual re-render"),
		"",
		"  Code / Edit Mode Controls                        ",
		"  ───────────────────────────────────────────────  ",
		format_row(k_tab, "Return to Preview Mode"),
		format_row(":w", "Save changes & re-render"),
		format_row(k_help .. " / " .. k_quit, "Close menu or quit modal"),
		"",
	}

	local w = 54
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
			{ " " .. k_help .. ": Back ", "MermaidLensKeyHint" },
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

	input.bind("n", mk.help or "?", close_fn, hopts)
	input.bind("n", mk.quit or { "q", "<Esc>" }, close_fn, hopts)
	vim.keymap.set("n", "<Esc>", close_fn, hopts)
	vim.keymap.set("n", "<CR>", close_fn, hopts)
end

return M
