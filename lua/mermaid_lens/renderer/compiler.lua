--- @module mermaid_lens.renderer.compiler
--- Architectural Layer: Infrastructure / Application Service
--- Parent: `mermaid_lens.init`, `mermaid_lens.ui.modal`, and `mermaid_lens.ui.picker`
--- Children: `mermaid_lens.config.constants`, `mermaid_lens.env.terminal`,
---           `mermaid_lens.config.themes`, `mermaid_lens.renderer.cache`,
---           `mermaid_lens.renderer.bridge_client`, `mermaid_lens.renderer.diagnostics`,
---           `mermaid_lens.renderer.ascii`, `mermaid_lens.ui.loader`
--- Single Responsibility: Compile Mermaid source into vector-backed PNG artifacts via
--- the warm SVG bridge (with automatic `mmdc` fallback) and rasterize dynamic viewBoxes on demand.

local constants = require("mermaid_lens.config.constants")
local terminal = require("mermaid_lens.env.terminal")
local themes = require("mermaid_lens.config.themes")
local cache = require("mermaid_lens.renderer.cache")
local bridge_client = require("mermaid_lens.renderer.bridge_client")
local diagnostics = require("mermaid_lens.renderer.diagnostics")
local ascii = require("mermaid_lens.renderer.ascii")
local loader = require("mermaid_lens.ui.loader")

local M = {}

local active_job = nil
local raster_seq = 0
local tile_slot = 0

--- @class RenderedDiagramArtifact
--- @field name string
--- @field mode "kitty"|"code"
--- @field theme "light"|"dark"
--- @field png_path string|nil
--- @field img_w integer|nil Logical vector width
--- @field img_h integer|nil Logical vector height
--- @field raster_w integer|nil Physical pixel width of the overview PNG
--- @field raster_h integer|nil Physical pixel height of the overview PNG
--- @field code string
--- @field filepath string
--- @field lnum integer
--- @field error MermaidSyntaxError|nil
--- @field error_severity integer|nil

local function write_file(filepath, content)
	local f = io.open(filepath, "w")
	if f then
		f:write(content)
		f:close()
	end
end

local function build_mermaid_config_table(theme)
	local c_lim = constants.COMPILER
	return {
		theme = "base",
		look = "neo",
		maxTextSize = c_lim.MAX_TEXT_SIZE,
		themeVariables = themes.build_theme_variables(theme),
		themeCSS = themes.build_theme_css(theme),
		flowchart = { useMaxWidth = false },
		er = { useMaxWidth = false },
		sequence = { useMaxWidth = false },
		class = { useMaxWidth = false },
		state = { useMaxWidth = false },
		gantt = { useMaxWidth = false },
		c4 = { useMaxWidth = false },
	}
end

local function write_compiler_configs(paths, theme, scale)
	local metrics = terminal.get_console_metrics()
	local c_lim = constants.COMPILER

	write_file(
		paths.puppeteer_cfg,
		vim.json.encode({
			args = { "--no-sandbox", "--disable-setuid-sandbox" },
			defaultViewport = {
				width = math.max(c_lim.MIN_VIEWPORT_WIDTH_PX, metrics.screen_px_w),
				height = math.max(c_lim.MIN_VIEWPORT_HEIGHT_PX, metrics.screen_px_h),
				deviceScaleFactor = math.max(c_lim.MIN_SCALE, math.min(c_lim.MAX_SCALE, scale or c_lim.DEFAULT_SCALE)),
			},
		})
	)

	write_file(paths.mermaid_cfg, vim.json.encode(build_mermaid_config_table(theme)))
end

local function build_fallback_artifact(diagram, theme, message, line, severity)
	return {
		name = diagram.name,
		mode = "code",
		theme = theme,
		code = diagram.code,
		filepath = diagram.filepath,
		lnum = diagram.lnum,
		error = {
			line = line or 1,
			message = message,
			raw = message,
		},
		error_severity = severity or vim.diagnostic.severity.WARN,
	}
end

