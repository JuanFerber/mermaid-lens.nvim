local T = _G.TestHarness
local bridge_client = require("mermaid_lens.renderer.bridge_client")

local function with_clean_bridge_state(fn)
	local st = _G._mermaid_lens_bridge_state
	local saved = {
		job = st.job,
		pending = st.pending,
		consecutive_failures = st.consecutive_failures,
		circuit_state = st.circuit_state,
		open_until_ms = st.open_until_ms,
		last_error = st.last_error,
		script_sig = st.script_sig,
		stopping_intentionally = st.stopping_intentionally,
	}

	st.job = nil
	st.pending = {}
	st.script_sig = nil
	st.stopping_intentionally = false
	bridge_client.reset_circuit()

	local ok, err = pcall(fn, st)

	st.job = saved.job
	st.pending = saved.pending
	st.consecutive_failures = saved.consecutive_failures
	st.circuit_state = saved.circuit_state
	st.open_until_ms = saved.open_until_ms
	st.last_error = saved.last_error
	st.script_sig = saved.script_sig
	st.stopping_intentionally = saved.stopping_intentionally

	if not ok then
		error(err, 0)
	end
end

T.test("bridge_client opens circuit after 3 consecutive failures and recovers via half_open and reset_circuit", function()
	with_clean_bridge_state(function(st)
		bridge_client.mark_failed("failure 1")
		T.assert_eq(bridge_client.get_status().circuit_state, "closed")
		T.assert_eq(bridge_client.get_status().consecutive_failures, 1)

		bridge_client.mark_failed("failure 2")
		T.assert_eq(bridge_client.get_status().circuit_state, "closed")
		T.assert_eq(bridge_client.get_status().consecutive_failures, 2)

		bridge_client.mark_failed("failure 3")
		local opened = bridge_client.get_status()
		T.assert_eq(opened.circuit_state, "open")
		T.assert_eq(opened.consecutive_failures, 3)
		T.assert_true(opened.cooldown_remaining_ms > 0)
		T.assert_false(bridge_client.is_available())

		-- Simulate cooldown expiry -> half_open
		st.open_until_ms = 0
		T.assert_eq(bridge_client.get_status().circuit_state, "half_open")

		-- Manual reset returns to clean closed state
		bridge_client.reset_circuit()
		local reset = bridge_client.get_status()
		T.assert_eq(reset.circuit_state, "closed")
		T.assert_eq(reset.consecutive_failures, 0)
		T.assert_nil(reset.last_error)
	end)
end)

T.test("bridge_client.mark_failed without reason and without running job is an idempotent no-op", function()
	with_clean_bridge_state(function()
		bridge_client.mark_failed("initial timeout")
		T.assert_eq(bridge_client.get_status().consecutive_failures, 1)

		-- Redundant bare mark_failed() from compiler fallback must not double-count
		bridge_client.mark_failed()
		T.assert_eq(bridge_client.get_status().consecutive_failures, 1)
	end)
end)

T.test("bridge_client.stop cancels orphaned requests with bridge_cancelled and closes timers", function()
	with_clean_bridge_state(function(st)
		local writes = {}
		local fake_job = {
			write = function(_, data)
				table.insert(writes, data)
			end,
			kill = function() end,
		}
		local timer_closed = false
		local fake_timer = {
			stop = function() end,
			close = function()
				timer_closed = true
			end,
		}
		local received = nil

		st.job = fake_job
		st.pending[1] = {
			timer = fake_timer,
			cb = function(res)
				received = res
			end,
		}

		bridge_client.stop()
		vim.wait(200, function()
			return received ~= nil
		end, 10)

		T.assert_true(timer_closed)
		T.assert_false(bridge_client.get_status().running)
		T.assert_true(received ~= nil and received.error_type == "bridge_cancelled")
	end)
end)

T.test("bridge_client.stop_if_script_changed stops worker only when bridge.js signature changes", function()
	with_clean_bridge_state(function(st)
		local killed_sig = nil
		local fake_job = {
			write = function() end,
			kill = function(_, sig)
				killed_sig = sig
			end,
		}
		local bridge_path = vim.fn.getcwd() .. "/lua/mermaid_lens/renderer/bridge.js"
		local stat = assert(vim.uv.fs_stat(bridge_path))

		st.job = fake_job
		st.script_sig = {
			path = bridge_path,
			size = stat.size,
			mtime_sec = stat.mtime.sec,
			mtime_nsec = stat.mtime.nsec,
		}

		T.assert_false(bridge_client.stop_if_script_changed())
		T.assert_true(bridge_client.get_status().running)
		T.assert_nil(killed_sig)

		st.script_sig.size = stat.size + 1
		T.assert_true(bridge_client.stop_if_script_changed())
		T.assert_false(bridge_client.get_status().running)
		T.assert_eq(killed_sig, 15)
	end)
end)
