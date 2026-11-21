--- @module mermaid_lens.renderer.cache
--- Architectural Layer: Infrastructure / Repository
--- Parent: `mermaid_lens.renderer.compiler` and `mermaid_lens.ui.modal`
--- Children: None (Leaf module).
--- Single Responsibility: Manage deterministic cache file paths with embedded vector
--- dimensions (`_WxH.png`), RAM-backed rotary viewport tiles, and PNG header dimensions.

local M = {}

local cache_dir = vim.fn.stdpath("cache") .. "/mermaid_lens"
local shm_dir = "/dev/shm"
local PRIVATE_DIR_MODE = tonumber("700", 8)
local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

local function get_current_uid()
	if vim.uv and type(vim.uv.getuid) == "function" then
		local ok, uid = pcall(vim.uv.getuid)
		if ok and type(uid) == "number" then
			return uid
		end
	end
	return nil
end

--- Verifies (and optionally creates) a private `0700` non-symlink directory owned by the current UID.
--- @param dir string
--- @param create boolean
--- @return boolean
local function verify_private_dir(dir, create)
	if not dir or dir == "" then
		return false
	end

	local st = vim.uv.fs_lstat(dir)
	if not st then
		if not create then
			return false
		end
		local ok_mk = pcall(vim.fn.mkdir, dir, "p", PRIVATE_DIR_MODE)
		if not ok_mk then
			return false
		end
		st = vim.uv.fs_lstat(dir)
	end

	if not st or st.type ~= "directory" then
		return false
	end

	local uid = get_current_uid()
	if uid ~= nil and st.uid ~= nil and st.uid ~= uid then
		return false
	end

	if create and not is_windows then
		pcall(vim.uv.fs_chmod, dir, PRIVATE_DIR_MODE)
	end

	return vim.fn.filewritable(dir) == 2
end

--- Resolves a private `0700` directory for rotary viewport tiles, preferring RAM-backed tmpfs:
--- 1. `$XDG_RUNTIME_DIR/mermaid_lens`
--- 2. `/dev/shm/mermaid_lens_<uid>` (verified real directory owned by current UID)
--- 3. `<cache_dir>/tiles`
--- @param create boolean Whether to create the directory if missing
--- @return string|nil
local function resolve_private_tile_dir(create)
	local xdg_runtime = os.getenv("XDG_RUNTIME_DIR")
	if
		xdg_runtime
		and xdg_runtime ~= ""
		and vim.fn.isdirectory(xdg_runtime) == 1
		and vim.fn.filewritable(xdg_runtime) == 2
	then
		local clean_xdg = xdg_runtime:gsub("/+$", "")
		if clean_xdg ~= "" then
			local xdg_dir = clean_xdg .. "/mermaid_lens"
			if verify_private_dir(xdg_dir, create) then
				return xdg_dir
			end
		end
	end

	local uid = get_current_uid()
	if uid ~= nil and vim.fn.isdirectory(shm_dir) == 1 and vim.fn.filewritable(shm_dir) == 2 then
		local shm_private = string.format("%s/mermaid_lens_%d", shm_dir, uid)
		if verify_private_dir(shm_private, create) then
			return shm_private
		end
	end

	local fallback_base = create and M.ensure_dir() or cache_dir
	local fallback_tiles = fallback_base .. "/tiles"
	if verify_private_dir(fallback_tiles, create) then
		return fallback_tiles
	end

	return create and M.ensure_dir() or nil
end

--- Ensures the plugin cache directory exists on disk with private `0700` permissions.
--- @return string cache_dir
function M.ensure_dir()
	if vim.fn.isdirectory(cache_dir) == 0 then
		vim.fn.mkdir(cache_dir, "p", PRIVATE_DIR_MODE)
	end
	if not is_windows then
		pcall(vim.uv.fs_chmod, cache_dir, PRIVATE_DIR_MODE)
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

--- Returns a fast rotary file path inside a private `0700` directory
--- (preferring `$XDG_RUNTIME_DIR`, then `/dev/shm/mermaid_lens_<uid>`, then cache dir).
--- @param slot integer 0 or 1
--- @return string
function M.get_viewport_tile_path(slot)
	local pid = vim.fn.getpid()
	local base_dir = resolve_private_tile_dir(true) or M.ensure_dir()
	return string.format("%s/mermaid_lens_vp_%d_%d.png", base_dir, pid, slot % 2)
end

--- Removes temporary rotary viewport tiles created by this Neovim PID without creating directories.
function M.cleanup_viewport_tiles()
	local base_dir = resolve_private_tile_dir(false)
	if not base_dir then
		return
	end
	local pid = vim.fn.getpid()
	for slot = 0, 1 do
		local p = string.format("%s/mermaid_lens_vp_%d_%d.png", base_dir, pid, slot)
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
