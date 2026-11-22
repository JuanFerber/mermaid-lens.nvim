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

--- Resolves the platform-specific POSIX `TIOCGWINSZ` ioctl request code from `os_uname`.
--- Uses `0x40087468` on macOS/BSD and Linux PowerPC/MIPS/SPARC, and `0x5413` on Linux x86/ARM/RISC-V.
--- @param uname { sysname?: string, machine?: string }|nil
--- @return integer
function M.resolve_tiocgwinsz(uname)
	local info = uname or (vim.uv and vim.uv.os_uname and vim.uv.os_uname()) or {}
	local sys = (info.sysname or ""):lower()
	local arch = (info.machine or ""):lower()

	if sys:find("darwin", 1, true) or sys:find("bsd", 1, true) then
		return 0x40087468
	end
	if
		sys == "linux"
		and (arch:match("^ppc") or arch:match("^powerpc") or arch:match("^mips") or arch:match("^sparc"))
	then
		return 0x40087468
	end
	if sys == "" and vim.fn.has("mac") == 1 then
		return 0x40087468
	end
	return 0x5413
end

local ffi_state = {
	initialized = false,
	ffi = nil,
	ws = nil,
	ioctl_req = M.resolve_tiocgwinsz(),
}

--- Lazily initializes isolated LuaJIT FFI bindings and `ml_winsize` struct once per process.
--- Declares `struct ml_winsize` independently from `ioctl` so pre-existing declarations
--- from other Neovim plugins cannot break struct initialization.
--- @return table|nil ffi, userdata|nil ws
local function get_ffi_winsize()
	if ffi_state.initialized then
		return ffi_state.ffi, ffi_state.ws
	end
	ffi_state.initialized = true

	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi then
		return nil, nil
	end

	if not pcall(ffi.typeof, "struct ml_winsize") then
		pcall(
			ffi.cdef,
			[[
				struct ml_winsize {
					unsigned short ws_row;
					unsigned short ws_col;
					unsigned short ws_xpixel;
					unsigned short ws_ypixel;
				};
			]]
		)
	end

	if not pcall(function()
		return ffi.C.ioctl
	end) then
		pcall(ffi.cdef, "int ioctl(int fd, unsigned long request, ...);")
	end

	local ok_ioctl_sym = pcall(function()
		return ffi.C.ioctl
	end)
	local ok_ws, ws = pcall(ffi.new, "struct ml_winsize")
	if ok_ioctl_sym and ok_ws then
		ffi_state.ffi = ffi
		ffi_state.ws = ws
	end
	return ffi_state.ffi, ffi_state.ws
end

--- Opens a TTY path safely via libuv using `O_RDONLY | O_NOCTTY | O_NONBLOCK`.
--- @param path string|nil
--- @return integer|nil fd
local function open_tty_readonly(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local c = vim.uv.constants or {}
	local flags = bit.bor(c.O_RDONLY or 0, c.O_NOCTTY or 0, c.O_NONBLOCK or 0)
	local ok, fd = pcall(vim.uv.fs_open, path, flags, 0)
	if ok and type(fd) == "number" and fd >= 0 then
		return fd
	end
	return nil
end

--- Queries cell pixel dimensions for a single open file descriptor via `ioctl(TIOCGWINSZ)`.
--- @param ffi table
--- @param ws userdata
--- @param fd integer
--- @return number|nil cell_w, number|nil cell_h
local function query_fd_cell_pixels(ffi, ws, fd)
	ws.ws_row = 0
	ws.ws_col = 0
	ws.ws_xpixel = 0
	ws.ws_ypixel = 0

	local ok_ioctl, ret = pcall(ffi.C.ioctl, fd, ffi_state.ioctl_req, ws)
	if ok_ioctl and ret == 0 and ws.ws_col > 0 and ws.ws_row > 0 and ws.ws_xpixel > 0 and ws.ws_ypixel > 0 then
		return ws.ws_xpixel / ws.ws_col, ws.ws_ypixel / ws.ws_row
	end
	return nil, nil
end

--- Determines whether the host terminal supports the Kitty graphics protocol.
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
--- Tries TMUX `client_tty`, then `stderr` (`fd = 2`), then `/dev/tty` via non-blocking libuv opens.
--- @param client_tty string|nil Optional TTY device path from TMUX
--- @return number cell_w, number cell_h
local function query_cell_pixel_dimensions(client_tty)
	local cell_w = constants.LIMITS.FALLBACK_CELL_WIDTH_PX
	local cell_h = constants.LIMITS.FALLBACK_CELL_HEIGHT_PX

	if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		return cell_w, cell_h
	end

	local ffi, ws = get_ffi_winsize()
	if not ffi or not ws then
		return cell_w, cell_h
	end

	if client_tty and client_tty ~= "" then
		local c_fd = open_tty_readonly(client_tty)
		if c_fd then
			local w, h = query_fd_cell_pixels(ffi, ws, c_fd)
			pcall(vim.uv.fs_close, c_fd)
			if w and h then
				return w, h
			end
		end
	end

	local stderr_w, stderr_h = query_fd_cell_pixels(ffi, ws, 2)
	if stderr_w and stderr_h then
		return stderr_w, stderr_h
	end

	local tty_fd = open_tty_readonly("/dev/tty")
	if tty_fd then
		local w, h = query_fd_cell_pixels(ffi, ws, tty_fd)
		pcall(vim.uv.fs_close, tty_fd)
		if w and h then
			return w, h
		end
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
