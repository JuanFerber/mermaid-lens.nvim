--- @module mermaid_lens.renderer.bridge_client
--- Architectural Layer: Infrastructure / IPC Client
--- Parent: `mermaid_lens.renderer.compiler` and `mermaid_lens.init`
--- Children: None (Leaf module).
--- Single Responsibility: Manage the lifecycle of the persistent zero-dependency
--- Node.js `bridge.js` worker over stdio JSONL with per-request timeouts, bounded
--- stdio buffers, stderr diagnostics ring-buffer, and a recoverable 3-state circuit breaker.

local M = {}

local REQUEST_TIMEOUT_MS = 10000
local MAX_CONSECUTIVE_FAILURES = 3
local CIRCUIT_COOLDOWN_MS = 60000
local MAX_STDERR_LINES = 20
local MAX_STDOUT_BUF_BYTES = 1024 * 1024
local MAX_STDERR_BUF_BYTES = 8192

_G._mermaid_lens_bridge_state = _G._mermaid_lens_bridge_state or {}

local state = _G._mermaid_lens_bridge_state
state.next_id = state.next_id or 1
state.pending = state.pending or {}
state.stdout_buf = state.stdout_buf or ""
state.stderr_buf = state.stderr_buf or ""
state.last_stderr = state.last_stderr or {}
state.has_succeeded_once = state.has_succeeded_once or false
state.stopping_intentionally = state.stopping_intentionally or false
state.consecutive_failures = state.consecutive_failures or 0
state.circuit_state = state.circuit_state or "closed"
state.open_until_ms = state.open_until_ms or 0

local function now_ms()
	return math.floor(vim.uv.hrtime() / 1e6)
end

local function current_circuit_state()
	if state.circuit_state == "open" and now_ms() >= state.open_until_ms then
		state.circuit_state = "half_open"
	end
	return state.circuit_state
end

local function record_success()
	state.has_succeeded_once = true
	state.consecutive_failures = 0
	state.circuit_state = "closed"
	state.open_until_ms = 0
	state.last_error = nil
end

local function record_failure(reason)
	state.consecutive_failures = (state.consecutive_failures or 0) + 1
	if reason and reason ~= "" then
		state.last_error = reason
	end
	if state.circuit_state == "half_open" or state.consecutive_failures >= MAX_CONSECUTIVE_FAILURES then
		state.circuit_state = "open"
		state.open_until_ms = now_ms() + CIRCUIT_COOLDOWN_MS
	end
end

local function append_stderr(data)
	if not data or data == "" then
		return
	end
	state.stderr_buf = state.stderr_buf .. data
	while true do
		local nl = state.stderr_buf:find("\n", 1, true)
		if not nl then
			break
		end
		local line = state.stderr_buf:sub(1, nl - 1):gsub("\r$", "")
		state.stderr_buf = state.stderr_buf:sub(nl + 1)
		if line ~= "" then
			table.insert(state.last_stderr, line)
			if #state.last_stderr > MAX_STDERR_LINES then
				table.remove(state.last_stderr, 1)
			end
		end
	end
	if #state.stderr_buf > MAX_STDERR_BUF_BYTES then
		state.stderr_buf = state.stderr_buf:sub(-math.floor(MAX_STDERR_BUF_BYTES / 2))
	end
end

local function get_bridge_script_path()
	local src = debug.getinfo(1, "S").source
	local file = src:sub(1, 1) == "@" and src:sub(2) or src
	local dir = vim.fs.dirname(vim.fn.fnamemodify(file, ":p"))
	return dir .. "/bridge.js"
end

local function read_script_signature(script_path)
	local stat = vim.uv.fs_stat(script_path)
	if not stat then
		return nil
	end
	return {
		path = script_path,
		size = stat.size or 0,
		mtime_sec = stat.mtime and stat.mtime.sec or 0,
		mtime_nsec = stat.mtime and stat.mtime.nsec or 0,
	}
end

local function signatures_equal(a, b)
	if not a or not b then
		return false
	end
	return a.path == b.path
		and a.size == b.size
		and a.mtime_sec == b.mtime_sec
		and a.mtime_nsec == b.mtime_nsec
