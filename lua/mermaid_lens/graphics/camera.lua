--- @module mermaid_lens.graphics.camera
--- Architectural Layer: Domain Math / Stateful Camera Controller
--- Parent: `mermaid_lens.ui.modal` and `mermaid_lens.graphics.layer_manager`
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.graphics.viewport`
--- Single Responsibility: Encapsulate pure 2D camera state (`zoom`, `pan_x`, `pan_y`,
--- `smart_zoom`, logical image dimensions) and window-free pan, zoom, drag, fit,
--- and overscan viewBox tile math.

local constants = require("mermaid_lens.config.constants")
local viewport = require("mermaid_lens.graphics.viewport")

local M = {}
M.__index = M

--- @class MermaidCamera
--- @field img_w integer Logical vector width
--- @field img_h integer Logical vector height
--- @field zoom number Current camera zoom factor
--- @field smart_zoom number Computed width-fit zoom factor for tall diagrams
--- @field pan_x number Camera left X coordinate in image pixels
--- @field pan_y number Camera top Y coordinate in image pixels

--- Creates a fresh 2D camera instance initialized to full-overview fit.
--- @return MermaidCamera
function M.new()
	return setmetatable({
		img_w = 1,
		img_h = 1,
		zoom = constants.LIMITS.MIN_ZOOM,
		smart_zoom = constants.LIMITS.MIN_ZOOM,
		pan_x = 0,
		pan_y = 0,
	}, M)
end

--- Projects the camera onto the given window dimensions and console metrics.
--- @param win_w integer
--- @param win_h integer
--- @param metrics ConsoleMetrics
--- @param zoom_override number|nil
--- @return ViewportProjection
function M:project(win_w, win_h, metrics, zoom_override)
	return viewport.project({
		win_width = win_w,
		win_height = win_h,
		img_w = self.img_w,
		img_h = self.img_h,
		zoom = zoom_override or self.zoom,
		pan_x = self.pan_x,
		pan_y = self.pan_y,
		metrics = metrics,
	})
end

--- Synchronizes clamped pan coordinates returned by a projection.
--- @param vp ViewportProjection
function M:sync_pan(vp)
	self.pan_x = vp.pan_x
	self.pan_y = vp.pan_y
end

--- Centers the camera horizontally (and vertically for overview / near-fit zooms; top-aligned when zoomed into tall diagrams).
--- @param win_w integer
--- @param win_h integer
--- @param metrics ConsoleMetrics
--- @param zoom_override number|nil
function M:reset_pan_centered(win_w, win_h, metrics, zoom_override)
	local target_zoom = zoom_override or self.zoom
	local vp = self:project(win_w, win_h, metrics, target_zoom)
	self.pan_x = (self.img_w - vp.cam_w) / 2
	if target_zoom <= 1.05 or vp.cam_h >= self.img_h * 0.85 then
		self.pan_y = (self.img_h - vp.cam_h) / 2
	else
		self.pan_y = 0
	end
end

--- Applies new logical image dimensions, recalculates `smart_zoom`, and optionally resets the camera to full overview.
--- @param img_w integer
--- @param img_h integer
--- @param win_w integer
--- @param win_h integer
--- @param metrics ConsoleMetrics
--- @param reset_camera boolean
function M:apply_image(img_w, img_h, win_w, win_h, metrics, reset_camera)
	self.img_w = math.max(1, img_w)
	self.img_h = math.max(1, img_h)
	self.smart_zoom = viewport.compute_smart_initial_zoom(win_w, win_h, self.img_w, self.img_h, metrics)
	if reset_camera then
		self.zoom = constants.LIMITS.MIN_ZOOM
		self:reset_pan_centered(win_w, win_h, metrics, self.zoom)
	end
end

--- Zooms in (`delta > 0`) or out (`delta <= 0`) while keeping the current viewport center pinned.
--- @param delta number
--- @param win_w integer
--- @param win_h integer
--- @param metrics ConsoleMetrics
function M:zoom_by(delta, win_w, win_h, metrics)
	local old_vp = self:project(win_w, win_h, metrics, self.zoom)
	local center_x = old_vp.pan_x + (old_vp.cam_w / 2)
	local center_y = old_vp.pan_y + (old_vp.cam_h / 2)

	local factor = delta > 0 and constants.LIMITS.ZOOM_STEP_IN or constants.LIMITS.ZOOM_STEP_OUT
	self.zoom = math.max(constants.LIMITS.MIN_ZOOM, math.min(self.zoom * factor, constants.LIMITS.MAX_ZOOM))

	local new_vp = self:project(win_w, win_h, metrics, self.zoom)
	self.pan_x = center_x - (new_vp.cam_w / 2)
	self.pan_y = center_y - (new_vp.cam_h / 2)
end

--- Pans the camera by proportional directional steps `(dx, dy)`.
--- @param dx number
--- @param dy number
--- @param win_w integer
--- @param win_h integer
--- @param metrics ConsoleMetrics
function M:pan(dx, dy, win_w, win_h, metrics)
	local vp = self:project(win_w, win_h, metrics, self.zoom)
	local step_x = math.max(constants.LIMITS.MIN_PAN_STEP_PX, vp.cam_w * constants.LIMITS.PAN_STEP_RATIO)
	local step_y = math.max(constants.LIMITS.MIN_PAN_STEP_PX, vp.cam_h * constants.LIMITS.PAN_STEP_RATIO)
	self.pan_x = vp.pan_x + (dx * step_x)
	self.pan_y = vp.pan_y + (dy * step_y)
end

--- Pans the camera by exact terminal cell deltas `(d_cols, d_rows)` for mouse click-drag gestures.
--- @param d_cols number
--- @param d_rows number
--- @param win_w integer
--- @param win_h integer
--- @param metrics ConsoleMetrics
function M:drag_cells(d_cols, d_rows, win_w, win_h, metrics)
	local vp = self:project(win_w, win_h, metrics, self.zoom)
	local dx_px = (d_cols * metrics.cell_w) / vp.scale
	local dy_px = (d_rows * metrics.cell_h) / vp.scale
	self.pan_x = vp.pan_x + dx_px
	self.pan_y = vp.pan_y + dy_px
end

--- Resets the camera back to `MIN_ZOOM` centered overview.
--- @param win_w integer
--- @param win_h integer
--- @param metrics ConsoleMetrics
function M:reset(win_w, win_h, metrics)
	self.zoom = constants.LIMITS.MIN_ZOOM
	self:reset_pan_centered(win_w, win_h, metrics, self.zoom)
end

--- Toggles between full overview (`MIN_ZOOM`) and readable width-fit (`smart_zoom` / `DEFAULT_FIT_ZOOM`).
--- @param win_w integer
--- @param win_h integer
--- @param metrics ConsoleMetrics
function M:toggle_fit(win_w, win_h, metrics)
	self.smart_zoom = viewport.compute_smart_initial_zoom(win_w, win_h, self.img_w, self.img_h, metrics)
	local target_fit = self.smart_zoom > 1.05 and self.smart_zoom or constants.LIMITS.DEFAULT_FIT_ZOOM
	if math.abs(self.zoom - constants.LIMITS.MIN_ZOOM) < 0.05 then
		self.zoom = target_fit
	else
		self.zoom = constants.LIMITS.MIN_ZOOM
	end
	self:reset_pan_centered(win_w, win_h, metrics, self.zoom)
end

--- Computes the 2.0x overscan vector viewBox crop and physical raster target dimensions
--- for high-DPI tile rasterization around the current camera viewport.
--- @param win_w integer
--- @param win_h integer
--- @param metrics ConsoleMetrics
--- @param max_tile_px integer|nil Maximum raster dimension per axis (default 2880)
--- @return { crop: { x: integer, y: integer, w: integer, h: integer }, raster_w: integer, raster_h: integer }
function M:compute_tile_request(win_w, win_h, metrics, max_tile_px)
	local vp = self:project(win_w, win_h, metrics, self.zoom)
	local limit = max_tile_px or 2880

	-- 2.0x overscan region (50% extra margin on each side) clamped to SVG bounds
	-- so normal panning and zooming stay inside the crisp tile.
	local pad_x = vp.src_w * 0.5
	local pad_y = vp.src_h * 0.5
	local crop_x1 = math.max(0, math.floor(vp.src_x - pad_x))
	local crop_y1 = math.max(0, math.floor(vp.src_y - pad_y))
	local crop_x2 = math.min(self.img_w, math.ceil(vp.src_x + vp.src_w + pad_x))
	local crop_y2 = math.min(self.img_h, math.ceil(vp.src_y + vp.src_h + pad_y))
	local crop_w = math.max(1, crop_x2 - crop_x1)
	local crop_h = math.max(1, crop_y2 - crop_y1)

	local density = math.min(vp.scale, limit / crop_w, limit / crop_h)
	local target_raster_w = math.max(64, math.floor(crop_w * density + 0.5))
	local target_raster_h = math.max(64, math.floor(crop_h * density + 0.5))

	return {
		crop = {
			x = crop_x1,
			y = crop_y1,
			w = crop_w,
			h = crop_h,
		},
		raster_w = target_raster_w,
		raster_h = target_raster_h,
	}
end

return M