--- Batch CLI fallback using `mmdc` when the warm Node bridge is unavailable.
local function compile_with_mmdc_batch(diagram, paths, theme, opts, callback)
	if active_job then
		pcall(function()
			active_job:kill(9)
		end)
		active_job = nil
	end

	local palette = themes.get_palette(theme)
	write_file(paths.mmd_path, diagram.code)
	write_compiler_configs(paths, theme, opts.scale)

	local function run_mmdc(args, on_done)
		active_job = vim.system(args, { text = true }, function(res)
			vim.schedule(function()
				active_job = nil
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
		local function finalize_success()
			loader.stop(function()
				local w, h = cache.read_png_dimensions(paths.png_path)
				if not w or not h then
					callback(
						build_fallback_artifact(
							diagram,
							theme,
							"Failed to read compiled PNG header dimensions.",
							1,
							vim.diagnostic.severity.ERROR
						)
					)
					return
				end
				callback({
					name = diagram.name,
					mode = "kitty",
					theme = theme,
					png_path = paths.png_path,
					img_w = w,
					img_h = h,
					raster_w = w,
					raster_h = h,
					code = diagram.code,
					filepath = diagram.filepath,
					lnum = diagram.lnum,
				})
			end)
		end

		if res.code == 0 and vim.fn.filereadable(paths.png_path) == 1 then
			finalize_success()
			return
		end

		local fallback_args = {
			"mmdc",
			"-c",
			paths.mermaid_cfg,
			"-i",
			paths.mmd_path,
			"-o",
			paths.png_path,
			"-b",
			palette.bg,
		}

		run_mmdc(fallback_args, function(res2)
			if res2.code == 0 and vim.fn.filereadable(paths.png_path) == 1 then
				finalize_success()
			else
				loader.stop(function()
					local raw_err = (res2.stderr and res2.stderr ~= "" and res2.stderr)
						or (res.stderr and res.stderr ~= "" and res.stderr)
						or res2.stdout
						or "Mermaid syntax error"
					local parsed_err = diagnostics.parse_stderr(raw_err)

					vim.notify(
						string.format(
							"MermaidLens: Syntax error on line %d — %s",
							parsed_err.line,
							parsed_err.message
						),
						vim.log.levels.ERROR
					)

					callback({
						name = diagram.name,
						mode = "code",
						theme = theme,
						code = diagram.code,
						filepath = diagram.filepath,
						lnum = diagram.lnum,
						error = parsed_err,
						error_severity = vim.diagnostic.severity.ERROR,
					})
				end)
			end
		end)
	end)
end

--- Compiles a Mermaid diagram into a cached PNG artifact or returns a Code Mode fallback artifact.
--- @param diagram MermaidDiagramEntry
--- @param opts { theme?: "light"|"dark", scale?: integer, force_ascii?: boolean, force_recompile?: boolean, fallback_to_code?: boolean, modal_box?: table }
--- @param callback fun(artifact: RenderedDiagramArtifact)
function M.compile(diagram, opts, callback)
	opts = opts or {}
	local theme = opts.theme or "light"
	local fallback_to_code = opts.fallback_to_code ~= false

	if opts.force_ascii then
		ascii.notify_coming_soon()
		if fallback_to_code then
			callback(
				build_fallback_artifact(
					diagram,
					theme,
					"ASCII mode is coming soon — opened in interactive Code Mode.",
					1,
					vim.diagnostic.severity.INFO
				)
			)
		end
		return
	end

	if not terminal.supports_kitty_graphics() then
		local msg = "Terminal does not support Kitty graphics protocol — opened in Code Mode."
		if fallback_to_code then
			callback(build_fallback_artifact(diagram, theme, msg, 1, vim.diagnostic.severity.WARN))
		else
			vim.notify("MermaidLens: " .. msg, vim.log.levels.WARN)
		end
		return
	end

	if vim.fn.executable("mmdc") == 0 then
		local msg = "'mmdc' (@mermaid-js/mermaid-cli) is not installed in PATH — opened in Code Mode."
		if fallback_to_code then
			callback(build_fallback_artifact(diagram, theme, msg, 1, vim.diagnostic.severity.WARN))
		else
			vim.notify("MermaidLens: " .. msg, vim.log.levels.ERROR)
		end
		return
	end

	local paths = cache.resolve_paths(diagram, theme)

	if not opts.force_recompile then
		local hit = cache.find_cached_overview(paths)
		if hit then
			callback({
				name = diagram.name,
				mode = "kitty",
				theme = theme,
				png_path = hit.png_path,
				img_w = hit.svg_w,
				img_h = hit.svg_h,
				raster_w = hit.raster_w,
				raster_h = hit.raster_h,
				code = diagram.code,
				filepath = diagram.filepath,
				lnum = diagram.lnum,
			})
			return
		end
	end

	loader.start(diagram.name, theme, opts.modal_box)

	if bridge_client.is_available() then
		local metrics = terminal.get_console_metrics()
		local palette = themes.get_palette(theme)
		bridge_client.request({
			action = "compile_svg",
			cache_key = paths.cache_key,
			code = diagram.code,
			bg = palette.bg,
			mermaid_config = build_mermaid_config_table(theme),
			out_path_template = paths.png_template,
			raster_w = math.max(800, metrics.screen_px_w),
			raster_h = math.max(600, metrics.screen_px_h),
		}, function(res)
			if res.status == "ok" and res.png_path and vim.fn.filereadable(res.png_path) == 1 then
				local rw, rh = cache.read_png_dimensions(res.png_path)
				local svg_w = tonumber(res.svg_w) or rw or 800
				local svg_h = tonumber(res.svg_h) or rh or 600
				loader.stop(function()
					callback({
						name = diagram.name,
						mode = "kitty",
						theme = theme,
						png_path = res.png_path,
						img_w = svg_w,
						img_h = svg_h,
						raster_w = rw or svg_w,
						raster_h = rh or svg_h,
						code = diagram.code,
						filepath = diagram.filepath,
						lnum = diagram.lnum,
					})
				end)
				return
			end

			-- Any non-syntax failure (browser launch, missing libs, timeout, crash) falls back to mmdc CLI
			if res.error_type ~= "syntax" then
				bridge_client.mark_failed()
				compile_with_mmdc_batch(diagram, paths, theme, opts, callback)
				return
			end

			loader.stop(function()
				local parsed_err = diagnostics.parse_stderr(res.error or "Mermaid syntax error")
				vim.notify(
					string.format("MermaidLens: Syntax error on line %d — %s", parsed_err.line, parsed_err.message),
					vim.log.levels.ERROR
				)
				callback({
					name = diagram.name,
					mode = "code",
					theme = theme,
					code = diagram.code,
					filepath = diagram.filepath,
					lnum = diagram.lnum,
					error = parsed_err,
					error_severity = vim.diagnostic.severity.ERROR,
				})
			end)
		end)
		return
	end

	compile_with_mmdc_batch(diagram, paths, theme, opts, callback)
end

--- Rasterizes a specific vector `viewBox` rectangle `(crop.x, crop.y, crop.w, crop.h)`
--- into a modal-sized PNG tile in RAM (`/dev/shm`). If the diagram was loaded from disk cache,
--- `bridge.js` hydrates the SVG in-memory first without touching the cached overview PNG on disk.
--- @param diagram MermaidDiagramEntry
--- @param opts { theme: "light"|"dark", crop: { x: number, y: number, w: number, h: number }, raster_w: integer, raster_h: integer }
--- @param callback fun(tile: { png_path: string, raster_w: integer, raster_h: integer, crop: table }|nil)
function M.raster_viewbox(diagram, opts, callback)
	if not bridge_client.is_available() then
		callback(nil)
		return
	end

	raster_seq = raster_seq + 1
	local my_seq = raster_seq
	local theme = opts.theme or "light"
	local paths = cache.resolve_paths(diagram, theme)
	local palette = themes.get_palette(theme)

	tile_slot = (tile_slot + 1) % 2
	local out_path = cache.get_viewport_tile_path(tile_slot)

	bridge_client.request({
		action = "raster_viewbox",
		cache_key = paths.cache_key,
		code = diagram.code,
		bg = palette.bg,
		mermaid_config = build_mermaid_config_table(theme),
		out_path = out_path,
		crop = opts.crop,
		raster_w = opts.raster_w,
		raster_h = opts.raster_h,
	}, function(res)
		if my_seq ~= raster_seq then
			return
		end
		if res.status == "ok" and vim.fn.filereadable(out_path) == 1 then
			callback({
				png_path = out_path,
				raster_w = tonumber(res.raster_w) or opts.raster_w,
				raster_h = tonumber(res.raster_h) or opts.raster_h,
				crop = opts.crop,
			})
		else
			if res.error_type == "bridge_fatal" then
				bridge_client.mark_failed()
			end
			callback(nil)
		end
	end)
end

return M
