--- @module mermaid_lens.parser.scanner
--- Architectural Layer: Use Case / Application Service
--- Parent: `mermaid_lens.init` and `mermaid_lens.ui.picker`
--- Children: `mermaid_lens.parser.detector`, `mermaid_lens.config.constants`, `mermaid_lens.config.state`
--- Single Responsibility: Extract Mermaid diagrams from open buffers or workspace
--- files while honoring `.gitignore`, default/user ignore globs, and file-size bounds.

local constants = require("mermaid_lens.config.constants")
local config_state = require("mermaid_lens.config.state")
local detector = require("mermaid_lens.parser.detector")

local M = {}

--- @class MermaidDiagramEntry
--- @field kind "block"|"file" Origin type of the diagram
--- @field name string Resolved display name (explicit name, filename, or numbered type)
--- @field filename string Base filename with extension
--- @field diagram_type string Canonical Mermaid diagram type (e.g., `erDiagram`, `flowchart`)
--- @field has_custom_name boolean Whether the block has a user-assigned identifier
--- @field code string Raw Mermaid source code
--- @field lnum integer 1-based starting line number in the source file
--- @field end_lnum integer 1-based ending line number in the source file
--- @field filepath string Absolute or buffer-descriptive file path
--- @field relpath string Workspace-relative file path

local function to_relpath(filepath)
	if not filepath or filepath == "" then
		return "[Unnamed Buffer]"
	end
	local rel = vim.fn.fnamemodify(filepath, ":.")
	return rel ~= "" and rel or filepath
end

--- Converts a glob pattern (`*`, `**`, `?`) into an anchored Lua pattern (Neovim 0.10+ compatible).
--- @param glob string
--- @return string
local function glob_to_lua_pattern(glob)
	local out = { "^" }
	local i = 1
	local len = #glob
	while i <= len do
		local ch = glob:sub(i, i)
		if ch == "*" then
			if glob:sub(i, i + 2) == "**/" then
				table.insert(out, ".*")
				i = i + 3
			elseif glob:sub(i + 1, i + 1) == "*" then
				table.insert(out, ".*")
				i = i + 2
			else
				table.insert(out, "[^/]*")
				i = i + 1
			end
		elseif ch == "?" then
			table.insert(out, "[^/]")
			i = i + 1
		else
			table.insert(out, vim.pesc(ch))
			i = i + 1
		end
	end
	table.insert(out, "$")
	return table.concat(out)
end

--- Merges default `constants.IGNORED_DIRS` with user-supplied `extra_ignored` patterns.
--- @param extra_ignored string[]|nil
--- @return string[] ordered_list, table<string, boolean> lookup_map, { pattern: string, has_slash: boolean }[] compiled_globs
local function build_ignored_rules(extra_ignored)
	local list = {}
	local map = {}
	local globs = {}

	local function add_entry(item)
		if type(item) ~= "string" then
			return
		end
		local clean = vim.trim(item):gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
		if clean ~= "" and not map[clean] then
			map[clean] = true
			table.insert(list, clean)
			if clean:find("[*%?]") then
				table.insert(globs, {
					pattern = glob_to_lua_pattern(clean),
					has_slash = clean:find("/", 1, true) ~= nil,
				})
			end
		end
	end

	for _, d in ipairs(constants.IGNORED_DIRS) do
		add_entry(d)
	end

	if type(extra_ignored) == "table" then
		for _, d in ipairs(extra_ignored) do
			add_entry(d)
		end
	end

	return list, map, globs
end

--- Checks whether a workspace-relative path matches any ignored directory, literal prefix, or glob pattern.
--- @param relpath string
--- @param ignored_list string[]
--- @param ignored_map table<string, boolean>
--- @param compiled_globs { pattern: string, has_slash: boolean }[]|nil
--- @return boolean
local function is_path_ignored(relpath, ignored_list, ignored_map, compiled_globs)
	if not relpath or relpath == "" or relpath:match("^%[") then
		return false
	end
	local normalized = relpath:gsub("\\", "/"):gsub("^%./", "")

	for segment in normalized:gmatch("[^/]+") do
		if ignored_map[segment] then
			return true
		end
	end

	for _, pat in ipairs(ignored_list) do
		if not pat:find("[*%?]") then
			if normalized == pat or normalized:find("^" .. vim.pesc(pat) .. "/") then
				return true
			end
		end
	end

	if compiled_globs then
		local basename = vim.fs.basename(normalized)
		for _, g in ipairs(compiled_globs) do
			if g.has_slash then
				if normalized:match(g.pattern) then
					return true
				end
			else
				if basename:match(g.pattern) or normalized:match(g.pattern) then
					return true
				end
			end
		end
	end

	return false
