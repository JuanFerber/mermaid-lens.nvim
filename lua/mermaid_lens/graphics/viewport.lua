--- @module mermaid_lens.graphics.viewport
--- Architectural Layer: Domain Math
--- Parent: `mermaid_lens.ui.modal`, `mermaid_lens.ui.loader`, and `mermaid_lens.ui.help`
--- Children: `mermaid_lens.config.constants`
--- Single Responsibility: Compute modal and overlay window geometry, smart width-fit
--- zoom factors, aspect-ratio-preserving source crops, and 2D camera coordinates.

local constants = require("mermaid_lens.config.constants")

local M = {}

--- @class ViewportProjection
--- @field cam_w number Virtual camera width in image pixels
--- @field cam_h number Virtual camera height in image pixels
--- @field pan_x number Clamped virtual camera X position
--- @field pan_y number Clamped virtual camera Y position
--- @field src_x integer Clipped source texture X offset in pixels
--- @field src_y integer Clipped source texture Y offset in pixels
--- @field src_w integer Clipped source texture width in pixels
--- @field src_h integer Clipped source texture height in pixels
--- @field dst_cols integer Destination width in terminal columns
--- @field dst_rows integer Destination height in terminal rows
--- @field offset_col integer Column offset inside the modal window
--- @field offset_row integer Row offset inside the modal window
--- @field scale number Physical pixel scaling factor

--- Returns the usable editor area `(usable_cols, usable_rows, tabline_h)` excluding tabline and statusline.
--- @param ui_cols integer|nil
--- @param ui_rows integer|nil
--- @return integer usable_cols, integer usable_rows, integer tabline_h
function M.get_usable_editor_area(ui_cols, ui_rows)
	if not ui_cols or not ui_rows then
		local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }
		ui_cols = ui.width
		ui_rows = ui.height
	end
	local tabline_h = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1
		or 0
	local bottom_h = (vim.o.laststatus > 0 and 1 or 0) + vim.o.cmdheight
	local usable_rows = math.max(6, ui_rows - tabline_h - bottom_h)
	local usable_cols = math.max(20, ui_cols)
	return usable_cols, usable_rows, tabline_h
end

--- Computes centered `(row, col)` coordinates for a floating overlay of size `(w, h)`,
--- relative either to `parent_box` (if provided) or to the usable Neovim editor screen.
--- @param w integer Inner width of the floating window
--- @param h integer Inner height of the floating window
--- @param parent_box { row: integer, col: integer, width: integer, height: integer }|nil
--- @return integer row, integer col
function M.compute_centered_position(w, h, parent_box)
	if parent_box and parent_box.row and parent_box.col and parent_box.width and parent_box.height then
		local row = parent_box.row + math.floor(((parent_box.height + 2) - (h + 2)) / 2)
		local col = parent_box.col + math.floor(((parent_box.width + 2) - (w + 2)) / 2)
		return math.max(0, row), math.max(0, col)
	end

	local usable_cols, usable_rows, tabline_h = M.get_usable_editor_area()
	local row = tabline_h + math.max(0, math.floor((usable_rows - (h + 2)) / 2))
	local col = math.max(0, math.floor((usable_cols - (w + 2)) / 2))
	return row, col
end

--- Computes the centered floating modal dimensions adapted to the current `NxM` console size.
--- @param metrics ConsoleMetrics
--- @param title_chunks table
--- @param modal_cfg { width?: number, height?: number }|nil
--- @return { width: integer, height: integer, row: integer, col: integer, title: table }
function M.compute_modal_box(metrics, title_chunks, modal_cfg)
	modal_cfg = modal_cfg or {}
	local lim = constants.LIMITS
	local w_ratio = math.max(lim.MODAL_MIN_W_RATIO, math.min(lim.MODAL_MAX_W_RATIO, modal_cfg.width or 0.92))
	local h_ratio = math.max(lim.MODAL_MIN_H_RATIO, math.min(lim.MODAL_MAX_H_RATIO, modal_cfg.height or 0.90))

	local usable_cols, usable_rows, tabline_h = M.get_usable_editor_area(metrics.ui_cols, metrics.ui_rows)

	local width = math.max(16, math.floor(usable_cols * w_ratio) - 2)
	local height = math.max(4, math.floor(usable_rows * h_ratio) - 2)

	local row = tabline_h + math.max(0, math.floor((usable_rows - (height + 2)) / 2))
	local col = math.max(0, math.floor((usable_cols - (width + 2)) / 2))

	return {
		width = width,
		height = height,
		row = row,
		col = col,
		title = title_chunks,
	}
