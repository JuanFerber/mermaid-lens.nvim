local T = _G.TestHarness
local cache = require("mermaid_lens.renderer.cache")

local function make_png_header(w, h)
	local function u32_be(n)
		local b1 = math.floor(n / 16777216) % 256
		local b2 = math.floor(n / 65536) % 256
		local b3 = math.floor(n / 256) % 256
		local b4 = n % 256
		return string.char(b1, b2, b3, b4)
	end
	return "\137PNG\r\n\026\n" .. "\0\0\0\13IHDR" .. u32_be(w) .. u32_be(h)
end

T.test("cache.ensure_dir and get_viewport_tile_path enforce private 0700 directories", function()
	local cdir = cache.ensure_dir()
	local tile_path = cache.get_viewport_tile_path(0)
	local tile_dir = vim.fs.dirname(tile_path)

	-- Tiles must never be written directly into shared /dev/shm root
	T.assert_true(tile_dir ~= "/dev/shm", "Viewport tiles must reside inside a private subdirectory, not /dev/shm")

	if vim.fn.has("win32") == 0 and vim.fn.has("win64") == 0 then
		local cst = vim.uv.fs_stat(cdir)
		local tst = vim.uv.fs_stat(tile_dir)
		T.assert_eq(bit.band(cst.mode, tonumber("777", 8)), tonumber("700", 8))
		T.assert_eq(bit.band(tst.mode, tonumber("777", 8)), tonumber("700", 8))
	end
end)

T.test("cache.resolve_paths truncates long names and varies digest on scale and style_hash", function()
	local long_name = string.rep("diagram_name_", 25)
	local d = { name = long_name, code = "flowchart TD\n  A --> B" }

	local p1 = cache.resolve_paths(d, "light", { scale = 2, style_hash = "aaaa1111" })
	local p2 = cache.resolve_paths(d, "light", { scale = 3, style_hash = "aaaa1111" })
	local p3 = cache.resolve_paths(d, "light", { scale = 2, style_hash = "bbbb2222" })
	-- Embedded NUL bytes must not trigger Neovim 0.10 E976 Blob errors in vim.fn.sha256
	local p_nul = cache.resolve_paths({ name = "nul_test", code = "flowchart TD\n  A --> B\0C" }, "light")

	T.assert_true(#vim.fs.basename(p1.png_path) <= 120, "Truncated cache filename must remain short")
	T.assert_true(p1.cache_key ~= p2.cache_key, "Different scale must yield distinct cache_key")
	T.assert_true(p1.cache_key ~= p3.cache_key, "Different style_hash must yield distinct cache_key")
	T.assert_true(type(p_nul.cache_key) == "string" and #p_nul.cache_key > 0)
end)

T.test("cache.prune evicts oldest png/mmd files by mtime while preserving json configs", function()
	local dir = string.format("/tmp/mlens_cache_prune_%d", vim.fn.getpid())
	vim.fn.delete(dir, "rf")
	vim.fn.mkdir(dir, "p")

	local ok, err = pcall(function()
		local files = {
			{ name = "a_old.png", mtime = 1000, size = 500 },
			{ name = "b_old.mmd", mtime = 2000, size = 500 },
			{ name = "c_mid.png", mtime = 3000, size = 500 },
			{ name = "d_new.png", mtime = 4000, size = 500 },
			{ name = "mermaid-config-light.json", mtime = 500, size = 500 },
		}

		for _, item in ipairs(files) do
			local full = dir .. "/" .. item.name
			local f = assert(io.open(full, "wb"))
			f:write(string.rep("a", item.size))
			f:close()
			vim.uv.fs_utime(full, item.mtime, item.mtime)
		end

		local removed_files, removed_bytes = cache.prune(2, 100000, dir)

		T.assert_eq(removed_files, 2)
		T.assert_eq(removed_bytes, 1000)
		T.assert_eq(vim.fn.filereadable(dir .. "/a_old.png"), 0)
		T.assert_eq(vim.fn.filereadable(dir .. "/b_old.mmd"), 0)
		T.assert_eq(vim.fn.filereadable(dir .. "/c_mid.png"), 1)
		T.assert_eq(vim.fn.filereadable(dir .. "/d_new.png"), 1)
		T.assert_eq(vim.fn.filereadable(dir .. "/mermaid-config-light.json"), 1)
	end)

	vim.fn.delete(dir, "rf")
	if not ok then
		error(err, 0)
	end
end)

T.test("cache.clear_all removes png, mmd, and json files while leaving unrelated files intact", function()
	local dir = string.format("/tmp/mlens_cache_clear_%d", vim.fn.getpid())
	vim.fn.delete(dir, "rf")
	vim.fn.mkdir(dir, "p")

	local ok, err = pcall(function()
		vim.fn.writefile({ "x" }, dir .. "/one.png")
		vim.fn.writefile({ "x" }, dir .. "/two.mmd")
		vim.fn.writefile({ "{}" }, dir .. "/cfg.json")
		vim.fn.writefile({ "keep" }, dir .. "/notes.txt")

		local removed = cache.clear_all(dir)

		T.assert_eq(removed, 3)
		T.assert_eq(vim.fn.filereadable(dir .. "/one.png"), 0)
		T.assert_eq(vim.fn.filereadable(dir .. "/two.mmd"), 0)
		T.assert_eq(vim.fn.filereadable(dir .. "/cfg.json"), 0)
		T.assert_eq(vim.fn.filereadable(dir .. "/notes.txt"), 1)
	end)

	vim.fn.delete(dir, "rf")
	if not ok then
		error(err, 0)
	end
end)

T.test("cache.read_png_dimensions parses big-endian IHDR width and height", function()
	local path = string.format("/tmp/mlens_ihdr_%d.png", vim.fn.getpid())
	local f = assert(io.open(path, "wb"))
	f:write(make_png_header(1234, 567))
	f:close()

	local w, h = cache.read_png_dimensions(path)
	vim.fn.delete(path)

	T.assert_eq(w, 1234)
	T.assert_eq(h, 567)
end)
