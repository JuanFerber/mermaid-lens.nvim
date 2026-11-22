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
local CACHE_SCHEMA_VERSION = "v2"
local MAX_SAFE_NAME_LEN = 64
local DEFAULT_MAX_FILES = 100
local DEFAULT_MAX_BYTES = 100 * 1024 * 1024
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

--- Lists cached overview PNGs matching `<base_prefix>_<W>x<H>.png` without glob metacharacter pitfalls.
--- @param base_prefix string
--- @return string[]
local function list_dimension_pngs(base_prefix)
	local dir = vim.fs.dirname(base_prefix)
	local prefix_name = vim.fs.basename(base_prefix) .. "_"
	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return {}
	end

	local matches = {}
	while true do
		local name, ftype = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if
			(ftype == "file" or ftype == nil)
			and name:sub(1, #prefix_name) == prefix_name
			and name:match("_(%d+)x(%d+)%.png$")
		then
			table.insert(matches, dir .. "/" .. name)
		end
	end
	table.sort(matches)
	return matches
end

--- Builds deterministic paths and templates for a diagram and theme.
--- Truncates `safe_name` to 64 chars to prevent `ENAMETOOLONG` and mixes schema version,
--- theme, scale, and optional `style_hash` into the digest for automatic cache invalidation.
--- @param diagram MermaidDiagramEntry
--- @param theme "light"|"dark"
--- @param opts { scale?: integer, style_hash?: string }|nil
--- @return { cache_key: string, base_prefix: string, mmd_path: string, png_path: string, png_template: string, puppeteer_cfg: string, mermaid_cfg: string }
function M.resolve_paths(diagram, theme, opts)
	opts = opts or {}
	M.ensure_dir()
	local digest_input = vim.json.encode({
		CACHE_SCHEMA_VERSION,
		theme or "light",
		tostring(opts.scale or ""),
		tostring(opts.style_hash or ""),
		diagram.code or "",
	})
	local hash = vim.fn.sha256(digest_input):sub(1, 16)
	local safe_name = (diagram.name or "diagram"):gsub("[^%w_%-]", "_"):sub(1, MAX_SAFE_NAME_LEN)
	if safe_name == "" then
		safe_name = "diagram"
	end
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

--- Deletes stale cached PNG/MMD artifacts for `paths` before a forced recompilation.
--- @param paths table Result of `M.resolve_paths`
function M.invalidate(paths)
	if not paths or not paths.base_prefix then
		return
	end
	for _, png in ipairs(list_dimension_pngs(paths.base_prefix)) do
		pcall(vim.uv.fs_unlink, png)
	end
	if paths.png_path and vim.fn.filereadable(paths.png_path) == 1 then
		pcall(vim.uv.fs_unlink, paths.png_path)
	end
	if paths.mmd_path and vim.fn.filereadable(paths.mmd_path) == 1 then
		pcall(vim.uv.fs_unlink, paths.mmd_path)
	end
end

--- Searches for an existing cached overview PNG (`_<svg_w>x<svg_h>.png` or legacy `.png`)
--- and returns its path, logical SVG dimensions, and physical raster dimensions.
--- @param paths table Result of `M.resolve_paths`
--- @return { png_path: string, svg_w: integer, svg_h: integer, raster_w: integer, raster_h: integer }|nil
function M.find_cached_overview(paths)
	local matches = list_dimension_pngs(paths.base_prefix)
	if #matches > 0 then
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

--- Evicts oldest cached diagram artifacts (`.png`/`.mmd`) by `mtime` (LRU) whenever
--- total file count exceeds `max_files` or total size exceeds `max_bytes`.
--- @param max_files integer|nil Defaults to 100
--- @param max_bytes integer|nil Defaults to 100 MB
--- @param target_dir string|nil Optional directory override for isolated testing
--- @return integer removed_files, integer removed_bytes
function M.prune(max_files, max_bytes, target_dir)
	max_files = max_files or DEFAULT_MAX_FILES
	max_bytes = max_bytes or DEFAULT_MAX_BYTES
	local dir = target_dir or cache_dir

	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return 0, 0
	end

	local entries = {}
	local total_bytes = 0
	while true do
		local name, ftype = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if (ftype == "file" or ftype == nil) and (name:match("%.png$") or name:match("%.mmd$")) then
			local full = dir .. "/" .. name
			local st = vim.uv.fs_stat(full)
			if st and st.type == "file" then
				local mtime_ns = (st.mtime and st.mtime.sec or 0) * 1e9 + (st.mtime and st.mtime.nsec or 0)
				table.insert(entries, {
					path = full,
					size = st.size or 0,
					mtime = mtime_ns,
				})
				total_bytes = total_bytes + (st.size or 0)
			end
		end
	end

	if #entries <= max_files and total_bytes <= max_bytes then
		return 0, 0
	end

	table.sort(entries, function(a, b)
		if a.mtime ~= b.mtime then
			return a.mtime < b.mtime
		end
		return a.path < b.path
	end)

	local remaining = #entries
	local removed_files = 0
	local removed_bytes = 0
	for _, entry in ipairs(entries) do
		if remaining <= max_files and total_bytes <= max_bytes then
			break
		end
		if pcall(vim.uv.fs_unlink, entry.path) then
			remaining = remaining - 1
			total_bytes = math.max(0, total_bytes - entry.size)
			removed_files = removed_files + 1
			removed_bytes = removed_bytes + entry.size
		end
	end

	return removed_files, removed_bytes
end

--- Removes all cached `.png`, `.mmd`, and `.json` files in the plugin cache directory
--- along with rotary viewport tiles for the current session.
--- @param target_dir string|nil Optional directory override for isolated testing
--- @return integer removed_files
function M.clear_all(target_dir)
	local dir = target_dir or cache_dir
	local removed = 0
	local handle = vim.uv.fs_scandir(dir)
	if handle then
		while true do
			local name, ftype = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if
				(ftype == "file" or ftype == nil)
				and (name:match("%.png$") or name:match("%.mmd$") or name:match("%.json$"))
			then
				if pcall(vim.uv.fs_unlink, dir .. "/" .. name) then
					removed = removed + 1
				end
			end
		end
	end
	if not target_dir then
		M.cleanup_viewport_tiles()
	end
	return removed
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
