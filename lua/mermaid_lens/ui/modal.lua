--- @module mermaid_lens.ui.modal
--- Architectural Layer: Interface Adapter / View Controller
--- Parent: `mermaid_lens.init` and `mermaid_lens.ui.picker`
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.env.terminal`,
---           `mermaid_lens.graphics.kitty`, `mermaid_lens.graphics.viewport`,
---           `mermaid_lens.renderer.compiler`, `mermaid_lens.renderer.diagnostics`,
---           `mermaid_lens.renderer.ascii`, `mermaid_lens.editor.sync`,
---           `mermaid_lens.ui.input`, `mermaid_lens.ui.code_view`, `mermaid_lens.ui.help`
--- Single Responsibility: Orchestrate the dual-mode (`Preview` <-> `Code/Edit`)
--- modal lifecycle, full-overview default camera, and user-configured keybindings.

local constants = require("mermaid_lens.config.constants")
local terminal = require("mermaid_lens.env.terminal")
local kitty = require("mermaid_lens.graphics.kitty")
local viewport = require("mermaid_lens.graphics.viewport")
local compiler = require("mermaid_lens.renderer.compiler")
local diagnostics = require("mermaid_lens.renderer.diagnostics")
local ascii = require("mermaid_lens.renderer.ascii")
local sync = require("mermaid_lens.editor.sync")
local input = require("mermaid_lens.ui.input")
local code_view = require("mermaid_lens.ui.code_view")
local help = require("mermaid_lens.ui.help")

local M = {}

local process_img_id = (vim.fn.getpid() % 800000) + 1000

local state = {
	canvas_buf = nil,
	code_buf = nil,
	win = nil,
	backdrop_buf = nil,
	backdrop_win = nil,
	augroup = nil,
	img_id = process_img_id,
	view_mode = "preview", -- "preview" | "code"
	name = "Mermaid",
	filename = "Mermaid",
	diagram = nil,
	last_rendered_code = nil,
	has_valid_render = false,
	theme = "light",
	png_path = nil,
	img_w = 1,
	img_h = 1,
	zoom = 1.0,
	smart_zoom = 1.0,
	pan_x = 0,
	pan_y = 0,
	metrics = nil,
	backdrop_enabled = true,
	backdrop_blend = 45,
	auto_render_on_save = true,
	save_parent_on_write = true,
	scale = 3,
	touchpad_mode = "zoom",
	modal_cfg = {},
	modal_keys = {},
}

local function setup_highlights()
	vim.api.nvim_set_hl(0, "MermaidLensBackdrop", { bg = "#05060a", default = false })
	vim.api.nvim_set_hl(0, "MermaidLensBorder", { fg = "#565f89", bg = "#16161e", default = false })
	vim.api.nvim_set_hl(0, "MermaidLensTitle", { fg = "#c0caf5", bg = "#16161e", bold = true, default = false })
	vim.api.nvim_set_hl(0, "MermaidLensModeBadge", { fg = "#9ece6a", bg = "#16161e", bold = true, default = false })
	vim.api.nvim_set_hl(0, "MermaidLensKeyHint", { fg = "#7aa2f7", bg = "#16161e", bold = true, default = false })
	vim.api.nvim_set_hl(0, "MermaidLensCloseHint", { fg = "#f7768e", bg = "#16161e", bold = true, default = false })
end

local function build_header_title(filename, mode)
	local k_help = input.format_keys(state.modal_keys.help, "?")
	local k_quit = input.format_keys(
		type(state.modal_keys.quit) == "table" and state.modal_keys.quit[1] or state.modal_keys.quit,
		"q"
	)
	if mode == "code" then
		return {
			{ " " .. filename .. " ", "MermaidLensTitle" },
			{ "[Code] ", "MermaidLensModeBadge" },
			{ " " .. k_help .. ": Options ", "MermaidLensKeyHint" },
			{ " " .. k_quit .. ": Quit ", "MermaidLensCloseHint" },
		}
	end
	return {
		{ " " .. filename .. " ", "MermaidLensTitle" },
		{ " " .. k_help .. ": Options ", "MermaidLensKeyHint" },
		{ " " .. k_quit .. ": Quit ", "MermaidLensCloseHint" },
	}
end

local function current_modal_box()
	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		return nil
	end
	local win_pos = vim.api.nvim_win_get_position(state.win)
	return {
		row = win_pos[1],
		col = win_pos[2],
		width = vim.api.nvim_win_get_width(state.win),
		height = vim.api.nvim_win_get_height(state.win),
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

-- Centers the diagram horizontally; centers vertically when viewing the full diagram
local function reset_pan_centered(win_width, win_height, zoom)
	local vp = current_projection(win_width, win_height, zoom)
	state.pan_x = (state.img_w - vp.cam_w) / 2
	if zoom <= 1.05 or vp.cam_h >= state.img_h * 0.85 then
		state.pan_y = (state.img_h - vp.cam_h) / 2
	else
		state.pan_y = 0
	end
end

local function render_viewport()
	if state.view_mode ~= "preview" or help.is_open() then
		return
	end
	if not state.win or not vim.api.nvim_win_is_valid(state.win) or not state.png_path then
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

local function switch_to_code_mode(err_info, severity)
	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		return
	end
	state.view_mode = "code"
	kitty.clear_all_placements()
	code_view.activate(state.win, state.code_buf, build_header_title(state.filename, "code"), err_info, severity)
	vim.cmd("redraw")
end

local function restore_existing_preview()
	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		return
	end
	diagnostics.clear(state.code_buf)
	state.view_mode = "preview"
	code_view.deactivate(state.win, state.canvas_buf, build_header_title(state.filename, "preview"))
	vim.cmd("redraw")
	kitty.clear_all_placements()
	kitty.transmit_file(state.img_id, state.png_path)
	render_viewport()
end

local function apply_compiled_artifact(artifact, reset_camera)
	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		return
	end

	if artifact.mode == "code" or not artifact.png_path then
		state.has_valid_render = false
		switch_to_code_mode(artifact.error, artifact.error_severity)
		return
	end

	diagnostics.clear(state.code_buf)
	state.view_mode = "preview"
	state.has_valid_render = true
	state.last_rendered_code = state.diagram and state.diagram.code or artifact.code
	state.png_path = artifact.png_path
	state.img_w = math.max(1, artifact.img_w or state.metrics.screen_px_w)
	state.img_h = math.max(1, artifact.img_h or state.metrics.screen_px_h)

	code_view.deactivate(state.win, state.canvas_buf, build_header_title(state.filename, "preview"))

	local win_w = vim.api.nvim_win_get_width(state.win)
	local win_h = vim.api.nvim_win_get_height(state.win)

	state.smart_zoom = viewport.compute_smart_initial_zoom(win_w, win_h, state.img_w, state.img_h, state.metrics)

	-- Default to full diagram view (`zoom = 1.0`) centered inside the modal
	if reset_camera then
		state.zoom = 1.0
		reset_pan_centered(win_w, win_h, state.zoom)
	end

	vim.cmd("redraw")
	kitty.clear_all_placements()
	kitty.delete_image(state.img_id)
	kitty.transmit_file(state.img_id, state.png_path)
	render_viewport()
end

local function compile_and_show(force_recompile, reset_camera)
	if not state.diagram then
		return
	end
	compiler.compile(state.diagram, {
		theme = state.theme,
		scale = state.scale,
		force_recompile = force_recompile,
		modal_box = current_modal_box(),
	}, function(new_artifact)
		apply_compiled_artifact(new_artifact, reset_camera)
	end)
end

local function zoom_by(delta)
	if state.view_mode ~= "preview" or not state.win or not vim.api.nvim_win_is_valid(state.win) then
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

--- Opens the interactive dual-mode modal for a compiled or fallback diagram artifact.
--- @param artifact RenderedDiagramArtifact
--- @param opts table|nil
function M.open(artifact, opts)
	opts = opts or {}
	local ml = require("mermaid_lens")
	local cfg = ml.config or constants.DEFAULT_CONFIG

	state.backdrop_enabled = opts.backdrop ~= nil and opts.backdrop or cfg.backdrop
	state.backdrop_blend = opts.backdrop_blend or cfg.backdrop_blend
	state.theme = opts.theme or artifact.theme or cfg.theme or "light"
	state.auto_render_on_save = cfg.auto_render_on_save ~= false
	state.save_parent_on_write = cfg.save_parent_on_write ~= false
	state.scale = cfg.scale or 3
	state.touchpad_mode = cfg.touchpad_mode or "zoom"
	state.modal_cfg = cfg.modal or {}
	state.modal_keys = (type(cfg.keymaps) == "table" and cfg.keymaps.modal) or constants.DEFAULT_CONFIG.keymaps.modal

	state.diagram = opts.diagram
		or {
			kind = "block",
			name = artifact.name or "Mermaid",
			filename = vim.fn.fnamemodify(artifact.filepath or "", ":t"),
			code = artifact.code or "",
			filepath = artifact.filepath or "",
			lnum = artifact.lnum or 1,
			end_lnum = (artifact.lnum or 1) + #vim.split(artifact.code or "", "\n", { plain = true }) + 1,
		}

	help.close()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	if state.canvas_buf and vim.api.nvim_buf_is_valid(state.canvas_buf) then
		pcall(vim.api.nvim_buf_delete, state.canvas_buf, { force = true })
	end
	close_backdrop()

	setup_highlights()

	state.name = state.diagram.name or "Mermaid"
	local short_file = vim.fn.fnamemodify(state.diagram.filepath or "", ":t")
	state.filename = (short_file ~= "" and not short_file:match("^%[")) and short_file or state.name

	state.metrics = terminal.get_console_metrics()
	local initial_mode = (artifact.mode == "code" or not artifact.png_path) and "code" or "preview"
	local box =
		viewport.compute_modal_box(state.metrics, build_header_title(state.filename, initial_mode), state.modal_cfg)

	open_backdrop(state.metrics)

	state.canvas_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.canvas_buf].buftype = "nofile"
	vim.bo[state.canvas_buf].bufhidden = "hide"
	vim.bo[state.canvas_buf].swapfile = false

	local blank_line = string.rep(" ", box.width)
	local blank_lines = {}
	for i = 1, box.height do
		blank_lines[i] = blank_line
	end
	vim.bo[state.canvas_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.canvas_buf, 0, -1, false, blank_lines)
	vim.bo[state.canvas_buf].modifiable = false

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
		if state.canvas_buf and vim.api.nvim_buf_is_valid(state.canvas_buf) then
			pcall(vim.api.nvim_buf_delete, state.canvas_buf, { force = true })
		end
		state.canvas_buf = nil
		state.code_buf = nil
		close_backdrop()
		vim.cmd("redraw!")
	end

	local function toggle_options_help()
		help.toggle(state.win, state.name, state.modal_keys, {
			on_open = function()
				kitty.clear_all_placements()
			end,
			on_close = function()
				if state.win and vim.api.nvim_win_is_valid(state.win) then
					vim.api.nvim_set_current_win(state.win)
					vim.cmd("redraw")
					if state.view_mode == "preview" then
						render_viewport()
					end
				end
			end,
		})
	end

	state.code_buf = code_view.get_or_create_buffer(state.diagram, state.modal_keys, {
		on_save = function(new_lines)
			local new_code = table.concat(new_lines, "\n")
			if new_code == state.diagram.code then
				vim.notify("MermaidLens: No changes detected.", vim.log.levels.INFO)
				return
			end

			local ok, err_msg = sync.apply_changes(state.diagram, new_lines, {
				write_to_disk = state.save_parent_on_write,
			})
			if not ok then
				vim.notify("MermaidLens: " .. tostring(err_msg), vim.log.levels.ERROR)
				return
			end

			vim.notify("MermaidLens: Saved changes to " .. state.filename, vim.log.levels.INFO)
			if state.auto_render_on_save then
				compile_and_show(true, false)
			end
		end,
		on_toggle_preview = function()
			local current_lines = vim.api.nvim_buf_get_lines(state.code_buf, 0, -1, false)
			local current_code = table.concat(current_lines, "\n")

			if current_code ~= state.diagram.code then
				local ok, err_msg = sync.apply_changes(state.diagram, current_lines, {
					write_to_disk = state.save_parent_on_write,
				})
				if not ok then
					vim.notify("MermaidLens: " .. tostring(err_msg), vim.log.levels.ERROR)
					return
				end
				vim.bo[state.code_buf].modified = false
			end

			if not state.has_valid_render or state.diagram.code ~= state.last_rendered_code then
				compile_and_show(true, false)
			else
				restore_existing_preview()
			end
		end,
		on_help = toggle_options_help,
		on_quit = close_modal,
	})

	state.win = vim.api.nvim_open_win(state.canvas_buf, true, {
		relative = "editor",
		width = box.width,
		height = box.height,
		row = box.row,
		col = box.col,
		style = "minimal",
		border = state.modal_cfg.border or "rounded",
		title = box.title,
		title_pos = "center",
		zindex = constants.UI.MODAL_ZINDEX,
	})
	vim.wo[state.win].winhl = "FloatBorder:MermaidLensBorder"

	input.lock_buffer_keys(state.canvas_buf)

	local kopts = { buffer = state.canvas_buf, silent = true, nowait = true }
	local mk = state.modal_keys

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

	-- `0` / Reset: Always returns to Full Overview (`zoom = 1.0`) centered in the modal
	local function reset_view()
		local win_w = vim.api.nvim_win_get_width(state.win)
		local win_h = vim.api.nvim_win_get_height(state.win)
		state.zoom = 1.0
		reset_pan_centered(win_w, win_h, state.zoom)
		render_viewport()
	end

	-- `f` / Toggle Fit: Toggles between Full Overview (`1.0x`) and Smart Width Fit (or `2.0x`)
	local function toggle_fit()
		local win_w = vim.api.nvim_win_get_width(state.win)
		local win_h = vim.api.nvim_win_get_height(state.win)
		state.smart_zoom = viewport.compute_smart_initial_zoom(win_w, win_h, state.img_w, state.img_h, state.metrics)
		local target_fit = state.smart_zoom > 1.05 and state.smart_zoom or 2.0
		if math.abs(state.zoom - 1.0) < 0.05 then
			state.zoom = target_fit
		else
			state.zoom = 1.0
		end
		reset_pan_centered(win_w, win_h, state.zoom)
		render_viewport()
	end

	local function toggle_theme()
		state.theme = (state.theme == "light") and "dark" or "light"
		compile_and_show(false, false)
	end

	input.bind("n", mk.quit, close_modal, kopts)
	input.bind("n", mk.help, toggle_options_help, kopts)
	input.bind("n", mk.toggle_code, function()
		switch_to_code_mode(nil, nil)
	end, kopts)
	input.bind("n", mk.rerender, function()
		compile_and_show(true, false)
	end, kopts)

	input.bind("n", mk.zoom_in, function()
		zoom_by(1)
	end, kopts)
	input.bind("n", mk.zoom_out, function()
		zoom_by(-1)
	end, kopts)
	input.bind("n", mk.reset, reset_view, kopts)
	input.bind("n", mk.toggle_fit, toggle_fit, kopts)
	input.bind("n", mk.toggle_theme, toggle_theme, kopts)
	vim.keymap.set("n", "a", ascii.notify_coming_soon, kopts)

	input.bind("n", mk.pan_left, function()
		pan(-1, 0)
	end, kopts)
	input.bind("n", mk.pan_right, function()
		pan(1, 0)
	end, kopts)
	input.bind("n", mk.pan_up, function()
		pan(0, -1)
	end, kopts)
	input.bind("n", mk.pan_down, function()
		pan(0, 1)
	end, kopts)

	input.attach_gestures(state.canvas_buf, {
		zoom = zoom_by,
		pan = pan,
		drag_cells = drag_cells,
		reset = reset_view,
		toggle_fit = toggle_fit,
		touchpad_key = mk.toggle_touchpad,
		initial_wheel_mode = state.touchpad_mode,
	})

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
				local new_box = viewport.compute_modal_box(
					state.metrics,
					build_header_title(state.filename, state.view_mode),
					state.modal_cfg
				)
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
				if state.view_mode == "preview" then
					render_viewport()
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "FocusGained", "WinEnter" }, {
		group = state.augroup,
		callback = function()
			if
				state.view_mode == "preview"
				and state.win
				and vim.api.nvim_win_is_valid(state.win)
				and state.png_path
			then
				state.metrics = terminal.get_console_metrics()
				vim.schedule(function()
					kitty.clear_all_placements()
					kitty.transmit_file(state.img_id, state.png_path)
					render_viewport()
				end)
			end
		end,
	})

	apply_compiled_artifact(artifact, true)
end

return M
