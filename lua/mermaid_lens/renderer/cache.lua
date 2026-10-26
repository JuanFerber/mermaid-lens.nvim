--- @module mermaid_lens.renderer.cache
--- Architectural Layer: Infrastructure / Repository
--- Parent: `mermaid_lens.renderer.compiler`
--- Children: None (Leaf module).
--- Single Responsibility: Manage deterministic cache file paths and read PNG
--- binary dimensions directly from big-endian IHDR headers.

local M = {}

local cache_dir = vim.fn.stdpath("cache") .. "/mermaid_lens"

--- Ensures the plugin cache directory exists on disk.
--- @return string cache_dir
function M.ensure_dir()
	if vim.fn.isdirectory(cache_dir) == 0 then
		vim.fn.mkdir(cache_dir, "p")
	end
	return cache_dir
end

--- Builds deterministic paths for the `.mmd` source and `.png` output based on content hash and theme.
--- @param diagram MermaidDiagramEntry
--- @param theme "light"|"dark"
--- @return { mmd_path: string, png_path: string, puppeteer_cfg: string, mermaid_cfg: string }
function M.resolve_paths(diagram, theme)
	M.ensure_dir()
	local hash = vim.fn.sha256(diagram.code):sub(1, 16)
	local safe_name = (diagram.name or "diagram"):gsub("[^%w_%-]", "_")
	local base = string.format("%s/%s_%s_%s", cache_dir, theme, safe_name, hash)

	return {
		mmd_path = base .. ".mmd",
		png_path = base .. ".png",
		puppeteer_cfg = cache_dir .. "/puppeteer-config.json",
		mermaid_cfg = string.format("%s/mermaid-config-%s.json", cache_dir, theme),
	}
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
