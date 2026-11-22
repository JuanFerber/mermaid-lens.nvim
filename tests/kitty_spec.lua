local T = _G.TestHarness
local kitty = require("mermaid_lens.graphics.kitty")
local terminal = require("mermaid_lens.env.terminal")
local multiplexer = require("mermaid_lens.env.multiplexer")

T.test("kitty emits zero APC escape sequences in headless mode", function()
	local sent = {}
	local orig_chan_send = vim.api.nvim_chan_send

	local ok, err = pcall(function()
		vim.api.nvim_chan_send = function(_, data)
			table.insert(sent, data)
		end

		kitty.transmit_file(9001, "/tmp/headless.png")
		kitty.place_viewport({
			img_id = 9001,
			x = 0,
			y = 0,
			w = 100,
			h = 100,
			cols = 10,
			rows = 5,
			screen_row = 2,
			screen_col = 2,
		})
		kitty.clear_all_placements()
		kitty.delete_image(9001)
		kitty.delete_all_owned_images()

		T.assert_eq(#sent, 0)
		T.assert_eq(kitty.get_owned_image_ids(), {})
	end)

	vim.api.nvim_chan_send = orig_chan_send
	if not ok then
		error(err, 0)
	end
end)

T.test("kitty scopes clear_all_placements (d=i) and delete_all_owned_images (d=I) strictly to owned IDs", function()
	local sent = {}
	local orig_chan_send = vim.api.nvim_chan_send
	local orig_list_uis = vim.api.nvim_list_uis
	local orig_supports = terminal.supports_kitty_graphics
	local orig_ensure = multiplexer.ensure_configured
	local orig_wrap = multiplexer.wrap_passthrough

	local ok, err = pcall(function()
		vim.api.nvim_list_uis = function()
			return { { width = 120, height = 40 } }
		end
		terminal.supports_kitty_graphics = function()
			return true
		end
		multiplexer.ensure_configured = function() end
		multiplexer.wrap_passthrough = function(seq)
			return seq
		end
		vim.api.nvim_chan_send = function(_, data)
			table.insert(sent, data)
		end

		kitty.delete_all_owned_images()
		sent = {}

		kitty.transmit_file(101, "/tmp/a.png")
		kitty.transmit_file(102, "/tmp/b.png")
		T.assert_eq(kitty.get_owned_image_ids(), { 101, 102 })

		sent = {}
		kitty.clear_all_placements()
		T.assert_eq(#sent, 2)
		local joined_clear = table.concat(sent, "\n")
		T.assert_true(joined_clear:find("d=i", 1, true) ~= nil, "Expected scoped d=i placement clear")
		T.assert_nil(joined_clear:find("d=a", 1, true), "Must never emit global d=a clear")
		T.assert_nil(joined_clear:find("d=A", 1, true), "Must never emit global d=A delete")
		T.assert_eq(kitty.get_owned_image_ids(), { 101, 102 })

		sent = {}
		kitty.delete_image(101)
		T.assert_eq(#sent, 1)
		T.assert_true(sent[1]:find("d=I", 1, true) ~= nil and sent[1]:find("i=101", 1, true) ~= nil)
		T.assert_eq(kitty.get_owned_image_ids(), { 102 })

		sent = {}
		kitty.delete_all_owned_images()
		T.assert_eq(#sent, 1)
		T.assert_true(sent[1]:find("d=I", 1, true) ~= nil and sent[1]:find("i=102", 1, true) ~= nil)
		T.assert_eq(kitty.get_owned_image_ids(), {})
	end)

	vim.api.nvim_chan_send = orig_chan_send
	vim.api.nvim_list_uis = orig_list_uis
	terminal.supports_kitty_graphics = orig_supports
	multiplexer.ensure_configured = orig_ensure
	multiplexer.wrap_passthrough = orig_wrap
	if not ok then
		error(err, 0)
	end
end)
