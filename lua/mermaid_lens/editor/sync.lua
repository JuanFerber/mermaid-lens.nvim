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
	local candidates = detector.scan_fenced_blocks(lines)
	local anchor = s or 1

	-- 1. Fast path: check if s and e still match an active parsed candidate
	if s and e and s < e then
		for _, c in ipairs(candidates) do
			if c.open_lnum == s and c.close_lnum == e then
				return s, e
			end
		end
	end

	-- 2. Exact content match
	local exact = find_closest_candidate(candidates, anchor, function(c)
		return c.code == diagram.code
	end)
	if exact then
		return exact.open_lnum, exact.close_lnum
	end

	-- 3. Match by explicit diagram name or diagram type closest to original line number
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

--- Writes a loaded Neovim buffer to disk without swallowing errors (`silent!`).
--- @param bufnr integer
--- @return boolean ok, string|nil err_msg
local function write_buffer_to_disk(bufnr)
	if vim.bo[bufnr].readonly then
		return false, "Source buffer is read-only."
	end
	local ok_w, err_w = pcall(vim.api.nvim_buf_call, bufnr, function()
		vim.cmd("silent write")
	end)
	if not ok_w then
		return false, "Failed to write buffer to disk: " .. tostring(err_w)
	end
	return true, nil
end

--- Atomically writes `lines` to `filepath` via a sibling temp file and `vim.uv.fs_rename`,
--- checking write permissions and preserving existing file mode.
--- @param filepath string
--- @param lines string[]
--- @return boolean ok, string|nil err_msg
local function write_file_atomically(filepath, lines)
	local existing_stat = vim.uv.fs_stat(filepath)
	if existing_stat and vim.fn.filewritable(filepath) ~= 1 then
		return false, "Target file is not writable: " .. filepath
	end

	local tmp_path = string.format("%s.mlens.tmp.%d.%d", filepath, vim.fn.getpid(), vim.uv.hrtime())
	local ok_w, err_w = pcall(vim.fn.writefile, lines, tmp_path)
	if not ok_w then
		pcall(vim.uv.fs_unlink, tmp_path)
		return false, "Failed to write temporary file for " .. filepath .. ": " .. tostring(err_w)
	end

	if existing_stat and existing_stat.mode then
		pcall(vim.uv.fs_chmod, tmp_path, bit.band(existing_stat.mode, tonumber("7777", 8)))
	end

	local ok_ren, ren_err = vim.uv.fs_rename(tmp_path, filepath)
	if not ok_ren then
		pcall(vim.uv.fs_unlink, tmp_path)
		return false, "Failed to atomically replace " .. filepath .. ": " .. tostring(ren_err)
	end

	return true, nil
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
			if write_to_disk and not diagram.filepath:match("^%[") and vim.bo[bufnr].readonly then
				return false, "Source buffer is read-only."
			end
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
			if write_to_disk and not diagram.filepath:match("^%[") then
				local ok_w, err_w = write_buffer_to_disk(bufnr)
				if not ok_w then
					return false, err_w
				end
			end
		elseif not write_to_disk then
			return false, "Source buffer is not loaded and write_to_disk is disabled."
		elseif not diagram.filepath:match("^%[") then
			local ok_w, err_w = write_file_atomically(diagram.filepath, new_lines)
			if not ok_w then
				return false, err_w
			end
		else
			return false, "Source buffer or file is no longer accessible."
		end

		diagram.code = table.concat(new_lines, "\n")
		diagram.lnum = 1
		diagram.end_lnum = #new_lines
		return true, nil
	end

	if bufnr then
		if write_to_disk and not diagram.filepath:match("^%[") and vim.bo[bufnr].readonly then
			return false, "Source buffer is read-only."
		end
		local host_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local open_lnum, close_lnum = verify_or_relocate_fence(host_lines, diagram)
		if not open_lnum or not close_lnum or open_lnum >= close_lnum or open_lnum < 1 or close_lnum > #host_lines then
			return false, "Could not locate valid Markdown code fence in buffer."
		end

		vim.api.nvim_buf_set_lines(bufnr, open_lnum, close_lnum - 1, false, new_lines)

		if write_to_disk and not diagram.filepath:match("^%[") then
			local ok_w, err_w = write_buffer_to_disk(bufnr)
			if not ok_w then
				return false, err_w
			end
		end

		diagram.lnum = open_lnum
		diagram.end_lnum = open_lnum + #new_lines + 1
		diagram.code = table.concat(new_lines, "\n")
		return true, nil
	end

	if not write_to_disk then
		return false, "Source buffer is not loaded and write_to_disk is disabled."
	end

	if not diagram.filepath:match("^%[") and vim.fn.filereadable(diagram.filepath) == 1 then
		local ok_r, disk_lines = pcall(vim.fn.readfile, diagram.filepath)
		if not ok_r or type(disk_lines) ~= "table" then
			return false, "Failed to read source file from disk."
		end

		local open_lnum, close_lnum = verify_or_relocate_fence(disk_lines, diagram)
		if not open_lnum or not close_lnum or open_lnum >= close_lnum or open_lnum < 1 or close_lnum > #disk_lines then
			return false, "Could not locate valid Markdown code fence on disk."
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

		local ok_w, err_w = write_file_atomically(diagram.filepath, updated_file)
		if not ok_w then
			return false, err_w
		end

		diagram.lnum = open_lnum
		diagram.end_lnum = open_lnum + #new_lines + 1
		diagram.code = table.concat(new_lines, "\n")
		return true, nil
	end

	return false, "Source buffer or file is no longer accessible."
end

return M
