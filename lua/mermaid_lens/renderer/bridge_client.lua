--- @module mermaid_lens.renderer.bridge_client
--- Architectural Layer: Infrastructure / IPC Client
--- Parent: `mermaid_lens.renderer.compiler` and `mermaid_lens.init`
--- Children: None (Leaf module).
--- Single Responsibility: Manage the lifecycle of the persistent zero-dependency
--- Node.js `bridge.js` worker over stdio JSONL with per-request timeouts and circuit-breaker protection.

local M = {}

local REQUEST_TIMEOUT_MS = 10000

_G._mermaid_lens_bridge_state = _G._mermaid_lens_bridge_state
	or {
		job = nil,
		next_id = 1,
		pending = {},
		stdout_buf = "",
		has_succeeded_once = false,
		failed_permanently = false,
		stopping_intentionally = false,
	}

local state = _G._mermaid_lens_bridge_state

local function get_bridge_script_path()
	local src = debug.getinfo(1, "S").source
	local file = src:sub(1, 1) == "@" and src:sub(2) or src
	local dir = vim.fs.dirname(vim.fn.fnamemodify(file, ":p"))
	return dir .. "/bridge.js"
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
		state.has_succeeded_once = true
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

--- Marks the bridge as permanently unavailable for the rest of the current Neovim session.
function M.mark_failed()
	state.failed_permanently = true
	M.stop()
end

--- Checks whether the warm bridge can be used on this machine.
--- @return boolean
function M.is_available()
	if state.failed_permanently then
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
	state.stdout_buf = ""
	state.stopping_intentionally = false

	local ok, job = pcall(vim.system, { "node", script_path, mmdc_path }, {
		stdin = true,
		stdout = function(_, data)
			if not data then
				return
			end
			state.stdout_buf = state.stdout_buf .. data
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
		stderr = function(_, _) end,
	}, function(exit_obj)
		-- Circuit-breaker: if Node exited unexpectedly before ever succeeding or with non-zero code,
		-- trip `failed_permanently` so we never spawn an infinite loop of failing Node processes.
		if not state.stopping_intentionally and (not state.has_succeeded_once or (exit_obj and exit_obj.code ~= 0)) then
			state.failed_permanently = true
		end

		local orphaned = state.pending
		state.job = nil
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
		state.failed_permanently = true
		return false
	end

	state.job = job
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
			M.mark_failed()
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
		M.mark_failed()
		callback({
			status = "error",
			error_type = "bridge_fatal",
			error = "Failed to write to bridge stdin.",
		})
	end
end

--- Gracefully stops the persistent Node.js + Chromium process.
function M.stop()
	if not state.job then
		return
	end
	state.stopping_intentionally = true
	local job = state.job
	local orphaned = state.pending
	state.job = nil
	state.pending = {}

	for _, entry in pairs(orphaned) do
		clear_entry_timer(entry)
	end

	pcall(function()
		job:write(vim.json.encode({ action = "shutdown" }) .. "\n")
	end)
	vim.defer_fn(function()
		pcall(function()
			job:kill(15)
		end)
	end, 150)
end

return M
