--- @module mermaid_lens.ui.modal
--- Architectural Layer: Interface Adapter / View Controller
--- Parent: `mermaid_lens.init`
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.config.state`,
---           `mermaid_lens.env.terminal`, `mermaid_lens.graphics.viewport`,
---           `mermaid_lens.graphics.camera`, `mermaid_lens.graphics.layer_manager`,
---           `mermaid_lens.renderer.compiler`, `mermaid_lens.renderer.diagnostics`,
---           `mermaid_lens.renderer.ascii`, `mermaid_lens.editor.sync`,
---           `mermaid_lens.ui.input`, `mermaid_lens.ui.code_view`,
---           `mermaid_lens.ui.help`, `mermaid_lens.ui.loader`
--- Single Responsibility: Orchestrate the dual-mode (`Preview` <-> `Code/Edit`)
--- modal window lifecycle, backdrop, key/gesture wiring, and scoped editor events.

local constants = require("mermaid_lens.config.constants")
local config_state = require("mermaid_lens.config.state")
local terminal = require("mermaid_lens.env.terminal")
local viewport = require("mermaid_lens.graphics.viewport")
local camera_mod = require("mermaid_lens.graphics.camera")
local layer_manager_mod = require("mermaid_lens.graphics.layer_manager")
local compiler = require("mermaid_lens.renderer.compiler")
local diagnostics = require("mermaid_lens.renderer.diagnostics")
local ascii = require("mermaid_lens.renderer.ascii")
local sync = require("mermaid_lens.editor.sync")
local input = require("mermaid_lens.ui.input")
local code_view = require("mermaid_lens.ui.code_view")
local help = require("mermaid_lens.ui.help")
local loader = require("mermaid_lens.ui.loader")

local M = {}

local camera = camera_mod.new()
local layers = layer_manager_mod.new()

local state = {
	canvas_buf = nil,
	code_buf = nil,
	win = nil,
	backdrop_buf = nil,
	backdrop_win = nil,
	augroup = nil,
	closing = false,
	view_mode = "preview",
	name = "Mermaid",
	filename = "Mermaid",
	diagram = nil,
	last_rendered_code = nil,
	has_valid_render = false,
	theme = "light",
	metrics = nil,
	backdrop_enabled = true,
	backdrop_blend = 45,
	auto_render_on_save = true,
	save_parent_on_write = true,
	fallback_to_code = true,
	scale = 3,
	max_text_size = nil,
	touchpad_mode = "zoom",
	modal_cfg = {},
	modal_keys = {},
}

local function setup_highlights()
	vim.api.nvim_set_hl(0, "MermaidLensBackdrop", { bg = "#05060a", default = true })
	vim.api.nvim_set_hl(0, "MermaidLensBorder", { fg = "#565f89", bg = "#16161e", default = true })
	vim.api.nvim_set_hl(0, "MermaidLensTitle", { fg = "#c0caf5", bg = "#16161e", bold = true, default = true })
	vim.api.nvim_set_hl(0, "MermaidLensModeBadge", { fg = "#9ece6a", bg = "#16161e", bold = true, default = true })
	vim.api.nvim_set_hl(0, "MermaidLensKeyHint", { fg = "#7aa2f7", bg = "#16161e", bold = true, default = true })
	vim.api.nvim_set_hl(0, "MermaidLensCloseHint", { fg = "#f7768e", bg = "#16161e", bold = true, default = true })
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

local function is_preview_active()
	return state.view_mode == "preview" and state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
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

local function render_viewport()
	if not is_preview_active() or help.is_open() or not layers:has_overview() then
		return
	end
	layers:render({
		camera = camera,
		win_w = vim.api.nvim_win_get_width(state.win),
		win_h = vim.api.nvim_win_get_height(state.win),
		win_pos = vim.api.nvim_win_get_position(state.win),
		metrics = state.metrics,
		border = state.modal_cfg.border,
	})
end

local function schedule_vector_sharpen()
	if not is_preview_active() then
		layers:stop_sharpen_timer()
		return
	end
	layers:schedule_sharpen({
		camera = camera,
		get_live_context = function()
			if not is_preview_active() or not state.diagram then
				return nil
			end
			return {
				win_w = vim.api.nvim_win_get_width(state.win),
				win_h = vim.api.nvim_win_get_height(state.win),
				metrics = state.metrics,
				diagram = state.diagram,
				theme = state.theme,
			}
		end,
		on_tile_ready = render_viewport,
	})
end

local function switch_to_code_mode(err_info, severity)
	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		return
	end
	layers:stop_sharpen_timer()
	state.view_mode = "code"
	layers:clear_placements()
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
	layers:clear_placements()
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

	local img_w = math.max(1, artifact.img_w or state.metrics.screen_px_w)
	local img_h = math.max(1, artifact.img_h or state.metrics.screen_px_h)
	local rw = math.max(1, artifact.raster_w or img_w)
	local rh = math.max(1, artifact.raster_h or img_h)

	code_view.deactivate(state.win, state.canvas_buf, build_header_title(state.filename, "preview"))

	local win_w = vim.api.nvim_win_get_width(state.win)
	local win_h = vim.api.nvim_win_get_height(state.win)
	camera:apply_image(img_w, img_h, win_w, win_h, state.metrics, reset_camera)

	vim.cmd("redraw")
	layers:set_overview(artifact.png_path, img_w, img_h, rw, rh)
	render_viewport()
	if not reset_camera and camera.zoom > 1.02 then
		schedule_vector_sharpen()
	end
end

local function compile_and_show(force_recompile, reset_camera)
	if not state.diagram then
		return
	end
	local delivered = false
	compiler.compile(state.diagram, {
		theme = state.theme,
		scale = state.scale,
		max_text_size = state.max_text_size,
		force_recompile = force_recompile,
		fallback_to_code = state.fallback_to_code,
		on_compile_start = function(d, theme)
			loader.start(d.name, theme, current_modal_box())
		end,
		on_compile_end = function(done)
			loader.stop(function()
				done()
				if not delivered and state.view_mode == "preview" and state.has_valid_render then
					render_viewport()
				end
			end)
		end,
	}, function(new_artifact)
		delivered = true
		apply_compiled_artifact(new_artifact, reset_camera)
	end)
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

local function close_modal()
	if state.closing then
		return
	end
	state.closing = true

	if state.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
		state.augroup = nil
	end
	help.close()
	layers:teardown()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	state.win = nil
	if state.canvas_buf and vim.api.nvim_buf_is_valid(state.canvas_buf) then
		pcall(vim.api.nvim_buf_delete, state.canvas_buf, { force = true })
	end
	state.canvas_buf = nil
	state.code_buf = nil
	close_backdrop()
	input.restore_mouse()
	state.closing = false
	vim.cmd("redraw!")
end

local function toggle_options_help()
	help.toggle(state.win, state.name, state.modal_keys, {
		on_open = function()
			layers:clear_placements()
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

--- Closes the active modal, backdrop, help popup, and GPU layers if currently open.
function M.close()
	if
		not state.win
		and not state.backdrop_win
		and not state.augroup
		and not state.canvas_buf
		and not layers:has_overview()
		and not help.is_open()
	then
		input.restore_mouse()
		return
	end
	close_modal()
end

--- Opens the interactive dual-mode modal for a compiled or fallback diagram artifact.
--- @param artifact RenderedDiagramArtifact
--- @param opts table|nil
function M.open(artifact, opts)
	opts = opts or {}
	local cfg = config_state.get()

	state.backdrop_enabled = opts.backdrop ~= nil and opts.backdrop or cfg.backdrop
	state.backdrop_blend = opts.backdrop_blend or cfg.backdrop_blend
	state.theme = opts.theme or artifact.theme or cfg.theme or "light"
	state.auto_render_on_save = cfg.auto_render_on_save ~= false
	state.save_parent_on_write = cfg.save_parent_on_write ~= false
	state.fallback_to_code = cfg.fallback_to_code ~= false
	state.scale = cfg.scale or constants.COMPILER.DEFAULT_SCALE
	state.max_text_size = cfg.max_text_size
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

	state.code_buf = code_view.get_or_create_buffer(state.diagram, state.modal_keys, {
		on_save = function(new_lines, save_opts)
			save_opts = save_opts or {}
			local new_code = table.concat(new_lines, "\n")
			if new_code == state.diagram.code then
				vim.notify("MermaidLens: No changes detected.", vim.log.levels.INFO)
				return true
			end

			local ok, err_msg = sync.apply_changes(state.diagram, new_lines, {
				write_to_disk = state.save_parent_on_write,
			})
			if not ok then
				vim.notify("MermaidLens: " .. tostring(err_msg), vim.log.levels.ERROR)
				return false
			end

			vim.notify("MermaidLens: Saved changes to " .. state.filename, vim.log.levels.INFO)
			if state.auto_render_on_save and not save_opts.skip_render then
				compile_and_show(true, false)
			end
			return true
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

	local modal_border = state.modal_cfg.border or "rounded"
	local has_border = modal_border ~= "none" and modal_border ~= ""
	local win_opts = {
		relative = "editor",
		width = box.width,
		height = box.height,
		row = box.row,
		col = box.col,
		style = "minimal",
		border = modal_border,
		zindex = constants.UI.MODAL_ZINDEX,
	}
	if has_border then
		win_opts.title = box.title
		win_opts.title_pos = "center"
	end
	state.win = vim.api.nvim_open_win(state.canvas_buf, true, win_opts)
	vim.wo[state.win].winhl = "FloatBorder:MermaidLensBorder"

	input.lock_buffer_keys(state.canvas_buf)

	local kopts = { buffer = state.canvas_buf, silent = true, nowait = true }
	local mk = state.modal_keys

	local function with_preview_camera(fn)
		if not is_preview_active() then
			return
		end
		fn(vim.api.nvim_win_get_width(state.win), vim.api.nvim_win_get_height(state.win))
		render_viewport()
		schedule_vector_sharpen()
	end

	local function zoom_by(delta)
		with_preview_camera(function(win_w, win_h)
			camera:zoom_by(delta, win_w, win_h, state.metrics)
		end)
	end

	local function pan(dx, dy)
		with_preview_camera(function(win_w, win_h)
			camera:pan(dx, dy, win_w, win_h, state.metrics)
		end)
	end

	local function drag_cells(d_cols, d_rows)
		with_preview_camera(function(win_w, win_h)
			camera:drag_cells(d_cols, d_rows, win_w, win_h, state.metrics)
		end)
	end

	local function reset_view()
		with_preview_camera(function(win_w, win_h)
			camera:reset(win_w, win_h, state.metrics)
		end)
	end

	local function toggle_fit()
		with_preview_camera(function(win_w, win_h)
			camera:toggle_fit(win_w, win_h, state.metrics)
		end)
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
	input.bind("n", mk.ascii, ascii.notify_coming_soon, kopts)

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

	state.augroup = vim.api.nvim_create_augroup("MermaidLensModal_" .. layers.overview_img_id, { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.augroup,
		pattern = tostring(state.win),
		callback = function()
			close_modal()
		end,
	})
	vim.api.nvim_create_autocmd({ "VimLeavePre", "VimLeave" }, {
		group = state.augroup,
		callback = function()
			close_modal()
		end,
	})
	vim.api.nvim_create_autocmd({ "FocusLost", "VimSuspend" }, {
		group = state.augroup,
		callback = function()
			layers:clear_placements()
		end,
	})
	vim.api.nvim_create_autocmd("WinLeave", {
		group = state.augroup,
		callback = function()
			if state.win and vim.api.nvim_get_current_win() == state.win then
				layers:clear_placements()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = state.augroup,
		buffer = state.canvas_buf,
		callback = function()
			layers:clear_placements()
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
				local resize_cfg = {
					relative = "editor",
					width = new_box.width,
					height = new_box.height,
					row = new_box.row,
					col = new_box.col,
				}
				if has_border then
					resize_cfg.title = new_box.title
					resize_cfg.title_pos = "center"
				end
				vim.api.nvim_win_set_config(state.win, resize_cfg)
				vim.cmd("redraw")
				layers:clear_placements()
				if state.view_mode == "preview" then
					render_viewport()
					schedule_vector_sharpen()
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "FocusGained", "WinEnter" }, {
		group = state.augroup,
		callback = function()
			if
				is_preview_active()
				and vim.api.nvim_get_current_win() == state.win
				and layers:has_overview()
			then
				state.metrics = terminal.get_console_metrics()
				vim.schedule(function()
					if is_preview_active() and vim.api.nvim_get_current_win() == state.win then
						layers:clear_placements()
						render_viewport()
					end
				end)
			end
		end,
	})

	apply_compiled_artifact(artifact, true)
end

return M
