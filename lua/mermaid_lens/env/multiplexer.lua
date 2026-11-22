--- @module mermaid_lens.env.multiplexer
--- Architectural Layer: Infrastructure
--- Parent: `mermaid_lens.env.terminal`, `mermaid_lens.graphics.kitty`, and `mermaid_lens.health`
--- Children: `mermaid_lens.config.state`
--- Single Responsibility: Detect terminal multiplexer sessions (TMUX), configure
--- pane-scoped passthrough/focus policies, query active pane offsets, and wrap escape sequences.

local config_state = require("mermaid_lens.config.state")

local M = {}

local is_configured = false

--- Executes a `tmux show` query and returns the trimmed option value if successful.
--- @param args string[]
--- @return string
local function query_tmux_option(args)
	local out = vim.fn.system(args)
	if vim.v.shell_error ~= 0 or type(out) ~= "string" then
		return ""
	end
	return vim.trim(out)
end

--- Builds a pane-targeted `tmux` command, attaching `-t $TMUX_PANE` when available.
--- @param base_args string[]
--- @param tail_args string[]
--- @return string[]
local function with_pane_target(base_args, tail_args)
	local cmd = vim.list_extend({}, base_args)
	local pane_id = os.getenv("TMUX_PANE")
	if pane_id and pane_id ~= "" then
		table.insert(cmd, "-t")
		table.insert(cmd, pane_id)
	end
	return vim.list_extend(cmd, tail_args)
end

--- Checks whether the current Neovim instance is running inside a TMUX session.
--- @return boolean
function M.is_tmux()
	return os.getenv("TMUX") ~= nil
end

--- Returns the effective TMUX `allow-passthrough` policy and its scope (`pane`, `window`, `global`, `unset`).
--- @return string value, "pane"|"window"|"global"|"unset" scope
function M.get_passthrough_policy()
	if not M.is_tmux() then
		return "", "unset"
	end

	local pane_val = query_tmux_option(with_pane_target({ "tmux", "show", "-pqv" }, { "allow-passthrough" }))
	if pane_val ~= "" then
		return pane_val, "pane"
	end

	local win_val = query_tmux_option(with_pane_target({ "tmux", "show", "-wqv" }, { "allow-passthrough" }))
	if win_val ~= "" then
		return win_val, "window"
	end

	local global_val = query_tmux_option({ "tmux", "show", "-gqv", "allow-passthrough" })
	if global_val ~= "" then
		return global_val, "global"
	end

	return "", "unset"
end

--- Returns the active TMUX server `focus-events` setting (`on`, `off`, or empty string).
--- @return string
function M.get_focus_events()
	if not M.is_tmux() then
		return ""
	end

	local server_val = query_tmux_option({ "tmux", "show", "-sqv", "focus-events" })
	if server_val ~= "" then
		return server_val
	end
	return query_tmux_option({ "tmux", "show", "-gqv", "focus-events" })
end

--- Configures TMUX for the active Neovim pane (`-p allow-passthrough all`) and enables
--- `focus-events` only if not already active. Respects `config.tmux_auto_configure`.
--- Side effects: Executes pane-scoped `tmux set -p` (and `tmux set -s focus-events on` if needed) once per session.
function M.ensure_configured()
	if not M.is_tmux() or is_configured then
		return
	end
	if config_state.get().tmux_auto_configure == false then
		return
	end
	is_configured = true

	if M.get_focus_events() ~= "on" then
		vim.fn.system({ "tmux", "set", "-s", "focus-events", "on" })
	end

	-- Scope `allow-passthrough all` strictly to this Neovim pane (`-p`) so unrelated
	-- background panes (e.g. remote SSH sessions) cannot inject escape sequences into the host terminal.
	vim.fn.system(with_pane_target({ "tmux", "set", "-p" }, { "allow-passthrough", "all" }))
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
