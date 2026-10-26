--- @module mermaid_lens.env.terminal
--- Architectural Layer: Infrastructure
--- Parent: `mermaid_lens.renderer.compiler`, `mermaid_lens.ui.modal`,
---         `mermaid_lens.ui.loader`, and `mermaid_lens.health`
--- Children: `mermaid_lens.env.multiplexer`, `mermaid_lens.config.constants`
--- Single Responsibility: Detect terminal graphics protocol support and query
--- real console cell/pixel dimensions via POSIX `ioctl(TIOCGWINSZ)`.

local constants = require("mermaid_lens.config.constants")
local multiplexer = require("mermaid_lens.env.multiplexer")

local M = {}

--- @class ConsoleMetrics
--- @field ui_cols integer Neovim UI width in character cells
--- @field ui_rows integer Neovim UI height in character cells
--- @field tmux_top integer Top row offset introduced by TMUX
--- @field tmux_left integer Left column offset introduced by TMUX
--- @field cell_w number Physical width of a single terminal cell in pixels
--- @field cell_h number Physical height of a single terminal cell in pixels
--- @field screen_px_w integer Total physical width of the Neovim UI in pixels
--- @field screen_px_h integer Total physical height of the Neovim UI in pixels

--- Determines whether the host terminal supports the Kitty graphics protocol.
--- Checks environment variables across Kitty, Ghostty, and WezTerm.
--- @return boolean
function M.supports_kitty_graphics()
	if os.getenv("KITTY_WINDOW_ID") ~= nil then
		return true
	end
	local term = (os.getenv("TERM") or ""):lower()
	local term_program = (os.getenv("TERM_PROGRAM") or ""):lower()

	return term:find("kitty", 1, true) ~= nil
		or term:find("ghostty", 1, true) ~= nil
		or term_program:find("ghostty", 1, true) ~= nil
		or term_program:find("wezterm", 1, true) ~= nil
end

--- Queries the host terminal's physical pixel dimensions per character cell using LuaJIT FFI.
--- When running inside TMUX, queries the underlying `client_tty` device directly because
--- the pseudo-terminal attached to Neovim inside TMUX may report `0` for `ws_xpixel`.
--- @param client_tty string|nil Optional TTY device path from TMUX
--- @return number cell_w, number cell_h
local function query_cell_pixel_dimensions(client_tty)
	local cell_w = constants.LIMITS.FALLBACK_CELL_WIDTH_PX
	local cell_h = constants.LIMITS.FALLBACK_CELL_HEIGHT_PX

	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi then
		return cell_w, cell_h
	end

	pcall(function()
		ffi.cdef([[
      struct ml_winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
      };
      int ioctl(int fd, unsigned long request, ...);
      int open(const char *pathname, int flags);
      int close(int fd);
    ]])
	end)

	local ws = ffi.new("struct ml_winsize")
	local TIOCGWINSZ = vim.fn.has("mac") == 1 and 0x40087468 or 0x5413
	local fd = 2
	local opened_fd = nil

	if client_tty and client_tty ~= "" then
		local c_fd = ffi.C.open(client_tty, 0)
		if c_fd >= 0 then
			fd = c_fd
			opened_fd = c_fd
		end
	end

	if ffi.C.ioctl(fd, TIOCGWINSZ, ws) == 0 then
		if ws.ws_col > 0 and ws.ws_row > 0 and ws.ws_xpixel > 0 and ws.ws_ypixel > 0 then
			cell_w = ws.ws_xpixel / ws.ws_col
			cell_h = ws.ws_ypixel / ws.ws_row
		end
	end

	if opened_fd then
		ffi.C.close(opened_fd)
	end

	return cell_w, cell_h
end

--- Collects real-time console metrics combining Neovim UI dimensions, TMUX pane
--- offsets, and physical cell pixel sizes.
--- @return ConsoleMetrics
function M.get_console_metrics()
	local pane = multiplexer.get_pane_geometry()
	local cell_w, cell_h = query_cell_pixel_dimensions(pane.client_tty)
	local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }

	return {
		ui_cols = ui.width,
		ui_rows = ui.height,
		tmux_top = pane.top,
		tmux_left = pane.left,
		cell_w = cell_w,
		cell_h = cell_h,
		screen_px_w = math.floor(ui.width * cell_w),
		screen_px_h = math.floor(ui.height * cell_h),
	}
end

return M
