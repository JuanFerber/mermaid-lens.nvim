--- @module mermaid_lens.health
--- Architectural Layer: Infrastructure / Diagnostics
--- Parent: Invoked directly by Neovim's `:checkhealth mermaid_lens` runner.
--- Children: `mermaid_lens.env.terminal`, `mermaid_lens.env.multiplexer`
--- Single Responsibility: Audit runtime requirements, terminal graphics protocol
--- capabilities, TMUX passthrough settings, and external CLI dependencies.

local terminal = require("mermaid_lens.env.terminal")
local multiplexer = require("mermaid_lens.env.multiplexer")

local M = {}

local start = vim.health.start or vim.health.report_start
local ok = vim.health.ok or vim.health.report_ok
local warn = vim.health.warn or vim.health.report_warn
local error = vim.health.error or vim.health.report_error
local info = vim.health.info or vim.health.report_info

local function check_neovim_runtime()
	start("Neovim & LuaJIT Runtime")

	if vim.fn.has("nvim-0.10.0") == 1 then
		ok(string.format("Neovim >= 0.10.0 detected (%s)", tostring(vim.version())))
	else
		error("Neovim >= 0.10.0 is required for `vim.system` and floating window title chunks.")
	end

	local has_ffi, _ = pcall(require, "ffi")
	if has_ffi then
		ok("LuaJIT FFI is available for `ioctl(TIOCGWINSZ)` pixel geometry queries.")
	else
		warn("LuaJIT FFI is unavailable; falling back to default cell aspect ratio (10x20px).")
	end
end

local function check_terminal_graphics()
	start("Terminal Graphics Protocol")

	local term = os.getenv("TERM") or "unset"
	local term_prog = os.getenv("TERM_PROGRAM") or "unset"
	local kitty_win = os.getenv("KITTY_WINDOW_ID") or "unset"
	info(string.format("Environment: TERM=%s, TERM_PROGRAM=%s, KITTY_WINDOW_ID=%s", term, term_prog, kitty_win))

	if terminal.supports_kitty_graphics() then
		ok("Host terminal supports the Kitty graphics protocol.")
	else
		error(
			"Host terminal does not appear to support the Kitty graphics protocol.",
			{ "Use Kitty, Ghostty, or WezTerm to render high-resolution diagrams." }
		)
	end

	local metrics = terminal.get_console_metrics()
	info(
		string.format(
			"Console geometry: %dx%d cells | Cell size: %.1fx%.1f px | Screen: %dx%d px",
			metrics.ui_cols,
			metrics.ui_rows,
			metrics.cell_w,
			metrics.cell_h,
			metrics.screen_px_w,
			metrics.screen_px_h
		)
	)
end

local function check_multiplexer()
	start("Terminal Multiplexer (TMUX)")

	if not multiplexer.is_tmux() then
		ok("Running directly in host terminal (no TMUX layer detected).")
		return
	end

	info("TMUX session detected ($TMUX is active).")

	local passthrough = vim.trim(vim.fn.system({ "tmux", "show", "-gv", "allow-passthrough" }) or "")
	if passthrough == "all" then
		ok("TMUX `allow-passthrough` is set to `all`.")
	elseif passthrough == "on" then
		warn(
			"TMUX `allow-passthrough` is `on` (recommended: `all` for clean image removal on tab switch).",
			{ "Add `set -g allow-passthrough all` to your `~/.tmux.conf`." }
		)
	else
		error("TMUX `allow-passthrough` is disabled.", { "Add `set -g allow-passthrough all` to your `~/.tmux.conf`." })
	end

	local focus = vim.trim(vim.fn.system({ "tmux", "show", "-gv", "focus-events" }) or "")
	if focus == "on" then
		ok("TMUX `focus-events` is `on`.")
	else
		warn(
			"TMUX `focus-events` is disabled.",
			{ "Add `set -g focus-events on` to `~/.tmux.conf` so images hide when switching tabs." }
		)
	end
end

local function check_external_dependencies()
	start("External CLI & Plugin Dependencies")

	if vim.fn.executable("mmdc") == 1 then
		local ver = vim.trim(vim.fn.system({ "mmdc", "--version" }) or "unknown")
		ok(string.format("`mmdc` (@mermaid-js/mermaid-cli) found (version: %s).", ver))
	else
		error("`mmdc` executable not found in PATH.", { "Install via npm: `npm install -g @mermaid-js/mermaid-cli`" })
	end

	if vim.fn.executable("rg") == 1 then
		ok("`rg` (ripgrep) found for fast workspace diagram discovery.")
	else
		warn(
			"`rg` (ripgrep) not found; falling back to `vim.uv.fs_scandir`.",
			{ "Install `ripgrep` for faster scanning on large repositories." }
		)
	end

	local has_telescope, _ = pcall(require, "telescope")
	if has_telescope then
		ok("`telescope.nvim` is installed.")
	else
		warn(
			"`telescope.nvim` is not installed; `:MermaidLensTelescope` will be unavailable.",
			{ "Install `nvim-telescope/telescope.nvim` to enable workspace diagram search." }
		)
	end
end

--- Entry point invoked by Neovim's `:checkhealth mermaid_lens`.
function M.check()
	check_neovim_runtime()
	check_terminal_graphics()
	check_multiplexer()
	check_external_dependencies()
end

return M
