--- @module mermaid_lens.ui.picker
--- Architectural Layer: Interface Adapter / View
--- Parent: `mermaid_lens.init` and `telescope._extensions.mermaid_lens`
--- Children: `mermaid_lens.parser.scanner`, `mermaid_lens.renderer.compiler`,
---           `mermaid_lens.renderer.ascii`, `mermaid_lens.ui.modal`
--- Single Responsibility: Provide a Telescope picker that lists all project Mermaid
--- diagrams with middle-truncated names and left-truncated file locations.

local has_telescope, _ = pcall(require, "telescope")
if not has_telescope then
	return {}
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")
local entry_display = require("telescope.pickers.entry_display")

local scanner = require("mermaid_lens.parser.scanner")
local compiler = require("mermaid_lens.renderer.compiler")
local ascii = require("mermaid_lens.renderer.ascii")
local modal = require("mermaid_lens.ui.modal")

local M = {}

local function truncate_middle(str, max_len)
	local len = vim.fn.strdisplaywidth(str)
	if len <= max_len then
		return str
	end
	if max_len <= 5 then
		return vim.fn.strcharpart(str, 0, max_len)
	end
	local head_len = math.ceil((max_len - 1) * 0.55)
	local tail_len = (max_len - 1) - head_len
	local total_chars = vim.fn.strchars(str)
	local head = vim.fn.strcharpart(str, 0, head_len)
	local tail = vim.fn.strcharpart(str, total_chars - tail_len, tail_len)
	return head .. "…" .. tail
end

local function format_name_column(d, max_len)
	if d.kind == "file" then
		local suffix = string.format(" <%s>", d.diagram_type or "mermaid")
		local full = d.filename .. suffix
		if vim.fn.strdisplaywidth(full) <= max_len then
			return full
		end
		local avail_for_name = math.max(8, max_len - vim.fn.strdisplaywidth(suffix))
		return truncate_middle(d.filename, avail_for_name) .. suffix
	else
		return truncate_middle(d.name or "mermaid", max_len)
	end
end

local function format_location_tail(location, max_len)
	local len = vim.fn.strdisplaywidth(location)
	if len <= max_len then
		return location
	end
	if max_len <= 6 then
		return "…"
	end

	local total_chars = vim.fn.strchars(location)
	local keep = max_len - 1
	local tail = vim.fn.strcharpart(location, total_chars - keep, keep)

	local slash_pos = tail:find("/")
	if slash_pos and slash_pos <= 10 and #tail - slash_pos >= 8 then
		tail = tail:sub(slash_pos)
	end

	return "…" .. tail
end

local function compute_column_widths()
	local total_cols = vim.o.columns
	local picker_w = math.floor(total_cols * 0.94)
	local preview_w = math.floor(picker_w * 0.40)
	local results_inner_w = math.max(50, picker_w - preview_w - 6)

	local usable = math.max(36, results_inner_w - 15)
	local name_w = math.max(28, math.min(44, math.floor(usable * 0.46)))
	local path_w = math.max(20, usable - name_w)

	return name_w, path_w
end

--- Opens the project-wide Mermaid diagram Telescope picker.
--- @param opts table|nil Telescope picker options
function M.find(opts)
	opts = opts or {}
	local diagrams = scanner.get_project_diagrams()

	if #diagrams == 0 then
		vim.notify("MermaidLens: No Mermaid diagrams found in the current workspace.", vim.log.levels.WARN)
		return
	end

	local name_w, path_w = compute_column_widths()

	local displayer = entry_display.create({
		separator = " │ ",
		items = {
			{ width = 7 },
			{ width = name_w },
			{ width = path_w },
		},
	})

	local function make_display(entry)
		local d = entry.value
		local formatted_name = format_name_column(d, name_w)

		if d.kind == "file" then
			local formatted_loc = format_location_tail(d.relpath, path_w)
			return displayer({
				{ "[File]", "TelescopeResultsConstant" },
				{ formatted_name, "TelescopeResultsIdentifier" },
				{ formatted_loc, "TelescopeResultsComment" },
			})
		else
			local raw_loc = string.format("%s:%d", d.relpath, d.lnum or 1)
			local formatted_loc = format_location_tail(raw_loc, path_w)
			return displayer({
				{ "[Block]", "TelescopeResultsFunction" },
				{ formatted_name, "TelescopeResultsIdentifier" },
				{ formatted_loc, "TelescopeResultsComment" },
			})
		end
	end

	pickers
		.new(opts, {
			prompt_title = "Mermaid Lens (Enter: Preview Modal | <C-g>: Jump to Source)",
			layout_strategy = "horizontal",
			layout_config = {
				horizontal = {
					width = 0.94,
					height = 0.88,
					preview_width = 0.40,
				},
			},
			finder = finders.new_table({
				results = diagrams,
				entry_maker = function(entry)
					local location = entry.kind == "file" and entry.relpath
						or string.format("%s:%d", entry.relpath, entry.lnum or 1)

					local search_key = string.format(
						"%s %s %s %s %s",
						entry.kind,
						entry.name or "",
						entry.filename or "",
						entry.diagram_type or "",
						location
					)

					return {
						value = entry,
						display = make_display,
						ordinal = search_key,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "Mermaid Source",
				dyn_title = function(_, entry)
					local d = entry.value
					if d.kind == "file" then
						return string.format(" %s <%s> — %s ", d.filename, d.diagram_type or "mermaid", d.relpath)
					end
					return string.format(" %s — %s:%d ", d.name, d.relpath, d.lnum or 1)
				end,
				define_preview = function(self, entry)
					local d = entry.value
					local full_loc = d.kind == "file" and d.relpath or string.format("%s:%d", d.relpath, d.lnum or 1)
					local header = {
						string.format("%%%% Name: %s  |  Type: %s", d.name or d.filename, d.diagram_type or "mermaid"),
						string.format("%%%% Location: %s", full_loc),
						"",
					}
					local code_lines = vim.split(d.code or "", "\n", { plain = true })
					local lines = vim.list_extend(header, code_lines)

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "mermaid"
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection and selection.value then
						local ml = require("mermaid_lens")
						local cfg = ml.config or {}
						local theme = cfg.theme or "light"
						compiler.compile(selection.value, { theme = theme }, function(artifact)
							modal.open(artifact, {
								theme = theme,
								backdrop = cfg.backdrop,
								backdrop_blend = cfg.backdrop_blend,
								diagram = selection.value,
							})
						end)
					end
				end)

				local function jump_to_source()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection and selection.value and selection.value.filepath then
						vim.cmd("edit " .. vim.fn.fnameescape(selection.value.filepath))
						vim.api.nvim_win_set_cursor(0, { selection.value.lnum or 1, 0 })
						vim.cmd("normal! zz")
					end
				end

				map("i", "<C-g>", jump_to_source)
				map("n", "<C-g>", jump_to_source)
				map("i", "<C-a>", ascii.notify_coming_soon)
				map("n", "<C-a>", ascii.notify_coming_soon)

				return true
			end,
		})
		:find()
end

return M
