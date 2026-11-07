--- @module mermaid_lens.renderer.cache
--- Architectural Layer: Infrastructure / Repository
--- Parent: `mermaid_lens.renderer.compiler` and `mermaid_lens.ui.modal`
--- Children: None (Leaf module).
--- Single Responsibility: Manage deterministic cache file paths with embedded vector
--- dimensions (`_WxH.png`), RAM-backed rotary viewport tiles, and PNG header dimensions.

local M = {}

local cache_dir = vim.fn.stdpath("cache") .. "/mermaid_lens"
local shm_dir = "/dev/shm"

--- Ensures the plugin cache directory exists on disk.
--- @return string cache_dir
function M.ensure_dir()
	if vim.fn.isdirectory(cache_dir) == 0 then
		vim.fn.mkdir(cache_dir, "p")
	end
	return cache_dir
end

--- Builds deterministic paths and templates for a diagram and theme.
--- @param diagram MermaidDiagramEntry
--- @param theme "light"|"dark"
--- @return { cache_key: string, base_prefix: string, mmd_path: string, png_path: string, png_template: string, puppeteer_cfg: string, mermaid_cfg: string }
function M.resolve_paths(diagram, theme)
	M.ensure_dir()
	local hash = vim.fn.sha256(diagram.code):sub(1, 16)
	local safe_name = (diagram.name or "diagram"):gsub("[^%w_%-]", "_")
	local base = string.format("%s/%s_%s_%s", cache_dir, theme, safe_name, hash)

	return {
		cache_key = theme .. "_" .. hash,
		base_prefix = base,
		mmd_path = base .. ".mmd",
		png_path = base .. ".png",
		png_template = base .. "_{W}x{H}.png",
		puppeteer_cfg = cache_dir .. "/puppeteer-config.json",
		mermaid_cfg = string.format("%s/mermaid-config-%s.json", cache_dir, theme),
	}
end

--- Searches for an existing cached overview PNG (`_<svg_w>x<svg_h>.png` or legacy `.png`)
--- and returns its path, logical SVG dimensions, and physical raster dimensions.
--- @param paths table Result of `M.resolve_paths`
--- @return { png_path: string, svg_w: integer, svg_h: integer, raster_w: integer, raster_h: integer }|nil
function M.find_cached_overview(paths)
	local matches = vim.fn.glob(paths.base_prefix .. "_*x*.png", false, true)
	if type(matches) == "table" and #matches > 0 then
		local candidate = matches[1]
		local sw, sh = candidate:match("_(%d+)x(%d+)%.png$")
		local rw, rh = M.read_png_dimensions(candidate)
		if rw and rh then
			return {
				png_path = candidate,
				svg_w = tonumber(sw) or rw,
				svg_h = tonumber(sh) or rh,
				raster_w = rw,
				raster_h = rh,
			}
		end
	end

	if vim.fn.filereadable(paths.png_path) == 1 then
		local rw, rh = M.read_png_dimensions(paths.png_path)
		if rw and rh then
			return {
				png_path = paths.png_path,
				svg_w = rw,
				svg_h = rh,
				raster_w = rw,
				raster_h = rh,
			}
		end
	end

	return nil
end

--- Returns a fast rotary file path (preferring Linux tmpfs `/dev/shm`) for live viewport tiles.
--- @param slot integer 0 or 1
--- @return string
function M.get_viewport_tile_path(slot)
	local pid = vim.fn.getpid()
	local base_dir = (vim.fn.isdirectory(shm_dir) == 1 and vim.fn.filewritable(shm_dir) == 2) and shm_dir
		or M.ensure_dir()
	return string.format("%s/mermaid_lens_vp_%d_%d.png", base_dir, pid, slot % 2)
end

--- Removes temporary rotary viewport tiles created by this Neovim PID.
function M.cleanup_viewport_tiles()
	for slot = 0, 1 do
		local p = M.get_viewport_tile_path(slot)
		if vim.fn.filereadable(p) == 1 then
			pcall(vim.fn.delete, p)
		end
	end
end

--- Reads the exact pixel width and height from the big-endian IHDR chunk of a PNG file.
--- @param png_path string Absolute path to the compiled PNG file
--- @return integer|nil width, integer|nil height
function M.read_png_dimensions(png_path)
	local f = io.open(png_path, "rb")
	if not f then
		return nil, nil
	end
	local header = f:read(24)
	f:close()
	if not header or #header < 24 then
		return nil, nil
	end

	local function read_u32_be(offset)
		local b1, b2, b3, b4 = header:byte(offset, offset + 3)
		return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
	end

	local w = read_u32_be(17)
	local h = read_u32_be(21)
	if w > 0 and h > 0 then
		return w, h
	end
	return nil, nil
end

return M
