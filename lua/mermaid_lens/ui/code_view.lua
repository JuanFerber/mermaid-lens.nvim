--- @module mermaid_lens.ui.code_view
--- Architectural Layer: Interface Adapter / View
--- Parent: `mermaid_lens.ui.modal`
--- Children: `mermaid_lens.renderer.diagnostics`, `mermaid_lens.ui.input`
--- Single Responsibility: Manage isolated, per-diagram editable Mermaid buffers
--- with persistent undo trees, `:w` (`BufWriteCmd`) hooks, and syntax diagnostics.

local diagnostics = require("mermaid_lens.renderer.diagnostics")
local input = require("mermaid_lens.ui.input")

local M = {}

--- Persistent cache of editable buffers keyed by `filepath::kind::name` so each diagram
--- preserves its own isolated undo/redo history across modal sessions (capped at 30 buffers).
--- @type table<string, integer>
local diagram_buffers = {}
local diagram_buffer_touch = {}
local touch_seq = 0
local MAX_CACHED_BUFFERS = 30

local function prune_diagram_buffers(protected_key)
	local active = {}
	for k, b in pairs(diagram_buffers) do
		if not vim.api.nvim_buf_is_valid(b) then
			diagram_buffers[k] = nil
			diagram_buffer_touch[k] = nil
		else
			table.insert(active, { key = k, buf = b, touched = diagram_buffer_touch[k] or 0 })
		end
	end

	if #active <= MAX_CACHED_BUFFERS then
		return
	end

	table.sort(active, function(a, b)
		return a.touched < b.touched
	end)

	local remaining = #active
	for _, entry in ipairs(active) do
		if remaining <= MAX_CACHED_BUFFERS then
			break
		end
		local is_open = vim.fn.bufwinid(entry.buf) ~= -1
		local is_dirty = vim.bo[entry.buf].modified
		if entry.key ~= protected_key and not is_open and not is_dirty then
			diagram_buffers[entry.key] = nil
			diagram_buffer_touch[entry.key] = nil
			pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
			remaining = remaining - 1
		end
	end
end

local function make_diagram_key(diagram)
	return string.format(
		"%s::%s::%s",
		diagram.filepath or "[buffer]",
		diagram.kind or "block",
		diagram.name or "diagram"
	)
end

