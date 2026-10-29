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

--- Finds the closest candidate in `candidates` matching `predicate`.
--- @param candidates ParsedMermaidFence[]
--- @param target_line integer
--- @param predicate fun(c: ParsedMermaidFence): boolean
--- @return ParsedMermaidFence|nil
local function find_closest_candidate(candidates, target_line, predicate)
	local best_match = nil
	local best_dist = math.huge
	for _, c in ipairs(candidates) do
		if predicate(c) then
			local dist = math.abs(c.open_lnum - target_line)
			if dist < best_dist then
				best_dist = dist
				best_match = c
			end
		end
	end
	return best_match
end

--- Locates the opening and closing fence lines (` ``` `) for `diagram` inside `lines`.
--- @param lines string[]
--- @param diagram MermaidDiagramEntry
--- @return integer|nil start_lnum, integer|nil close_lnum
local function verify_or_relocate_fence(lines, diagram)
	local s = diagram.lnum
	local e = diagram.end_lnum

	if lines[s] and lines[s]:match("^%s*```") and lines[e] and lines[e]:match("^%s*```%s*$") then
		return s, e
	end

	local candidates = detector.scan_fenced_blocks(lines)
	local anchor = s or 1

	local exact = find_closest_candidate(candidates, anchor, function(c)
		return c.code == diagram.code
	end)
	if exact then
		return exact.open_lnum, exact.close_lnum
	end

	local by_identity = find_closest_candidate(candidates, anchor, function(c)
		local name_matches = diagram.has_custom_name and (c.explicit_name == diagram.name)
		local type_matches = not diagram.has_custom_name and (c.diagram_type == diagram.diagram_type)
		return name_matches or type_matches
	end)
	if by_identity then
		return by_identity.open_lnum, by_identity.close_lnum
	end

	return nil, nil
end

--- Writes updated diagram lines back to the origin `.md` block or `.mmd` file.
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

	if bufnr then
		local host_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local open_lnum, close_lnum = verify_or_relocate_fence(host_lines, diagram)
		if not open_lnum or not close_lnum then
			return false, "Could not locate original Markdown code fence in buffer."
		end

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
