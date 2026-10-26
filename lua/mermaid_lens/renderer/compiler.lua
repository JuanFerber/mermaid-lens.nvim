--- @module mermaid_lens.renderer.compiler
--- Architectural Layer: Infrastructure / Application Service
--- Parent: `mermaid_lens.init`, `mermaid_lens.ui.modal`, and `mermaid_lens.ui.picker`
--- Children: `mermaid_lens.env.terminal`, `mermaid_lens.config.themes`,
---           `mermaid_lens.renderer.cache`, `mermaid_lens.renderer.diagnostics`,
---           `mermaid_lens.renderer.ascii`, `mermaid_lens.ui.loader`
--- Single Responsibility: Compile Mermaid source code into high-resolution PNG
--- textures using `mmdc` asynchronously, manage cache hits, and return structured
--- syntax diagnostics or code-fallback artifacts on failure.

local terminal = require("mermaid_lens.env.terminal")
local themes = require("mermaid_lens.config.themes")
local cache = require("mermaid_lens.renderer.cache")
local diagnostics = require("mermaid_lens.renderer.diagnostics")
local ascii = require("mermaid_lens.renderer.ascii")
local loader = require("mermaid_lens.ui.loader")

local M = {}

local active_job = nil

--- @class RenderedDiagramArtifact
--- @field name string
--- @field mode "kitty"|"code"
--- @field theme "light"|"dark"
--- @field png_path string|nil
--- @field img_w integer|nil
--- @field img_h integer|nil
--- @field code string
--- @field filepath string
--- @field lnum integer
--- @field error MermaidSyntaxError|nil
--- @field error_severity integer|nil

local function write_compiler_configs(paths, theme, scale)
	local metrics = terminal.get_console_metrics()

	local pf = io.open(paths.puppeteer_cfg, "w")
	if pf then
		pf:write(vim.json.encode({
			args = { "--no-sandbox", "--disable-setuid-sandbox" },
			defaultViewport = {
				width = math.max(1280, metrics.screen_px_w),
				height = math.max(720, metrics.screen_px_h),
				deviceScaleFactor = math.max(1, math.min(4, scale or 3)),
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

--- Compiles a Mermaid diagram into a cached PNG artifact or returns a Code Mode fallback artifact.
--- Cancels any in-flight `mmdc` process to prevent race conditions during rapid saves.
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

	local palette = themes.get_palette(theme)
	local paths = cache.resolve_paths(diagram, theme)

	-- Serve from disk cache in 0ms unless manual re-render was requested
	if not opts.force_recompile and vim.fn.filereadable(paths.png_path) == 1 then
		local w, h = cache.read_png_dimensions(paths.png_path)
		if w and h then
			callback({
				name = diagram.name,
				mode = "kitty",
				theme = theme,
				png_path = paths.png_path,
				img_w = w,
				img_h = h,
				code = diagram.code,
				filepath = diagram.filepath,
				lnum = diagram.lnum,
			})
			return
		end
	end

	-- Cancel previous in-flight compilation if still running
	if active_job then
		pcall(function()
			active_job:kill(9)
		end)
		active_job = nil
	end

	local f = io.open(paths.mmd_path, "w")
	if f then
		f:write(diagram.code)
		f:close()
	end

	write_compiler_configs(paths, theme, opts.scale)
	loader.start(diagram.name, theme, opts.modal_box)

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

		-- Secondary attempt without custom Puppeteer config in case `mmdc` is a wrapper script
		run_mmdc({ "mmdc", "-i", paths.mmd_path, "-o", paths.png_path, "-b", palette.bg }, function(res2)
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

return M