end

--- Parses an array of text lines from either a standalone `.mmd` file or a Markdown document.
--- @param lines string[]
--- @param filepath string
--- @param ext string Lowercase file extension
--- @param ft string Buffer filetype
--- @return MermaidDiagramEntry[]
local function parse_lines(lines, filepath, ext, ft)
	local full_code = table.concat(lines, "\n")
	local filename = filepath ~= "" and vim.fn.fnamemodify(filepath, ":t") or "[Buffer]"
	local relpath = to_relpath(filepath)

	local is_mmd_file = (ext == "mmd" or ext == "mermaid" or ft == "mermaid")
	local is_markdown_file = (ext == "md" or ext == "markdown" or ext == "mdx" or ft == "markdown" or ft == "mdx")
	local has_fence = full_code:find("```", 1, true) ~= nil or full_code:find("~~~", 1, true) ~= nil

	if is_mmd_file or (not is_markdown_file and not has_fence and detector.detect_diagram_type(full_code) ~= nil) then
		if vim.trim(full_code) == "" then
			return {}
		end
		local dtype = detector.detect_diagram_type(full_code) or "mermaid"
		return {
			{
				kind = "file",
				name = filename,
				filename = filename,
				diagram_type = dtype,
				has_custom_name = true,
				code = full_code,
				lnum = 1,
				end_lnum = #lines,
				filepath = filepath ~= "" and filepath or "[Buffer .mmd]",
				relpath = relpath,
			},
		}
	end

	local raw_blocks = detector.scan_fenced_blocks(lines)
	local unnamed_counts = {}
	for _, b in ipairs(raw_blocks) do
		if not b.explicit_name then
			unnamed_counts[b.diagram_type] = (unnamed_counts[b.diagram_type] or 0) + 1
		end
	end

	local seen_unnamed = {}
	local diagrams = {}

	for _, b in ipairs(raw_blocks) do
		local final_name
		local has_custom = false

		if b.explicit_name then
			final_name = b.explicit_name
			has_custom = true
		else
			local dtype = b.diagram_type
			if (unnamed_counts[dtype] or 0) > 1 then
				seen_unnamed[dtype] = (seen_unnamed[dtype] or 0) + 1
				final_name = string.format("%s #%d", dtype, seen_unnamed[dtype])
			else
				final_name = dtype
			end
		end

		table.insert(diagrams, {
			kind = "block",
			name = final_name,
			filename = filename,
			diagram_type = b.diagram_type,
			has_custom_name = has_custom,
			code = b.code,
			lnum = b.open_lnum,
			end_lnum = b.close_lnum,
			filepath = filepath ~= "" and filepath or "[Unnamed Buffer]",
			relpath = relpath,
		})
	end

	return diagrams
end

