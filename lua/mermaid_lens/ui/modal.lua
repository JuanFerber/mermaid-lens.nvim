--- @module mermaid_lens.ui.modal
--- Architectural Layer: Interface Adapter / View Controller
--- Parent: `mermaid_lens.init` and `mermaid_lens.ui.picker`
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.env.terminal`,
---           `mermaid_lens.graphics.kitty`, `mermaid_lens.graphics.viewport`,
---           `mermaid_lens.renderer.compiler`, `mermaid_lens.renderer.ascii`,
---           `mermaid_lens.ui.input`, `mermaid_lens.ui.help`
--- Single Responsibility: Orchestrate the interactive preview modal lifecycle,
--- backdrop dimming, camera state transitions, theme switching, and focus events.

local constants = require("mermaid_lens.config.constants")
local terminal = require("mermaid_lens.env.terminal")
local kitty = require("mermaid_lens.graphics.kitty")
local viewport = require("mermaid_lens.graphics.viewport")
local compiler = require("mermaid_lens.renderer.compiler")
local ascii = require("mermaid_lens.renderer.ascii")
local input = require("mermaid_lens.ui.input")
local help = require("mermaid_lens.ui.help")

local M = {}

local process_img_id = (vim.fn.getpid() % 800000) + 1000

local state = {
	buf = nil,
	win = nil,
	backdrop_buf = nil,
	backdrop_win = nil,
	augroup = nil,
	img_id = process_img_id,
	name = "Mermaid",
	filename = "Mermaid",
	diagram = nil,
	theme = "light",
	png_path = nil,
	img_w = 1,
	img_h = 1,
	zoom = 1.0,
	default_zoom = 1.0,
	pan_x = 0,
	pan_y = 0,
	metrics = nil,
	backdrop_enabled = true,
	backdrop_blend = 45,
}

local function setup_highlights()
	vim.api.nvim_set_hl(0, "MermaidLensBackdrop", { bg = "#05060a", default = false })
	vim.api.nvim_set_hl(0, "MermaidLensBorder", { fg = "#565f89", bg = "#16161e", default = false })
	vim.api.nvim_set_hl(0, "MermaidLensTitle", { fg = "#c0caf5", bg = "#16161e", bold = true, default = false })
	vim.api.nvim_set_hl(0, "MermaidLensKeyHint", { fg = "#7aa2f7", bg = "#16161e", bold = true, default = false })
	vim.api.nvim_set_hl(0, "MermaidLensCloseHint", { fg = "#f7768e", bg = "#16161e", bold = true, default = false })
end

local function build_header_title(filename)
	return {
		{ " " .. filename .. " ", "MermaidLensTitle" },
		{ " ?: Options ", "MermaidLensKeyHint" },
		{ " q: Quit ", "MermaidLensCloseHint" },
	}
end

local function current_projection(win_width, win_height, zoom)
	return viewport.project({
		win_width = win_width,
		win_height = win_height,
		img_w = state.img_w,
		img_h = state.img_h,
		zoom = zoom,
		pan_x = state.pan_x,
		pan_y = state.pan_y,
		metrics = state.metrics,
	})
end

local function reset_pan_centered(win_width, win_height, zoom)
	local vp = current_projection(win_width, win_height, zoom)
	state.pan_x = (state.img_w - vp.cam_w) / 2
	if vp.cam_h >= state.img_h * 0.85 then
		state.pan_y = (state.img_h - vp.cam_h) / 2
	else
		state.pan_y = 0
	end
end

local function render_viewport()
	if help.is_open() then
		return
	end
	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		return
	end

	local win_width = vim.api.nvim_win_get_width(state.win)
	local win_height = vim.api.nvim_win_get_height(state.win)
	local win_pos = vim.api.nvim_win_get_position(state.win)

	local vp = current_projection(win_width, win_height, state.zoom)
	state.pan_x = vp.pan_x
	state.pan_y = vp.pan_y

	local screen_row = state.metrics.tmux_top + win_pos[1] + 2 + vp.offset_row
	local screen_col = state.metrics.tmux_left + win_pos[2] + 2 + vp.offset_col

	kitty.place_viewport({
		img_id = state.img_id,
		x = vp.src_x,
		y = vp.src_y,
		w = vp.src_w,
		h = vp.src_h,
		cols = vp.dst_cols,
		rows = vp.dst_rows,
		screen_row = screen_row,
		screen_col = screen_col,
	})
end

local function zoom_by(delta)
	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		return
	end
	local win_width = vim.api.nvim_win_get_width(state.win)
	local win_height = vim.api.nvim_win_get_height(state.win)

	local old_vp = current_projection(win_width, win_height, state.zoom)
	local center_x = old_vp.pan_x + (old_vp.cam_w / 2)
	local center_y = old_vp.pan_y + (old_vp.cam_h / 2)

	local factor = delta > 0 and constants.LIMITS.ZOOM_STEP_IN or constants.LIMITS.ZOOM_STEP_OUT
	state.zoom = math.max(constants.LIMITS.MIN_ZOOM, math.min(state.zoom * factor, constants.LIMITS.MAX_ZOOM))

	local new_vp = current_projection(win_width, win_height, state.zoom)
	state.pan_x = center_x - (new_vp.cam_w / 2)
	state.pan_y = center_y - (new_vp.cam_h / 2)

	render_viewport()
end

local function open_backdrop(metrics)
	if not state.backdrop_enabled then
		return
	end
	state.backdrop_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.backdrop_buf].buftype = "nofile"
	vim.bo[state.backdrop_buf].bufhidden = "wipe"

	state.backdrop_win = vim.api.nvim_open_win(state.backdrop_buf, false, {
		relative = "editor",
		width = metrics.ui_cols,
		height = metrics.ui_rows,
		row = 0,
		col = 0,
		style = "minimal",
		focusable = false,
		zindex = constants.UI.BACKDROP_ZINDEX,
	})
	vim.wo[state.backdrop_win].winhl = "Normal:MermaidLensBackdrop"
	vim.wo[state.backdrop_win].winblend = state.backdrop_blend
end

local function close_backdrop()
	if state.backdrop_win and vim.api.nvim_win_is_valid(state.backdrop_win) then
		pcall(vim.api.nvim_win_close, state.backdrop_win, true)
	end
	state.backdrop_win = nil
	state.backdrop_buf = nil
end

--- Opens the interactive preview modal for a compiled diagram artifact.
--- @param artifact RenderedDiagramArtifact
--- @param opts { theme?: "light"|"dark", backdrop?: boolean, backdrop_blend?: integer, diagram?: MermaidDiagramEntry }
function M.open(artifact, opts)
	opts = opts or {}
	if opts.backdrop ~= nil then
		state.backdrop_enabled = opts.backdrop
	end
	if opts.backdrop_blend ~= nil then
		state.backdrop_blend = opts.backdrop_blend
	end
	if opts.theme then
		state.theme = opts.theme
	end
	if opts.diagram then
		state.diagram = opts.diagram
	end

	help.close()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	close_backdrop()

	setup_highlights()

	state.name = artifact.name or "Mermaid"
	local short_file = vim.fn.fnamemodify(artifact.filepath or "", ":t")
	state.filename = (short_file ~= "" and not short_file:match("^%[")) and short_file or state.name

	state.metrics = terminal.get_console_metrics()
	local box = viewport.compute_modal_box(state.metrics, build_header_title(state.filename))

	open_backdrop(state.metrics)

	state.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.buf].buftype = "nofile"
	vim.bo[state.buf].bufhidden = "wipe"
	vim.bo[state.buf].swapfile = false

	state.win = vim.api.nvim_open_win(state.buf, true, {
		relative = "editor",
		width = box.width,
		height = box.height,
		row = box.row,
		col = box.col,
		style = "minimal",
		border = "rounded",
		title = box.title,
		title_pos = "center",
		zindex = constants.UI.MODAL_ZINDEX,
	})
	vim.wo[state.win].winhl = "FloatBorder:MermaidLensBorder"

	local function close_modal()
		if state.augroup then
			pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
			state.augroup = nil
		end
		help.close()
		kitty.clear_all_placements()
		kitty.delete_image(state.img_id)
		if state.win and vim.api.nvim_win_is_valid(state.win) then
			vim.api.nvim_win_close(state.win, true)
		end
		close_backdrop()
		vim.cmd("redraw!")
	end

	local function toggle_options_help()
		help.toggle(state.win, state.name, {
			on_open = function()
				kitty.clear_all_placements()
			end,
			on_close = function()
				if state.win and vim.api.nvim_win_is_valid(state.win) then
					vim.api.nvim_set_current_win(state.win)
					vim.cmd("redraw")
					render_viewport()
				end
			end,
		})
	end

	-- 1. Lock all default Vim keys and modes in the modal buffer
	input.lock_buffer_keys(state.buf)

	-- 2. Bind modal control keys
	local kopts = { buffer = state.buf, silent = true, nowait = true }
	vim.keymap.set("n", "q", close_modal, kopts)
	vim.keymap.set("n", "<Esc>", close_modal, kopts)
	vim.keymap.set("n", "?", toggle_options_help, kopts)

	state.png_path = artifact.png_path
	state.img_w = math.max(1, artifact.img_w or state.metrics.screen_px_w)
	state.img_h = math.max(1, artifact.img_h or state.metrics.screen_px_h)

	state.default_zoom =
		viewport.compute_smart_initial_zoom(box.width, box.height, state.img_w, state.img_h, state.metrics)
	state.zoom = state.default_zoom
	reset_pan_centered(box.width, box.height, state.zoom)

	-- Fill buffer with whitespace so Neovim reports cell coordinates across the entire interior on mouse drag
	local blank_line = string.rep(" ", box.width)
	local blank_lines = {}
	for i = 1, box.height do
		blank_lines[i] = blank_line
	end
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, blank_lines)
	vim.bo[state.buf].modifiable = false

	vim.cmd("redraw")
	kitty.clear_all_placements()
	kitty.delete_image(state.img_id)
	kitty.transmit_file(state.img_id, state.png_path)
	render_viewport()

	state.augroup = vim.api.nvim_create_augroup("MermaidLensModal_" .. state.img_id, { clear = true })
	vim.api.nvim_create_autocmd({ "FocusLost", "WinLeave", "BufLeave", "VimSuspend" }, {
		group = state.augroup,
		callback = function()
			kitty.clear_all_placements()
		end,
	})

	vim.api.nvim_create_autocmd({ "VimResized" }, {
		group = state.augroup,
		callback = function()
			if state.win and vim.api.nvim_win_is_valid(state.win) then
				state.metrics = terminal.get_console_metrics()
				if state.backdrop_win and vim.api.nvim_win_is_valid(state.backdrop_win) then
					vim.api.nvim_win_set_config(state.backdrop_win, {
						relative = "editor",
						width = state.metrics.ui_cols,
						height = state.metrics.ui_rows,
						row = 0,
						col = 0,
					})
				end
				local new_box = viewport.compute_modal_box(state.metrics, build_header_title(state.filename))
				vim.api.nvim_win_set_config(state.win, {
					relative = "editor",
					width = new_box.width,
					height = new_box.height,
					row = new_box.row,
					col = new_box.col,
					title = new_box.title,
					title_pos = "center",
				})
				vim.cmd("redraw")
				kitty.clear_all_placements()
				render_viewport()
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "FocusGained", "WinEnter" }, {
		group = state.augroup,
		callback = function()
			if state.win and vim.api.nvim_win_is_valid(state.win) and state.png_path then
				state.metrics = terminal.get_console_metrics()
				vim.schedule(function()
					kitty.clear_all_placements()
					kitty.transmit_file(state.img_id, state.png_path)
					render_viewport()
				end)
			end
		end,
	})

	local function pan(dx, dy)
		local win_w = vim.api.nvim_win_get_width(state.win)
		local win_h = vim.api.nvim_win_get_height(state.win)
		local vp = current_projection(win_w, win_h, state.zoom)
		local step_x = math.max(constants.LIMITS.MIN_PAN_STEP_PX, vp.cam_w * constants.LIMITS.PAN_STEP_RATIO)
		local step_y = math.max(constants.LIMITS.MIN_PAN_STEP_PX, vp.cam_h * constants.LIMITS.PAN_STEP_RATIO)
		state.pan_x = vp.pan_x + (dx * step_x)
		state.pan_y = vp.pan_y + (dy * step_y)
		render_viewport()
	end

	local function drag_cells(d_cols, d_rows)
		local win_w = vim.api.nvim_win_get_width(state.win)
		local win_h = vim.api.nvim_win_get_height(state.win)
		local vp = current_projection(win_w, win_h, state.zoom)
		local dx_px = (d_cols * state.metrics.cell_w) / vp.scale
		local dy_px = (d_rows * state.metrics.cell_h) / vp.scale
		state.pan_x = vp.pan_x + dx_px
		state.pan_y = vp.pan_y + dy_px
		render_viewport()
	end

	local function reset_view()
		local win_w = vim.api.nvim_win_get_width(state.win)
		local win_h = vim.api.nvim_win_get_height(state.win)
		state.default_zoom = viewport.compute_smart_initial_zoom(win_w, win_h, state.img_w, state.img_h, state.metrics)
		state.zoom = state.default_zoom
		reset_pan_centered(win_w, win_h, state.zoom)
		render_viewport()
	end

	local function toggle_fit()
		local win_w = vim.api.nvim_win_get_width(state.win)
		local win_h = vim.api.nvim_win_get_height(state.win)
		if math.abs(state.zoom - 1.0) < 0.05 and state.default_zoom > 1.05 then
			state.zoom = state.default_zoom
		else
			state.zoom = 1.0
		end
		reset_pan_centered(win_w, win_h, state.zoom)
		render_viewport()
	end

	local function toggle_theme()
		local next_theme = (state.theme == "light") and "dark" or "light"
		local diag = state.diagram
			or {
				name = state.name,
				code = artifact.code,
				filepath = artifact.filepath,
				lnum = artifact.lnum,
			}
		if not diag.code then
			return
		end

		local current_modal_box = nil
		if state.win and vim.api.nvim_win_is_valid(state.win) then
			local win_pos = vim.api.nvim_win_get_position(state.win)
			current_modal_box = {
				row = win_pos[1],
				col = win_pos[2],
				width = vim.api.nvim_win_get_width(state.win),
				height = vim.api.nvim_win_get_height(state.win),
			}
		end

		compiler.compile(diag, { theme = next_theme, modal_box = current_modal_box }, function(new_artifact)
			if state.win and vim.api.nvim_win_is_valid(state.win) then
				state.theme = next_theme
				state.png_path = new_artifact.png_path
				state.img_w = math.max(1, new_artifact.img_w or state.img_w)
				state.img_h = math.max(1, new_artifact.img_h or state.img_h)
				kitty.clear_all_placements()
				kitty.delete_image(state.img_id)
				kitty.transmit_file(state.img_id, state.png_path)
				render_viewport()
			end
		end)
	end

	vim.keymap.set("n", "+", function()
		zoom_by(1)
	end, kopts)
	vim.keymap.set("n", "=", function()
		zoom_by(1)
	end, kopts)
	vim.keymap.set("n", "-", function()
		zoom_by(-1)
	end, kopts)
	vim.keymap.set("n", "0", reset_view, kopts)
	vim.keymap.set("n", "f", toggle_fit, kopts)
	vim.keymap.set("n", "t", toggle_theme, kopts)
	vim.keymap.set("n", "a", ascii.notify_coming_soon, kopts)

	vim.keymap.set("n", "h", function()
		pan(-1, 0)
	end, kopts)
	vim.keymap.set("n", "l", function()
		pan(1, 0)
	end, kopts)
	vim.keymap.set("n", "k", function()
		pan(0, -1)
	end, kopts)
	vim.keymap.set("n", "j", function()
		pan(0, 1)
	end, kopts)

	vim.keymap.set("n", "<Left>", function()
		pan(-1, 0)
	end, kopts)
	vim.keymap.set("n", "<Right>", function()
		pan(1, 0)
	end, kopts)
	vim.keymap.set("n", "<Up>", function()
		pan(0, -1)
	end, kopts)
	vim.keymap.set("n", "<Down>", function()
		pan(0, 1)
	end, kopts)

	input.attach_gestures(state.buf, {
		zoom = zoom_by,
		pan = pan,
		drag_cells = drag_cells,
		reset = reset_view,
		toggle_fit = toggle_fit,
	})
end

return M
