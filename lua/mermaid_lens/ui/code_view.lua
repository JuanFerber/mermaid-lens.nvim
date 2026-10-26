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
--- preserves its own isolated undo/redo history across modal sessions.
--- @type table<string, integer>
local diagram_buffers = {}

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
--- @param callbacks { on_save: fun(lines: string[]), on_toggle_preview: fun(), on_help: fun(), on_quit: fun() }
--- @return integer code_buf
function M.get_or_create_buffer(diagram, modal_keys, callbacks)
	local key = make_diagram_key(diagram)
	local buf = diagram_buffers[key]
	local incoming_lines = vim.split(diagram.code or "", "\n", { plain = true })

	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		buf = vim.api.nvim_create_buf(false, true)
		diagram_buffers[key] = buf

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
			vim.bo[buf].modified = false
			if callbacks.on_save then
				callbacks.on_save(current_lines)
			end
		end,
	})

	local kopts = { buffer = buf, silent = true, nowait = true }
	local mk = modal_keys or {}

	input.bind("n", mk.toggle_code or "<Tab>", function()
		if callbacks.on_toggle_preview then
			callbacks.on_toggle_preview()
		end
	end, kopts)

	input.bind("n", mk.help or "?", function()
		if callbacks.on_help then
			callbacks.on_help()
		end
	end, kopts)

	-- Bind quit keys with unsaved-changes protection for `q` and force-revert + quit on `<Esc>`
	local quit_keys = mk.quit or { "q", "<Esc>" }
	if type(quit_keys) == "string" then
		quit_keys = { quit_keys }
	end
	if type(quit_keys) == "table" then
		for _, k in ipairs(quit_keys) do
			if k == "<Esc>" then
				vim.keymap.set("n", "<Esc>", function()
					if vim.bo[buf].modified then
						local saved_lines = vim.split(diagram.code or "", "\n", { plain = true })
						vim.api.nvim_buf_set_lines(buf, 0, -1, false, saved_lines)
						vim.bo[buf].modified = false
					end
					if callbacks.on_quit then
						callbacks.on_quit()
					end
				end, kopts)
			else
				vim.keymap.set("n", k, function()
					if vim.bo[buf].modified then
						vim.notify(
							"MermaidLens: Unsaved changes in diagram! Use `:w` to save or `<Esc>` to discard and quit.",
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
	vim.api.nvim_win_set_config(win, {
		title = title_chunks,
		title_pos = "center",
	})

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
	vim.api.nvim_win_set_config(win, {
		title = title_chunks,
		title_pos = "center",
	})

	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].cursorline = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false
end

return M
