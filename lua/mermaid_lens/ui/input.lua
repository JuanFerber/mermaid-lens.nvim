--- @module mermaid_lens.ui.input
--- Architectural Layer: Interface Adapter / Controller
--- Parent: `mermaid_lens.ui.modal` and `mermaid_lens.ui.help`
--- Children: None (Leaf module).
--- Single Responsibility: Sandbox modal buffers against unintended Vim operators/modes
--- and bind mouse drag, scroll wheel, and touchpad gestures.

local M = {}

local drag_state = {
	active = false,
	last_row = 0,
	last_col = 0,
	wheel_mode = "zoom", -- "zoom" | "pan"
}

--- Locks all printable ASCII keys, motions, visual modes, and mouse events in `buf`
--- so the user cannot accidentally trigger Operator-pending mode (e.g., `t`, `f`, `d`, `c`)
--- or mutate buffer state. Callers then whitelist only their allowed keys on top.
--- @param buf integer Buffer handle
function M.lock_buffer_keys(buf)
	local opts = { buffer = buf, silent = true, nowait = true }
	local noop = function() end

	for byte = 32, 126 do
		vim.keymap.set({ "n", "v", "x" }, string.char(byte), noop, opts)
	end

	local extra_blocked = {
		"<Up>",
		"<Down>",
		"<Left>",
		"<Right>",
		"<BS>",
		"<Space>",
		"<Tab>",
		"<CR>",
		"<C-v>",
		"<C-r>",
		"<C-u>",
		"<C-d>",
		"<C-f>",
		"<C-b>",
		"<C-o>",
		"<C-i>",
		"<LeftMouse>",
		"<RightMouse>",
		"<2-LeftMouse>",
		"<LeftDrag>",
		"<LeftRelease>",
		"<ScrollWheelUp>",
		"<ScrollWheelDown>",
		"<ScrollWheelLeft>",
		"<ScrollWheelRight>",
		"<C-ScrollWheelUp>",
		"<C-ScrollWheelDown>",
		"<S-ScrollWheelUp>",
		"<S-ScrollWheelDown>",
		"<S-ScrollWheelLeft>",
		"<S-ScrollWheelRight>",
	}
	for _, key in ipairs(extra_blocked) do
		vim.keymap.set({ "n", "v", "x" }, key, noop, opts)
	end
end

--- Attaches interactive mouse click-drag, wheel zoom, and 2-finger touchpad gestures to `buf`.
--- @param buf integer
--- @param callbacks { zoom: fun(delta: number), pan: fun(dx: number, dy: number), drag_cells: fun(dc: integer, dr: integer), reset: fun(), toggle_fit: fun() }
function M.attach_gestures(buf, callbacks)
	if vim.o.mouse == "" then
		vim.o.mouse = "a"
	end

	local opts = { buffer = buf, silent = true, nowait = true }

	vim.keymap.set("n", "<LeftMouse>", function()
		local pos = vim.fn.getmousepos()
		drag_state.active = true
		drag_state.last_row = pos.screenrow
		drag_state.last_col = pos.screencol
	end, opts)

	vim.keymap.set("n", "<LeftDrag>", function()
		if not drag_state.active then
			return
		end
		local pos = vim.fn.getmousepos()
		local d_col = pos.screencol - drag_state.last_col
		local d_row = pos.screenrow - drag_state.last_row

		if d_col ~= 0 or d_row ~= 0 then
			drag_state.last_col = pos.screencol
			drag_state.last_row = pos.screenrow
			callbacks.drag_cells(-d_col, -d_row)
		end
	end, opts)

	vim.keymap.set("n", "<LeftRelease>", function()
		drag_state.active = false
	end, opts)

	vim.keymap.set("n", "<2-LeftMouse>", callbacks.toggle_fit, opts)
	vim.keymap.set("n", "<RightMouse>", callbacks.reset, opts)

	vim.keymap.set("n", "<C-ScrollWheelUp>", function()
		callbacks.zoom(1)
	end, opts)
	vim.keymap.set("n", "<C-ScrollWheelDown>", function()
		callbacks.zoom(-1)
	end, opts)

	vim.keymap.set("n", "<ScrollWheelUp>", function()
		if drag_state.wheel_mode == "zoom" then
			callbacks.zoom(1)
		else
			callbacks.pan(0, -0.6)
		end
	end, opts)

	vim.keymap.set("n", "<ScrollWheelDown>", function()
		if drag_state.wheel_mode == "zoom" then
			callbacks.zoom(-1)
		else
			callbacks.pan(0, 0.6)
		end
	end, opts)

	vim.keymap.set("n", "<ScrollWheelLeft>", function()
		callbacks.pan(-0.6, 0)
	end, opts)
	vim.keymap.set("n", "<ScrollWheelRight>", function()
		callbacks.pan(0.6, 0)
	end, opts)

	vim.keymap.set("n", "<S-ScrollWheelUp>", function()
		callbacks.pan(0, -0.8)
	end, opts)
	vim.keymap.set("n", "<S-ScrollWheelDown>", function()
		callbacks.pan(0, 0.8)
	end, opts)
	vim.keymap.set("n", "<S-ScrollWheelLeft>", function()
		callbacks.pan(-0.8, 0)
	end, opts)
	vim.keymap.set("n", "<S-ScrollWheelRight>", function()
		callbacks.pan(0.8, 0)
	end, opts)

	vim.keymap.set("n", "m", function()
		if drag_state.wheel_mode == "zoom" then
			drag_state.wheel_mode = "pan"
			vim.notify("MermaidLens: Touchpad 2-finger mode -> 2D PAN", vim.log.levels.INFO)
		else
			drag_state.wheel_mode = "zoom"
			vim.notify("MermaidLens: Touchpad 2-finger mode -> ZOOM", vim.log.levels.INFO)
		end
	end, opts)
end

return M
