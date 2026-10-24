--- @module mermaid_lens.env.multiplexer
--- Architectural Layer: Infrastructure
--- Parent: `mermaid_lens.env.terminal` and `mermaid_lens.graphics.kitty`
--- Children: None (Leaf module).
--- Single Responsibility: Detect terminal multiplexer sessions (TMUX), configure
--- passthrough/focus policies, query active pane offsets, and wrap escape sequences.

local M = {}

local is_configured = false

--- Checks whether the current Neovim instance is running inside a TMUX session.
--- @return boolean
function M.is_tmux()
	return os.getenv("TMUX") ~= nil
end

--- Configures the active TMUX server to emit focus events and allow passthrough
--- sequences from background/blurred panes so images can be cleaned up on tab switch.
--- Side effects: Executes `tmux set -g` commands once per session.
function M.ensure_configured()
	if not M.is_tmux() or is_configured then
		return
	end
	is_configured = true
	-- `allow-passthrough all` is required because TMUX marks the outgoing window
	-- as inactive before dispatching `FocusLost` to Neovim.
	vim.fn.system({ "tmux", "set", "-g", "focus-events", "on" })
	vim.fn.system({ "tmux", "set", "-g", "allow-passthrough", "all" })
end

--- @class TmuxPaneGeometry
--- @field top integer Row offset of the active pane (including top status bar)
--- @field left integer Column offset of the active pane
--- @field client_tty string|nil Path to the underlying host client TTY device

--- Queries TMUX for the active pane's top/left coordinates and host client TTY path.
--- Relation to parent (`terminal`): Provides the physical screen offset and host TTY
--- descriptor required to align Kitty graphics placements and query pixel metrics.
--- @return TmuxPaneGeometry
function M.get_pane_geometry()
	if not M.is_tmux() then
		return { top = 0, left = 0, client_tty = nil }
	end

	local out = vim.fn.system({
		"tmux",
		"display-message",
		"-p",
		"#{pane_top},#{pane_left},#{status},#{status-position},#{client_tty}",
	})

	if vim.v.shell_error ~= 0 or not out then
		return { top = 0, left = 0, client_tty = nil }
	end

	local top, left, status, pos, tty = out:match("^(%d+),(%d+),([^,]+),([%w%-]+),([^\r\n]+)")
	if not top or not left then
		return { top = 0, left = 0, client_tty = nil }
	end

	local row_offset = tonumber(top) or 0
	local col_offset = tonumber(left) or 0

	-- TMUX's `#{pane_top}` is relative to the window layout area and does not count
	-- the status bar row when `status-position` is set to `top`.
	if status ~= "off" and pos == "top" then
		local status_lines = tonumber(status) or 1
		row_offset = row_offset + status_lines
	end

	return {
		top = row_offset,
		left = col_offset,
		client_tty = tty,
	}
end

--- Wraps a raw terminal escape sequence inside a TMUX DCS passthrough envelope
--- when running inside TMUX; returns the sequence unchanged otherwise.
--- @param seq string Raw escape sequence
--- @return string
function M.wrap_passthrough(seq)
	if not M.is_tmux() then
		return seq
	end
	return "\x1bPtmux;" .. seq:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
end

return M