end

local function clear_entry_timer(entry)
	if entry and entry.timer then
		pcall(function()
			entry.timer:stop()
			entry.timer:close()
		end)
		entry.timer = nil
	end
end

local function handle_stdout_line(line)
	local prefix = "MLENS:"
	if line:sub(1, #prefix) ~= prefix then
		return
	end

	local json_str = line:sub(#prefix + 1)
	local ok, decoded = pcall(vim.json.decode, json_str)
	if not ok or type(decoded) ~= "table" or not decoded.id then
		return
	end

	if decoded.status == "ok" then
		record_success()
	end

	local entry = state.pending[decoded.id]
	if entry then
		state.pending[decoded.id] = nil
		clear_entry_timer(entry)
		vim.schedule(function()
			entry.cb(decoded)
		end)
	end
end

--- Records a bridge failure in the circuit breaker and stops the running worker.
--- Calls without `reason` when no job is running are treated as idempotent no-ops
--- to avoid double-counting failures already recorded on timeout or crash.
--- @param reason string|nil
function M.mark_failed(reason)
	if reason == nil and state.job == nil then
		return
	end
	record_failure(reason or "Bridge reported fatal error.")
	M.stop()
end

--- Resets the circuit breaker back to `closed` state (clears failure count and cooldown).
function M.reset_circuit()
	state.consecutive_failures = 0
	state.circuit_state = "closed"
	state.open_until_ms = 0
	state.last_error = nil
end

--- Returns a diagnostic snapshot of the bridge lifecycle, circuit breaker, and recent `stderr`.
--- @return { running: boolean, circuit_state: "closed"|"open"|"half_open", consecutive_failures: integer, max_failures: integer, cooldown_remaining_ms: integer, has_succeeded_once: boolean, last_error: string|nil, last_stderr: string[] }
function M.get_status()
	local circuit = current_circuit_state()
	local cooldown_remaining_ms = 0
	if circuit == "open" then
		cooldown_remaining_ms = math.max(0, state.open_until_ms - now_ms())
	end
	return {
		running = state.job ~= nil,
		circuit_state = circuit,
		consecutive_failures = state.consecutive_failures,
		max_failures = MAX_CONSECUTIVE_FAILURES,
		cooldown_remaining_ms = cooldown_remaining_ms,
		has_succeeded_once = state.has_succeeded_once,
		last_error = state.last_error,
		last_stderr = vim.deepcopy(state.last_stderr),
	}
end

--- Checks whether the warm bridge can be used right now (accounting for circuit cooldown).
--- @return boolean
function M.is_available()
	if current_circuit_state() == "open" then
		return false
	end
	if vim.fn.executable("node") == 0 or vim.fn.executable("mmdc") == 0 then
		return false
	end
	return vim.fn.filereadable(get_bridge_script_path()) == 1
end

--- Starts the persistent Node.js bridge process lazily if not already running.
--- @return boolean started
function M.ensure_started()
	if state.job then
		return true
	end
	if not M.is_available() then
		return false
	end

	local mmdc_path = vim.fn.exepath("mmdc")
	local script_path = get_bridge_script_path()
	local script_sig = read_script_signature(script_path)
	state.stdout_buf = ""
	state.stderr_buf = ""
	state.stopping_intentionally = false

	local ok, job = pcall(vim.system, { "node", script_path, mmdc_path }, {
		stdin = true,
		stdout = function(_, data)
			if not data then
				return
			end
			state.stdout_buf = state.stdout_buf .. data
			if #state.stdout_buf > MAX_STDOUT_BUF_BYTES then
				state.stdout_buf = ""
				vim.schedule(function()
					M.mark_failed("Warm bridge stdout buffer exceeded 1 MB limit.")
				end)
				return
			end
			while true do
				local nl = state.stdout_buf:find("\n", 1, true)
				if not nl then
					break
				end
				local line = state.stdout_buf:sub(1, nl - 1):gsub("\r$", "")
				state.stdout_buf = state.stdout_buf:sub(nl + 1)
				if line ~= "" then
					handle_stdout_line(line)
				end
			end
		end,
		stderr = function(_, data)
			append_stderr(data)
		end,
	}, function(exit_obj)
		local exit_code = exit_obj and exit_obj.code or -1
		if not state.stopping_intentionally and (not state.has_succeeded_once or exit_code ~= 0) then
			record_failure(string.format("Warm bridge exited unexpectedly (code %d).", exit_code))
		end

		local orphaned = state.pending
		state.job = nil
		state.script_sig = nil
		state.pending = {}
		vim.schedule(function()
			for _, entry in pairs(orphaned) do
				clear_entry_timer(entry)
				pcall(entry.cb, {
					status = "error",
					error_type = "bridge_fatal",
					error = "Warm bridge process terminated unexpectedly.",
				})
			end
		end)
	end)

	if not ok or not job then
		record_failure("Failed to spawn warm bridge Node process.")
		return false
	end

	state.job = job
	state.script_sig = script_sig
	return true
end

--- Sends a JSONL request to the warm bridge with a 10-second watchdog timeout.
--- @param payload table
--- @param callback fun(res: table)
function M.request(payload, callback)
	if not M.ensure_started() then
		callback({
			status = "error",
			error_type = "bridge_fatal",
			error = "Bridge unavailable.",
		})
		return
	end

	local id = state.next_id
	state.next_id = id + 1
	payload.id = id

	local timer = vim.uv.new_timer()
	state.pending[id] = {
		cb = callback,
		timer = timer,
	}

	timer:start(
		REQUEST_TIMEOUT_MS,
		0,
		vim.schedule_wrap(function()
			local entry = state.pending[id]
			if not entry then
				return
			end
			state.pending[id] = nil
			clear_entry_timer(entry)
			M.mark_failed("Warm bridge timed out after 10 seconds.")
			pcall(entry.cb, {
				status = "error",
				error_type = "bridge_fatal",
				error = "Warm bridge timed out after 10 seconds.",
			})
		end)
	)

	local encoded = vim.json.encode(payload) .. "\n"
	local ok = pcall(function()
		state.job:write(encoded)
	end)

	if not ok then
		local entry = state.pending[id]
		state.pending[id] = nil
		clear_entry_timer(entry)
		M.mark_failed("Failed to write to bridge stdin.")
		callback({
			status = "error",
			error_type = "bridge_fatal",
			error = "Failed to write to bridge stdin.",
		})
	end
end

--- Checks whether `bridge.js` on disk changed since the running worker was spawned,
--- and stops the worker immediately if so (used during hot-reload / plugin updates).
--- @return boolean stopped
function M.stop_if_script_changed()
	if not state.job then
		return false
	end
	local current_sig = read_script_signature(get_bridge_script_path())
	if not signatures_equal(state.script_sig, current_sig) then
		M.stop({ immediate = true })
		return true
	end
	return false
end

--- Gracefully stops the persistent Node.js + Chromium process and notifies orphaned callers.
--- When `opts.immediate` is true (e.g. during `VimLeavePre`/`VimLeave`), closes stdin
--- and signals `SIGTERM` synchronously without scheduling fallback callbacks.
--- @param opts { immediate?: boolean }|nil
function M.stop(opts)
	opts = opts or {}
	if not state.job then
		return
	end
	state.stopping_intentionally = true
	local job = state.job
	local orphaned = state.pending
	state.job = nil
	state.script_sig = nil
	state.pending = {}

	local has_orphaned = false
	for _, entry in pairs(orphaned) do
		clear_entry_timer(entry)
		has_orphaned = true
	end

	if has_orphaned and not opts.immediate then
		vim.schedule(function()
			for _, entry in pairs(orphaned) do
				pcall(entry.cb, {
					status = "error",
					error_type = "bridge_cancelled",
					error = "Warm bridge stopped before request completed.",
				})
			end
		end)
	end

	pcall(function()
		job:write(vim.json.encode({ action = "shutdown" }) .. "\n")
	end)
	pcall(function()
		job:write(nil)
	end)

	if opts.immediate then
		pcall(function()
			job:kill(15)
		end)
		return
	end

	vim.defer_fn(function()
		pcall(function()
			job:kill(15)
		end)
	end, 150)
end

return M