--- Extracts all Mermaid diagrams present in the specified Neovim buffer.
--- @param bufnr integer|nil Defaults to current buffer (`0`)
--- @return MermaidDiagramEntry[]
function M.get_buffer_diagrams(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local ft = vim.bo[bufnr].filetype or ""
	local ext = vim.fn.fnamemodify(filepath, ":e"):lower()

	return parse_lines(lines, filepath, ext, ft)
end

--- Returns the Mermaid diagram enclosing the cursor, or the first diagram in the buffer.
--- @param bufnr integer|nil Defaults to current buffer (`0`)
--- @return MermaidDiagramEntry|nil
function M.get_diagram_under_cursor(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local diagrams = M.get_buffer_diagrams(bufnr)

	for _, d in ipairs(diagrams) do
		if cursor_line >= d.lnum and cursor_line <= d.end_lnum then
			return d
		end
	end
	return diagrams[1]
end

--- Discovers all Markdown and Mermaid files in the workspace using `rg` or `vim.uv.fs_scandir`.
--- @param root string Workspace root directory path
--- @param ignored_list string[]
--- @param ignored_map table<string, boolean>
--- @param compiled_globs { pattern: string, has_slash: boolean }[]
--- @param respect_gitignore boolean
--- @return string[]
local function list_project_files(root, ignored_list, ignored_map, compiled_globs, respect_gitignore)
	if vim.fn.executable("rg") == 1 then
		local cmd = { "rg", "--files" }
		if not respect_gitignore then
			table.insert(cmd, "--hidden")
			table.insert(cmd, "--no-ignore")
		end
		for _, glob in ipairs(constants.RG_FILE_GLOBS) do
			table.insert(cmd, "--type-add")
			table.insert(cmd, "mlens:" .. glob)
		end
		table.insert(cmd, "-t")
		table.insert(cmd, "mlens")

		for _, pattern in ipairs(ignored_list) do
			if pattern:find("[*%?]") then
				table.insert(cmd, "-g")
				table.insert(cmd, "!" .. pattern)
			else
				table.insert(cmd, "-g")
				table.insert(cmd, "!**/" .. pattern .. "/**")
				table.insert(cmd, "-g")
				table.insert(cmd, "!" .. pattern .. "/**")
			end
		end

		table.insert(cmd, root)

		local out = vim.fn.systemlist(cmd)
		if vim.v.shell_error == 0 and type(out) == "table" then
			return out
		end
	end

	local results = {}
	local function scan_dir(dir)
		local handle = vim.uv.fs_scandir(dir)
		if not handle then
			return
		end
		while true do
			local name, ftype = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if not (respect_gitignore and name:sub(1, 1) == ".") then
				local full_path = dir .. "/" .. name
				local rel = to_relpath(full_path)

				if not ignored_map[name] and not is_path_ignored(rel, ignored_list, ignored_map, compiled_globs) then
					if ftype == "directory" then
						scan_dir(full_path)
					elseif ftype == "file" then
						local ext = (name:match("%.([^%.]+)$") or ""):lower()
						if constants.SUPPORTED_EXTENSIONS[ext] then
							table.insert(results, full_path)
						end
					end
				end
			end
		end
	end

	scan_dir(root)
	return results
end

--- Scans the entire project workspace and returns all Mermaid diagrams sorted by path and line.
--- @param opts { ignored_dirs?: string[], respect_gitignore?: boolean, root?: string }|nil
--- @return MermaidDiagramEntry[]
function M.get_project_diagrams(opts)
	opts = opts or {}
	local cfg = config_state.get()
	local respect_gitignore = opts.respect_gitignore
	if respect_gitignore == nil then
		respect_gitignore = cfg.respect_gitignore ~= false
	end

	local ignored_list, ignored_map, compiled_globs = build_ignored_rules(opts.ignored_dirs)
	local root = opts.root or vim.fn.getcwd()
	local files = list_project_files(root, ignored_list, ignored_map, compiled_globs, respect_gitignore)
	local all_diagrams = {}
	local loaded_buffers_by_path = {}
	local max_file_bytes = constants.LIMITS.MAX_SCAN_FILE_BYTES

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local bname = vim.api.nvim_buf_get_name(bufnr)
			if bname ~= "" then
				loaded_buffers_by_path[vim.fn.fnamemodify(bname, ":p")] = bufnr
			end
		end
	end

	local visited_paths = {}

	for _, file in ipairs(files) do
		local abs_path = vim.fn.fnamemodify(file, ":p")
		local rel = to_relpath(abs_path)

		if not is_path_ignored(rel, ignored_list, ignored_map, compiled_globs) then
			visited_paths[abs_path] = true

			local diags
			if loaded_buffers_by_path[abs_path] then
				diags = M.get_buffer_diagrams(loaded_buffers_by_path[abs_path])
			else
				local st = vim.uv.fs_stat(abs_path)
				if st and st.type == "file" and (st.size or 0) <= max_file_bytes then
					local ok, lines = pcall(vim.fn.readfile, abs_path)
					if ok and type(lines) == "table" then
						local ext = vim.fn.fnamemodify(abs_path, ":e"):lower()
						diags = parse_lines(lines, abs_path, ext, "")
					end
				end
			end

			if diags then
				for _, d in ipairs(diags) do
					table.insert(all_diagrams, d)
				end
			end
		end
	end

	local cur_buf = vim.api.nvim_get_current_buf()
	local cur_path = vim.api.nvim_buf_get_name(cur_buf)
	local abs_cur = cur_path ~= "" and vim.fn.fnamemodify(cur_path, ":p") or ""
	local rel_cur = to_relpath(abs_cur)

	if
		(abs_cur == "" or not visited_paths[abs_cur])
		and not is_path_ignored(rel_cur, ignored_list, ignored_map, compiled_globs)
	then
		for _, d in ipairs(M.get_buffer_diagrams(cur_buf)) do
			table.insert(all_diagrams, d)
		end
	end

	table.sort(all_diagrams, function(a, b)
		if a.relpath ~= b.relpath then
			return a.relpath < b.relpath
		end
		return (a.lnum or 1) < (b.lnum or 1)
	end)

	return all_diagrams
end

return M
