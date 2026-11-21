--- @module mermaid_lens.graphics.kitty
--- Architectural Layer: Infrastructure / Interface Adapter
--- Parent: `mermaid_lens.ui.modal`, `mermaid_lens.ui.loader`, and `mermaid_lens.init`
--- Children: `mermaid_lens.env.multiplexer`, `mermaid_lens.env.terminal`
--- Single Responsibility: Encode and transmit Kitty Graphics Protocol APC escape
--- sequences with atomic cursor preservation (`DECSC`/`DECRC` + `C=1`) and
--- plugin-owned texture lifecycle tracking.

local multiplexer = require("mermaid_lens.env.multiplexer")
local terminal = require("mermaid_lens.env.terminal")

local M = {}

--- Registry of GPU texture IDs transmitted by this plugin instance (`img_id -> true`).
--- @type table<integer, boolean>
local owned_ids = {}

--- @class KittyViewportPlacement
--- @field img_id integer Unique texture identifier in GPU memory
--- @field x integer Source crop top-left X coordinate in pixels
--- @field y integer Source crop top-left Y coordinate in pixels
--- @field w integer Source crop width in pixels
--- @field h integer Source crop height in pixels
--- @field cols integer Destination width in terminal character cells
--- @field rows integer Destination height in terminal character cells
--- @field screen_row integer 1-based absolute terminal row
--- @field screen_col integer 1-based absolute terminal column

--- Returns whether emitting Kitty APC escape sequences is safe in the current session.
--- Blocks output in headless mode (`#nvim_list_uis() == 0`) and on unsupported terminals.
--- @return boolean
local function can_emit()
	return #vim.api.nvim_list_uis() > 0 and terminal.supports_kitty_graphics()
end

local function build_apc(params, payload)
	local parts = {}
	for k, v in pairs(params) do
		table.insert(parts, string.format("%s=%s", k, tostring(v)))
	end
	local header = table.concat(parts, ",")
	return string.format("\x1b_G%s;%s\x1b\\", header, payload or "")
end

--- Sends a single Kitty APC command wrapped for the active multiplexer.
--- No-op when headless or when the host terminal does not support Kitty graphics.
--- @param params table<string, string|number>
--- @param payload string|nil
function M.send(params, payload)
	if not can_emit() then
		return
	end
	local seq = multiplexer.wrap_passthrough(build_apc(params, payload))
	vim.api.nvim_chan_send(vim.v.stderr, seq)
end

--- Uploads a local PNG file to Kitty's GPU texture slot `img_id` and tracks ownership.
--- @param img_id integer
--- @param png_path string
function M.transmit_file(img_id, png_path)
	if not can_emit() then
		return
	end
	multiplexer.ensure_configured()
	owned_ids[img_id] = true
	local b64_path = vim.base64.encode(png_path)
	M.send({ a = "t", f = 100, t = "f", i = img_id, q = 2 }, b64_path)
end

--- Renders a cropped rectangular region of texture `img_id` at exact screen coordinates.
--- Saves and restores the cursor (`\x1b7` / `\x1b8`) inside the passthrough envelope
--- and sets `C=1` so Kitty never mutates Neovim's physical cursor position.
--- @param opts KittyViewportPlacement
function M.place_viewport(opts)
	if not can_emit() then
		return
	end
	local apc = build_apc({
		a = "p",
		i = opts.img_id,
		p = 1,
		C = 1,
		x = opts.x,
		y = opts.y,
		w = opts.w,
		h = opts.h,
		c = opts.cols,
		r = opts.rows,
		q = 2,
	})

	local raw_seq = string.format("\x1b7\x1b[%d;%dH%s\x1b8", opts.screen_row, opts.screen_col, apc)
	vim.api.nvim_chan_send(vim.v.stderr, multiplexer.wrap_passthrough(raw_seq))
end

--- Hides all visible screen placements owned by this plugin without freeing GPU memory
--- and without affecting textures belonging to other plugins or terminal programs.
function M.clear_all_placements()
	for img_id in pairs(owned_ids) do
		M.send({ a = "d", d = "i", i = img_id, q = 2 })
	end
end

--- Deletes texture `img_id` completely from GPU memory and unregisters ownership.
--- @param img_id integer
function M.delete_image(img_id)
	if not img_id then
		return
	end
	owned_ids[img_id] = nil
	M.send({ a = "d", d = "I", i = img_id, q = 2 })
end

--- Deletes every GPU texture owned by this plugin and clears the ownership registry.
function M.delete_all_owned_images()
	local ids = {}
	for img_id in pairs(owned_ids) do
		table.insert(ids, img_id)
	end
	owned_ids = {}
	for _, img_id in ipairs(ids) do
		M.send({ a = "d", d = "I", i = img_id, q = 2 })
	end
end

--- Returns a sorted snapshot of currently registered plugin-owned GPU texture IDs.
--- @return integer[]
function M.get_owned_image_ids()
	local ids = {}
	for img_id in pairs(owned_ids) do
		table.insert(ids, img_id)
	end
	table.sort(ids)
	return ids
end

return M
