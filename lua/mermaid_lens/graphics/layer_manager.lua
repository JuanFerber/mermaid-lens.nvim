--- @module mermaid_lens.graphics.layer_manager
--- Architectural Layer: Interface Adapter / GPU Graphics Layer Controller
--- Parent: `mermaid_lens.ui.modal`
--- Children: `mermaid_lens.graphics.kitty`, `mermaid_lens.graphics.viewport`,
---           `mermaid_lens.renderer.compiler`, `mermaid_lens.renderer.cache`
--- Single Responsibility: Manage Kitty dual-layer GPU textures (overview + rotating
--- high-DPI vector zoom tiles), debounced re-rasterization, and flicker-free placement transitions.

local kitty = require("mermaid_lens.graphics.kitty")
local viewport = require("mermaid_lens.graphics.viewport")
local compiler = require("mermaid_lens.renderer.compiler")
local cache = require("mermaid_lens.renderer.cache")

local M = {}
M.__index = M

local SHARPEN_DEBOUNCE_MS = 60
local MAX_TILE_PX = 2880

--- @class MermaidLayerManager
--- @field base_img_id integer Base Kitty image ID unique to this Neovim PID
--- @field overview_img_id integer Kitty image ID for the overview layer
--- @field tile_img_id integer|nil Kitty image ID for the active high-DPI zoom tile
--- @field tile_slot integer Rotating slot index (`0` or `1`) for flicker-free tile swaps
--- @field png_path string|nil Path to the active overview PNG
--- @field tile_png_path string|nil Path to the active zoom tile PNG
--- @field overview_tex_rect table Texture bounds of the overview image
--- @field tile_tex_rect table|nil Texture bounds of the active zoom tile
--- @field sharpen_timer userdata|nil Active libuv debounce timer

--- Creates a dual-layer Kitty GPU texture manager.
--- @param base_img_id integer|nil Optional deterministic base ID (defaults to PID-scoped ID)
--- @return MermaidLayerManager
function M.new(base_img_id)
	local base_id = base_img_id or (((vim.fn.getpid() % 100000000) * 3) + 1000)
	return setmetatable({
		base_img_id = base_id,
		overview_img_id = base_id,
		tile_img_id = nil,
		tile_slot = 0,
		png_path = nil,
		tile_png_path = nil,
		overview_tex_rect = { x = 0, y = 0, w = 1, h = 1, raster_w = 1, raster_h = 1 },
		tile_tex_rect = nil,
		sharpen_timer = nil,
		generation = 0,
	}, M)
end

--- Stops and closes the debounced vector sharpen timer if active.
function M:stop_sharpen_timer()
	if self.sharpen_timer then
		pcall(function()
			self.sharpen_timer:stop()
			self.sharpen_timer:close()
		end)
		self.sharpen_timer = nil
	end
end

--- Deletes the active zoomed tile from Kitty GPU memory and clears its metadata.
function M:clear_zoom_tile()
	if self.tile_img_id then
		kitty.delete_image(self.tile_img_id)
		self.tile_img_id = nil
	end
	self.tile_tex_rect = nil
	self.tile_png_path = nil
end

--- Clears visible placements of owned Kitty images without freeing uploaded texture buffers.
function M:clear_placements()
	kitty.clear_all_placements()
end

--- Returns whether an overview texture is currently loaded.
--- @return boolean
function M:has_overview()
	return self.png_path ~= nil
end

--- Replaces the overview texture in Kitty GPU memory and resets any previous zoom tile.
--- @param png_path string
--- @param img_w integer
--- @param img_h integer
--- @param raster_w integer
--- @param raster_h integer
function M:set_overview(png_path, img_w, img_h, raster_w, raster_h)
	self.generation = self.generation + 1
	self:stop_sharpen_timer()
	self.png_path = png_path
	self.overview_tex_rect = {
		x = 0,
		y = 0,
		w = math.max(1, img_w),
		h = math.max(1, img_h),
		raster_w = math.max(1, raster_w),
		raster_h = math.max(1, raster_h),
	}

	kitty.clear_all_placements()
	self:clear_zoom_tile()
	kitty.delete_image(self.overview_img_id)
	kitty.transmit_file(self.overview_img_id, self.png_path)
end