--- Retrieves or creates an isolated editable buffer for `diagram`.
--- Preserves the diagram's dedicated undo tree across modal opens while syncing
--- any external modifications made to the diagram in the host buffer.
--- @param diagram MermaidDiagramEntry
--- @param modal_keys table
--- @param callbacks { on_save: fun(lines: string[], opts?: { skip_render?: boolean }): boolean|nil, on_toggle_preview: fun(), on_help: fun(), on_quit: fun() }
--- @return integer code_buf
function M.get_or_create_buffer(diagram, modal_keys, callbacks)
	local key = make_diagram_key(diagram)
	touch_seq = touch_seq + 1
	diagram_buffer_touch[key] = touch_seq
	prune_diagram_buffers(key)

	local buf = diagram_buffers[key]
	local incoming_lines = vim.split(diagram.code or "", "\n", { plain = true })

	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		buf = vim.api.nvim_create_buf(false, true)
		diagram_buffers[key] = buf
		prune_diagram_buffers(key)

		local virt_name = string.format("mermaid-lens://%s/%s", diagram.filename or "buffer", diagram.name or "diagram")
		pcall(vim.api.nvim_buf_set_name, buf, virt_name)

		vim.bo[buf].buftype = "acwrite"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "mermaid"
		vim.bo[buf].modifiable = true

		-- Set initial baseline without polluting the undo history prior to first edit
		local old_ul = vim.bo[buf].undolevels
		vim.bo[buf].undolevels = -1
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, incoming_lines)
		vim.bo[buf].undolevels = old_ul
		vim.bo[buf].modified = false
	else
		-- If the diagram was modified externally in the host buffer while modal was closed,
		-- append the updated lines into `buf` so the undo tree stays coherent.
		local existing_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if table.concat(existing_lines, "\n") ~= (diagram.code or "") then
			vim.bo[buf].modifiable = true
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, incoming_lines)
			vim.bo[buf].modified = false
		end
	end

	vim.api.nvim_clear_autocmds({ buffer = buf })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			local saved = true
			if callbacks.on_save then
				saved = callbacks.on_save(current_lines) ~= false
			end
			if saved and vim.api.nvim_buf_is_valid(buf) then
				vim.bo[buf].modified = false
			end
		end,
	})

	local kopts = { buffer = buf, silent = true, nowait = true }
	local mk = modal_keys or {}

	input.bind("n", input.resolve_key(mk.toggle_code, "<Tab>"), function()
		if callbacks.on_toggle_preview then
			callbacks.on_toggle_preview()
		end
	end, kopts)

	input.bind("n", input.resolve_key(mk.help, "?"), function()
		if callbacks.on_help then
			callbacks.on_help()
		end
	end, kopts)

	-- Bind quit keys with unsaved-changes protection for both `q` and `<Esc>`
	local quit_keys = input.resolve_key(mk.quit, { "q", "<Esc>" })
	if type(quit_keys) == "string" then
		quit_keys = { quit_keys }
	end
	if type(quit_keys) == "table" then
		for _, k in ipairs(quit_keys) do
			if type(k) == "string" and k ~= "" then
				if k == "<Esc>" then
					vim.keymap.set("n", "<Esc>", function()
						if vim.bo[buf].modified then
							local choice = vim.fn.confirm(
								"MermaidLens: Unsaved changes in diagram. What do you want to do?",
								"&Save and quit\n&Discard and quit\n&Cancel",
								3
							)
							if choice == 1 then
								local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
								local saved = true
								if callbacks.on_save then
									saved = callbacks.on_save(current_lines, { skip_render = true }) ~= false
								end
								if not saved then
									return
								end
								if vim.api.nvim_buf_is_valid(buf) then
									vim.bo[buf].modified = false
								end
							elseif choice == 2 then
								local saved_lines = vim.split(diagram.code or "", "\n", { plain = true })
								vim.api.nvim_buf_set_lines(buf, 0, -1, false, saved_lines)
								vim.bo[buf].modified = false
							else
								return
							end
						end
						if callbacks.on_quit then
							callbacks.on_quit()
						end
					end, kopts)
				else
					vim.keymap.set("n", k, function()
						if vim.bo[buf].modified then
							vim.notify(
								"MermaidLens: Unsaved changes in diagram! Use `:w` to save or `<Esc>` for save/discard options.",
								vim.log.levels.WARN
							)
							return
						end
						if callbacks.on_quit then
							callbacks.on_quit()
						end
					end, kopts)
				end
			end
		end
	end

	return buf
end

--- Switches the modal window `win` to display `code_buf` and configures editor UI options.
--- @param win integer
--- @param code_buf integer
--- @param title_chunks table
--- @param err_info MermaidSyntaxError|nil
--- @param severity integer|nil
function M.activate(win, code_buf, title_chunks, err_info, severity)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	if not code_buf or not vim.api.nvim_buf_is_valid(code_buf) then
		return
	end

	vim.api.nvim_win_set_buf(win, code_buf)
	local win_cfg = vim.api.nvim_win_get_config(win)
	if win_cfg.border and win_cfg.border ~= "none" and win_cfg.border ~= "" then
		vim.api.nvim_win_set_config(win, {
			title = title_chunks,
			title_pos = "center",
		})
	end

	vim.wo[win].number = true
	vim.wo[win].relativenumber = true
	vim.wo[win].cursorline = true
	vim.wo[win].signcolumn = "yes:1"
	vim.wo[win].wrap = false

	if err_info then
		diagnostics.publish(code_buf, err_info, severity)
		local line_count = vim.api.nvim_buf_line_count(code_buf)
		local target_line = math.max(1, math.min(line_count, err_info.line or 1))
		pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
		vim.cmd("normal! zz")
	else
		diagnostics.clear(code_buf)
	end
end

--- Restores minimal canvas window options on `win` when switching back to Kitty Preview Mode.
--- @param win integer
--- @param canvas_buf integer
--- @param title_chunks table
function M.deactivate(win, canvas_buf, title_chunks)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	if not canvas_buf or not vim.api.nvim_buf_is_valid(canvas_buf) then
		return
	end

	vim.api.nvim_win_set_buf(win, canvas_buf)
	local win_cfg = vim.api.nvim_win_get_config(win)
	if win_cfg.border and win_cfg.border ~= "none" and win_cfg.border ~= "" then
		vim.api.nvim_win_set_config(win, {
			title = title_chunks,
			title_pos = "center",
		})
	end

	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].cursorline = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false
end

return M
