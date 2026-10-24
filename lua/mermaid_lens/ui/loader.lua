--- @module mermaid_lens.ui.loader
--- Architectural Layer: Interface Adapter / View
--- Parent: `mermaid_lens.renderer.compiler`
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.env.terminal`, `mermaid_lens.graphics.kitty`
--- Single Responsibility: Display an animated percentage progress modal centered
--- either in the Neovim session or inside the active preview modal during compilation.

local constants = require("mermaid_lens.config.constants")
local terminal = require("mermaid_lens.env.terminal")
local kitty = require("mermaid_lens.graphics.kitty")

local M = {}

local state = {
	buf = nil,
	win = nil,
	timer = nil,
	percent = 0,
	frame_idx = 1,
	label = "",
}

local function setup_highlights()
	vim.api.nvim_set_hl(0, "MermaidLensLoaderBorder", { fg = "#7aa2f7", bg = "#16161e", default = false })
	vim.api.nvim_set_hl(0, "MermaidLensLoaderTitle", { fg = "#c0caf5", bg = "#16161e", bold = true, default = false })
	vim.api.nvim_set_hl(0, "MermaidLensLoaderBar", { fg = "#7aa2f7", bg = "#16161e", bold = true, default = false })
end

local function center_text(str, width)
	local len = vim.fn.strdisplaywidth(str)
	local pad = math.max(0, math.floor((width - len) / 2))
	return string.rep(" ", pad) .. str
end

local function compute_position(w, h, modal_box)
	if modal_box and modal_box.row and modal_box.col and modal_box.width and modal_box.height then
		local row = modal_box.row + math.floor(((modal_box.height + 2) - (h + 2)) / 2)
		local col = modal_box.col + math.floor(((modal_box.width + 2) - (w + 2)) / 2)
		return math.max(0, row), math.max(0, col)
	end

	local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }
	local tabline_h = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1
		or 0
	local bottom_h = (vim.o.laststatus > 0 and 1 or 0) + vim.o.cmdheight
	local usable_rows = math.max(6, ui.height - tabline_h - bottom_h)
	local usable_cols = math.max(20, ui.width)

	local row = tabline_h + math.max(0, math.floor((usable_rows - (h + 2)) / 2))
	local col = math.max(0, math.floor((usable_cols - (w + 2)) / 2))
	return row, col
end

local function render_frame()
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	local w = constants.UI.LOADER_WIDTH
	local bar_width = constants.UI.LOADER_BAR_WIDTH
	local filled = math.floor((state.percent / 100) * bar_width)
	local empty = bar_width - filled
	local bar = string.rep("█", filled) .. string.rep("░", empty)
	local spin = constants.UI.SPINNER_FRAMES[state.frame_idx]

	local raw_line1 = string.format("%s Rendering %s...", spin, state.label)
	if vim.fn.strdisplaywidth(raw_line1) > w - 2 then
		raw_line1 = vim.fn.strcharpart(raw_line1, 0, w - 5) .. "..."
	end
	local raw_line2 = string.format("[%s] %3d%%", bar, state.percent)

	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
		"",
		center_text(raw_line1, w),
		"",
		center_text(raw_line2, w),
		"",
	})
	vim.bo[state.buf].modifiable = false
end

--- Opens and animates the percentage progress modal.
--- @param diagram_name string
--- @param theme "light"|"dark"
--- @param modal_box table|nil Optional parent modal geometry for relative centering
function M.start(diagram_name, theme, modal_box)
	setup_highlights()

	if terminal.supports_kitty_graphics() then
		kitty.clear_all_placements()
	end

	if state.timer then
		state.timer:stop()
		state.timer:close()
		state.timer = nil
	end
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end

	state.percent = 4
	state.frame_idx = 1
	state.label = string.format("'%s' (%s)", diagram_name or "Mermaid", theme or "light")

	local w = constants.UI.LOADER_WIDTH
	local h = constants.UI.LOADER_HEIGHT
	local row, col = compute_position(w, h, modal_box)

	state.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.buf].buftype = "nofile"
	vim.bo[state.buf].bufhidden = "wipe"

	state.win = vim.api.nvim_open_win(state.buf, false, {
		relative = "editor",
		width = w,
		height = h,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = { { " Mermaid Lens ", "MermaidLensLoaderTitle" } },
		title_pos = "center",
		focusable = false,
		zindex = constants.UI.LOADER_ZINDEX,
	})
	vim.wo[state.win].winhl = "Normal:MermaidLensLoaderBar,FloatBorder:MermaidLensLoaderBorder"

	render_frame()
	vim.cmd("redraw")

	state.timer = vim.uv.new_timer()
	state.timer:start(
		0,
		constants.UI.LOADER_TICK_MS,
		vim.schedule_wrap(function()
			if not state.win or not vim.api.nvim_win_is_valid(state.win) then
				return
			end
			state.frame_idx = (state.frame_idx % #constants.UI.SPINNER_FRAMES) + 1
			if state.percent < 65 then
				state.percent = state.percent + 5
			elseif state.percent < 88 then
				state.percent = state.percent + 2
			elseif state.percent < 96 then
				state.percent = state.percent + 1
			end
			render_frame()
		end)
	)
end

--- Completes the progress bar at 100%, closes the loader window, and invokes `on_closed`.
--- @param on_closed fun()|nil
function M.stop(on_closed)
	if state.timer then
		state.timer:stop()
		state.timer:close()
		state.timer = nil
	end

	state.percent = 100
	render_frame()
	vim.cmd("redraw")

	vim.defer_fn(function()
		if state.win and vim.api.nvim_win_is_valid(state.win) then
			pcall(vim.api.nvim_win_close, state.win, true)
		end
		state.win = nil
		state.buf = nil
		vim.cmd("redraw")
		if on_closed then
			on_closed()
		end
	end, 60)
end

return M
