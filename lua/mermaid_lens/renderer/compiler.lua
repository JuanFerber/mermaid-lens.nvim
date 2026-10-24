--- @module mermaid_lens.renderer.compiler
--- Architectural Layer: Infrastructure / Application Service
--- Parent: `mermaid_lens.init`, `mermaid_lens.ui.modal`, `mermaid_lens.ui.picker`
--- Children: `mermaid_lens.env.terminal`, `mermaid_lens.config.themes`,
---           `mermaid_lens.renderer.cache`, `mermaid_lens.renderer.ascii`, `mermaid_lens.ui.loader`
--- Single Responsibility: Compile Mermaid source code into high-resolution PNG
--- textures using `mmdc` asynchronously while managing cache hits and progress UI.

local terminal = require("mermaid_lens.env.terminal")
local themes = require("mermaid_lens.config.themes")
local cache = require("mermaid_lens.renderer.cache")
local ascii = require("mermaid_lens.renderer.ascii")
local loader = require("mermaid_lens.ui.loader")

local M = {}

--- @class RenderedDiagramArtifact
--- @field name string
--- @field mode "kitty"
--- @field theme "light"|"dark"
--- @field png_path string
--- @field img_w integer
--- @field img_h integer
--- @field code string
--- @field filepath string
--- @field lnum integer

--- Writes the Puppeteer and Mermaid JSON configuration files tailored to the current console size.
--- @param paths table
--- @param theme "light"|"dark"
local function write_compiler_configs(paths, theme)
	local metrics = terminal.get_console_metrics()

	local pf = io.open(paths.puppeteer_cfg, "w")
	if pf then
		pf:write(vim.json.encode({
			args = { "--no-sandbox", "--disable-setuid-sandbox" },
			defaultViewport = {
				width = math.max(1280, metrics.screen_px_w),
				height = math.max(720, metrics.screen_px_h),
				deviceScaleFactor = 3,
			},
		}))
		pf:close()
	end

	local mf = io.open(paths.mermaid_cfg, "w")
	if mf then
		mf:write(vim.json.encode({
			theme = "base",
			look = "neo",
			maxTextSize = 1000000,
			themeVariables = themes.build_theme_variables(theme),
			themeCSS = themes.build_theme_css(theme),
			flowchart = { useMaxWidth = false },
			er = { useMaxWidth = false },
			sequence = { useMaxWidth = false },
			class = { useMaxWidth = false },
			state = { useMaxWidth = false },
			gantt = { useMaxWidth = false },
			c4 = { useMaxWidth = false },
		}))
		mf:close()
	end
end

--- Compiles a Mermaid diagram into a cached PNG artifact and invokes `callback`.
--- Preconditions: Requires a Kitty-capable terminal and `mmdc` in `$PATH`.
--- Side effects: Spawns `mmdc` subprocess, writes cache files, and displays the progress loader.
--- @param diagram MermaidDiagramEntry
--- @param opts { theme?: "light"|"dark", force_ascii?: boolean, modal_box?: table }
--- @param callback fun(artifact: RenderedDiagramArtifact)
function M.compile(diagram, opts, callback)
	opts = opts or {}

	if opts.force_ascii then
		ascii.notify_coming_soon()
		return
	end

	if not terminal.supports_kitty_graphics() then
		vim.notify(
			"MermaidLens: Terminal does not support the Kitty graphics protocol (ASCII mode coming soon).",
			vim.log.levels.WARN
		)
		return
	end

	if vim.fn.executable("mmdc") == 0 then
		vim.notify("MermaidLens: '@mermaid-js/mermaid-cli' (mmdc) is not installed in PATH.", vim.log.levels.ERROR)
		return
	end

	local theme = opts.theme or "light"
	local palette = themes.get_palette(theme)
	local paths = cache.resolve_paths(diagram, theme)

	-- Fast path: serve directly from disk cache in 0ms without opening loader
	if vim.fn.filereadable(paths.png_path) == 1 then
		local w, h = cache.read_png_dimensions(paths.png_path)
		if w and h then
			local entry = {
				name = diagram.name,
				mode = "kitty",
				theme = theme,
				png_path = paths.png_path,
				img_w = w,
				img_h = h,
				code = diagram.code,
				filepath = diagram.filepath,
				lnum = diagram.lnum,
				updated_at = os.time(),
			}
			cache.save_entry(entry)
			callback(entry)
			return
		end
	end

	local f = io.open(paths.mmd_path, "w")
	if f then
		f:write(diagram.code)
		f:close()
	end

	write_compiler_configs(paths, theme)
	loader.start(diagram.name, theme, opts.modal_box)

	local function run_mmdc(args, on_done)
		vim.system(args, { text = true }, function(res)
			vim.schedule(function()
				on_done(res)
			end)
		end)
	end

	local primary_args = {
		"mmdc",
		"-p",
		paths.puppeteer_cfg,
		"-c",
		paths.mermaid_cfg,
		"-i",
		paths.mmd_path,
		"-o",
		paths.png_path,
		"-b",
		palette.bg,
	}

	run_mmdc(primary_args, function(res)
		local function finalize()
			loader.stop(function()
				local w, h = cache.read_png_dimensions(paths.png_path)
				if not w or not h then
					vim.notify("MermaidLens: Failed to read compiled PNG dimensions.", vim.log.levels.ERROR)
					return
				end
				local entry = {
					name = diagram.name,
					mode = "kitty",
					theme = theme,
					png_path = paths.png_path,
					img_w = w,
					img_h = h,
					code = diagram.code,
					filepath = diagram.filepath,
					lnum = diagram.lnum,
					updated_at = os.time(),
				}
				cache.save_entry(entry)
				callback(entry)
			end)
		end

		if res.code == 0 and vim.fn.filereadable(paths.png_path) == 1 then
			finalize()
			return
		end

		-- Fallback invocation without custom Puppeteer flags for wrapper binaries
		run_mmdc({ "mmdc", "-i", paths.mmd_path, "-o", paths.png_path, "-b", palette.bg }, function(res2)
			if res2.code == 0 and vim.fn.filereadable(paths.png_path) == 1 then
				finalize()
			else
				loader.stop(function()
					local err_msg = (res2.stderr or res.stderr or ""):match("([^\r\n]+)") or "mmdc execution error"
					vim.notify("MermaidLens: Failed to compile diagram (" .. err_msg .. ").", vim.log.levels.ERROR)
				end)
			end
		end)
	end)
end

return M