--- Projects the active camera onto either the crisp zoom tile (when contained) or overview texture,
--- placing the active layer FIRST so Kitty never flashes a blank frame.
--- @param ctx { camera: MermaidCamera, win_w: integer, win_h: integer, win_pos: integer[], metrics: ConsoleMetrics, border?: string }
--- @return { use_tile: boolean, active_img_id: integer, vp: ViewportProjection, screen_row: integer, screen_col: integer }|nil
function M:render(ctx)
	if not self.png_path then
		return nil
	end

	local camera = ctx.camera
	local vp = camera:project(ctx.win_w, ctx.win_h, ctx.metrics)
	camera:sync_pan(vp)

	local use_tile = camera.zoom > 1.02
		and self.tile_img_id ~= nil
		and viewport.is_contained_in_texture(vp, self.tile_tex_rect)

	local active_img_id = use_tile and self.tile_img_id or self.overview_img_id
	local active_rect = use_tile and self.tile_tex_rect or self.overview_tex_rect
	local tex_crop = viewport.map_to_texture(vp, active_rect)

	local border = ctx.border
	local border_pad = (border == "none" or border == "") and 0 or 1
	local screen_row = ctx.metrics.tmux_top + ctx.win_pos[1] + 1 + border_pad + vp.offset_row
	local screen_col = ctx.metrics.tmux_left + ctx.win_pos[2] + 1 + border_pad + vp.offset_col

	-- 1. Place the active image FIRST so Kitty never displays a blank frame
	kitty.place_viewport({
		img_id = active_img_id,
		x = tex_crop.x,
		y = tex_crop.y,
		w = tex_crop.w,
		h = tex_crop.h,
		cols = vp.dst_cols,
		rows = vp.dst_rows,
		screen_row = screen_row,
		screen_col = screen_col,
	})

	-- 2. Clean up the inactive layer AFTER the new placement is already on screen
	if use_tile then
		kitty.send({ a = "d", d = "i", i = self.overview_img_id, p = 1, q = 2 })
	elseif self.tile_img_id then
		self:clear_zoom_tile()
	end

	return {
		use_tile = use_tile,
		active_img_id = active_img_id,
		vp = vp,
		screen_row = screen_row,
		screen_col = screen_col,
	}
end

--- Schedules a debounced vector re-rasterization with a 2.0x overscan margin around `camera`
--- so subsequent pan and zoom steps remain sharp without dropping back to overview.
--- @param ctx { camera: MermaidCamera, get_live_context: fun(): { win_w: integer, win_h: integer, metrics: ConsoleMetrics, diagram: MermaidDiagramEntry, theme: "light"|"dark" }|nil, on_tile_ready: fun() }
function M:schedule_sharpen(ctx)
	self:stop_sharpen_timer()

	if ctx.camera.zoom <= 1.02 then
		if self.tile_img_id and ctx.on_tile_ready then
			ctx.on_tile_ready()
		end
		return
	end

	local req_gen = self.generation
	self.sharpen_timer = vim.uv.new_timer()
	self.sharpen_timer:start(
		SHARPEN_DEBOUNCE_MS,
		0,
		vim.schedule_wrap(function()
			self:stop_sharpen_timer()
			if req_gen ~= self.generation then
				return
			end
			local live = ctx.get_live_context()
			if not live then
				return
			end

			local req = ctx.camera:compute_tile_request(live.win_w, live.win_h, live.metrics, MAX_TILE_PX)

			compiler.raster_viewbox(live.diagram, {
				theme = live.theme,
				crop = req.crop,
				raster_w = req.raster_w,
				raster_h = req.raster_h,
			}, function(tile)
				if req_gen ~= self.generation or not tile or not ctx.get_live_context() then
					return
				end

				local prev_tile_id = self.tile_img_id
				self.tile_slot = (self.tile_slot + 1) % 2
				local next_tile_id = self.base_img_id + 1 + self.tile_slot

				kitty.transmit_file(next_tile_id, tile.png_path)
				self.tile_img_id = next_tile_id
				self.tile_png_path = tile.png_path
				self.tile_tex_rect = {
					x = tile.crop.x,
					y = tile.crop.y,
					w = tile.crop.w,
					h = tile.crop.h,
					raster_w = tile.raster_w,
					raster_h = tile.raster_h,
				}

				if ctx.on_tile_ready then
					ctx.on_tile_ready()
				end
				if prev_tile_id and prev_tile_id ~= next_tile_id then
					kitty.delete_image(prev_tile_id)
				end
			end)
		end)
	)
end

--- Releases timers, Kitty GPU images owned by this manager, and temporary viewport tile files.
function M:teardown()
	self.generation = self.generation + 1
	self:stop_sharpen_timer()
	self:clear_zoom_tile()
	kitty.delete_image(self.overview_img_id)
	kitty.delete_all_owned_images()
	pcall(cache.cleanup_viewport_tiles)
	self.png_path = nil
end

return M