end

--- Calculates a readable width-fit zoom level (`f` toggle) for tall vertical diagrams.
--- @param win_width integer
--- @param win_height integer
--- @param img_w integer
--- @param img_h integer
--- @param metrics ConsoleMetrics
--- @return number
function M.compute_smart_initial_zoom(win_width, win_height, img_w, img_h, metrics)
	local lim = constants.LIMITS
	local canvas_cols = math.max(4, win_width)
	local canvas_rows = math.max(2, win_height)
	local canvas_px_w = canvas_cols * metrics.cell_w
	local canvas_px_h = canvas_rows * metrics.cell_h

	local fit_scale = math.min(canvas_px_w / img_w, canvas_px_h / img_h)
	local fit_cols = (img_w * fit_scale) / metrics.cell_w

	if fit_cols < (canvas_cols * lim.SMART_ZOOM_TRIGGER_RATIO) then
		return math.min(
			lim.SMART_ZOOM_MAX,
			math.max(lim.MIN_ZOOM, (canvas_cols * lim.SMART_ZOOM_TARGET_RATIO) / math.max(1, fit_cols))
		)
	end
	return lim.MIN_ZOOM
end

--- Projects the virtual 2D camera onto valid source texture pixels and modal character cells.
--- @param params { win_width: integer, win_height: integer, img_w: integer, img_h: integer, zoom: number, pan_x: number, pan_y: number, metrics: ConsoleMetrics }
--- @return ViewportProjection
function M.project(params)
	local m = params.metrics
	local canvas_cols = math.max(4, params.win_width)
	local canvas_rows = math.max(2, params.win_height)

	local canvas_px_w = canvas_cols * m.cell_w
	local canvas_px_h = canvas_rows * m.cell_h

	local base_scale = math.min(canvas_px_w / params.img_w, canvas_px_h / params.img_h)
	local scale = base_scale * params.zoom

	local cam_w = canvas_px_w / scale
	local cam_h = canvas_px_h / scale

	local min_pan_x = -cam_w / 2
	local max_pan_x = params.img_w - (cam_w / 2)
	local min_pan_y = -cam_h / 2
	local max_pan_y = params.img_h - (cam_h / 2)

	local clamped_pan_x = math.max(min_pan_x, math.min(params.pan_x, max_pan_x))
	local clamped_pan_y = math.max(min_pan_y, math.min(params.pan_y, max_pan_y))

	local src_x1 = math.max(0, clamped_pan_x)
	local src_y1 = math.max(0, clamped_pan_y)
	local src_x2 = math.min(params.img_w, clamped_pan_x + cam_w)
	local src_y2 = math.min(params.img_h, clamped_pan_y + cam_h)

	local src_w = math.max(1, src_x2 - src_x1)
	local src_h = math.max(1, src_y2 - src_y1)

	local dst_px_x = (src_x1 - clamped_pan_x) * scale
	local dst_px_y = (src_y1 - clamped_pan_y) * scale
	local dst_px_w = src_w * scale
	local dst_px_h = src_h * scale

	local offset_col = math.max(0, math.min(canvas_cols - 1, math.floor(dst_px_x / m.cell_w + 0.5)))
	local offset_row = math.max(0, math.min(canvas_rows - 1, math.floor(dst_px_y / m.cell_h + 0.5)))

	local dst_cols = math.max(1, math.min(canvas_cols - offset_col, math.floor(dst_px_w / m.cell_w + 0.5)))
	local dst_rows = math.max(1, math.min(canvas_rows - offset_row, math.floor(dst_px_h / m.cell_h + 0.5)))

	local int_x = math.max(0, math.min(params.img_w - 1, math.floor(src_x1 + 0.5)))
	local int_y = math.max(0, math.min(params.img_h - 1, math.floor(src_y1 + 0.5)))
	local int_w = math.max(1, math.min(params.img_w - int_x, math.floor(src_w + 0.5)))
	local int_h = math.max(1, math.min(params.img_h - int_y, math.floor(src_h + 0.5)))

	return {
		cam_w = cam_w,
		cam_h = cam_h,
		pan_x = clamped_pan_x,
		pan_y = clamped_pan_y,
		src_x = int_x,
		src_y = int_y,
		src_w = int_w,
		src_h = int_h,
		dst_cols = dst_cols,
		dst_rows = dst_rows,
		offset_col = offset_col,
		offset_row = offset_row,
		scale = scale,
	}
end

return M
