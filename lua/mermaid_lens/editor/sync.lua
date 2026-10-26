--- @module mermaid_lens.editor.sync
--- Architectural Layer: Use Case / Application Service
--- Parent: `mermaid_lens.ui.modal`
--- Children: `mermaid_lens.parser.detector`
--- Single Responsibility: Synchronize Mermaid source code edited inside the modal
--- back to the origin buffer and/or disk file (`.md` block or `.mmd` file) while
--- relocating shifted code fences safely and updating `end_lnum` atomically.

local detector = require("mermaid_lens.parser.detector")

local M = {}

--- Finds an already loaded Neovim buffer matching `filepath`, if any.
--- @param filepath string
--- @return integer|nil bufnr
local function find_loaded_buffer(filepath)
	if not filepath or filepath == "" or filepath:match("^%[") then
		return nil
	end
	local target_abs = vim.fn.fnamemodify(filepath, ":p")
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local bname = vim.api.nvim_buf_get_name(bufnr)
			if bname ~= "" and vim.fn.fnamemodify(bname, ":p") == target_abs then
				return bufnr
			end
		end
	end
	return nil
end

--- Locates the opening and closing fence lines (` ``` `) for `diagram` inside `lines`.
--- Fast-paths if `lnum` and `end_lnum` are unchanged; otherwise parses all fenced blocks
--- statefully so even large insertions/deletions above the diagram in the host file
--- never corrupt or misidentify the target block.
--- @param lines string[]
--- @param diagram MermaidDiagramEntry
--- @return integer|nil start_lnum, integer|nil close_lnum
local function verify_or_relocate_fence(lines, diagram)
	local s = diagram.lnum
	local e = diagram.end_lnum

	if lines[s] and lines[s]:match("^%s*```") and lines[e] and lines[e]:match("^%s*```%s*$") then
		return s, e
	end

	local candidates = {}
	local in_block = false
	local open_idx = 1
	local info_str = ""
	local body = {}

	for idx, line in ipairs(lines) do
		local fence_open = line:match("^%s*```(.*)$")
		if not in_block and fence_open then
			in_block = true
			open_idx = idx
			info_str = fence_open
			body = {}
		elseif in_block and line:match("^%s*```%s*$") then
			local code = table.concat(body, "\n")
			local explicit_name, is_mermaid = detector.extract_explicit_name(info_str, code)
			local dtype = detector.detect_diagram_type(code)
			if is_mermaid and dtype then
				table.insert(candidates, {
					open_lnum = open_idx,
					close_lnum = idx,
					explicit_name = explicit_name,
					diagram_type = dtype,
					code = code,
				})
			end
			in_block = false
		elseif in_block then
			table.insert(body, line)
		end
	end

	-- 1. Exact content match (if user edited outside the diagram in the host file)
	local best_match = nil
	local best_dist = math.huge
	for _, c in ipairs(candidates) do
		if c.code == diagram.code then
			local dist = math.abs(c.open_lnum - (s or 1))
			if dist < best_dist then
				best_dist = dist
				best_match = c
			end
		end
	end
	if best_match then
		return best_match.open_lnum, best_match.close_lnum
	end

	-- 2. Match by explicit diagram name or diagram type closest to original line number
	best_dist = math.huge
	for _, c in ipairs(candidates) do
		local name_matches = diagram.has_custom_name and (c.explicit_name == diagram.name)
		local type_matches = not diagram.has_custom_name and (c.diagram_type == diagram.diagram_type)
		if name_matches or type_matches then
			local dist = math.abs(c.open_lnum - (s or 1))
			if dist < best_dist then
				best_dist = dist
				best_match = c
			end
		end
	end
	if best_match then
		return best_match.open_lnum, best_match.close_lnum
	end

	return nil, nil
end

--- Writes updated diagram lines back to the origin `.md` block or `.mmd` file.
--- Replaces strictly the diagram's line range so outside edits in the host buffer remain untouched.
--- Mutates `diagram.code`, `diagram.lnum`, and `diagram.end_lnum` in place on success.
--- @param diagram MermaidDiagramEntry
--- @param new_lines string[]
--- @param opts { write_to_disk?: boolean }|nil
--- @return boolean ok, string|nil err_msg
function M.apply_changes(diagram, new_lines, opts)
	opts = opts or {}
	local write_to_disk = opts.write_to_disk ~= false

	if not diagram or not diagram.filepath then
		return false, "Diagram has no associated source file."
	end

	local bufnr = find_loaded_buffer(diagram.filepath)

	-- Case A: Standalone `.mmd` / `.mermaid` file
	if diagram.kind == "file" then
		if bufnr then
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
			if write_to_disk and not diagram.filepath:match("^%[") then
				vim.api.nvim_buf_call(bufnr, function()
					vim.cmd("silent! write")
				end)
			end
		elseif write_to_disk and not diagram.filepath:match("^%[") then
			local ok_w = pcall(vim.fn.writefile, new_lines, diagram.filepath)
			if not ok_w then
				return false, "Failed to write changes to " .. diagram.filepath
			end
		end

		diagram.code = table.concat(new_lines, "\n")
		diagram.lnum = 1
		diagram.end_lnum = #new_lines
		return true, nil
	end

	-- Case B: Fenced block inside a Markdown document
	if bufnr then
		local host_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local open_lnum, close_lnum = verify_or_relocate_fence(host_lines, diagram)
		if not open_lnum or not close_lnum then
			return false, "Could not locate original Markdown code fence in buffer."
		end

		-- Replace only the inner body lines [open_lnum, close_lnum - 1) (0-indexed)
		vim.api.nvim_buf_set_lines(bufnr, open_lnum, close_lnum - 1, false, new_lines)

		if write_to_disk and not diagram.filepath:match("^%[") then
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("silent! write")
			end)
		end

		diagram.lnum = open_lnum
		diagram.end_lnum = open_lnum + #new_lines + 1
		diagram.code = table.concat(new_lines, "\n")
		return true, nil
	end

	-- Host Markdown file is not loaded in a buffer: update directly on disk
	if not diagram.filepath:match("^%[") and vim.fn.filereadable(diagram.filepath) == 1 then
		local ok_r, disk_lines = pcall(vim.fn.readfile, diagram.filepath)
		if not ok_r or type(disk_lines) ~= "table" then
			return false, "Failed to read source file from disk."
		end

		local open_lnum, close_lnum = verify_or_relocate_fence(disk_lines, diagram)
		if not open_lnum or not close_lnum then
			return false, "Could not locate original Markdown code fence on disk."
		end

		local updated_file = {}
		for i = 1, open_lnum do
			table.insert(updated_file, disk_lines[i])
		end
		for _, l in ipairs(new_lines) do
			table.insert(updated_file, l)
		end
		for i = close_lnum, #disk_lines do
			table.insert(updated_file, disk_lines[i])
		end

		local ok_w = pcall(vim.fn.writefile, updated_file, diagram.filepath)
		if not ok_w then
			return false, "Failed to write updated Markdown file to disk."
		end

		diagram.lnum = open_lnum
		diagram.end_lnum = open_lnum + #new_lines + 1
		diagram.code = table.concat(new_lines, "\n")
		return true, nil
	end

	return false, "Source buffer or file is no longer accessible."
end

return M
