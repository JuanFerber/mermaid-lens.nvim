local T = _G.TestHarness
local viewport = require("mermaid_lens.graphics.viewport")

T.test("viewport.map_to_texture maps full overview coordinates proportionally", function()
	local vp = {
		src_x = 300,
		src_y = 2000,
		src_w = 600,
		src_h = 4000,
	}
	local tex_rect = {
		x = 0,
		y = 0,
		w = 1200,
		h = 10000,
		raster_w = 600,
		raster_h = 5000,
	}

	local mapped = viewport.map_to_texture(vp, tex_rect)
	T.assert_eq(mapped.x, 150, "Expected scaled X offset in overview raster")
	T.assert_eq(mapped.y, 1000, "Expected scaled Y offset in overview raster")
	T.assert_eq(mapped.w, 300, "Expected scaled width in overview raster")
	T.assert_eq(mapped.h, 2000, "Expected scaled height in overview raster")
end)

T.test("viewport.map_to_texture maps exact 1:1 zoomed viewBox tile to full texture bounds", function()
	local vp = {
		src_x = 420,
		src_y = 3150,
		src_w = 350,
		src_h = 220,
	}
	local tex_rect = {
		x = 420,
		y = 3150,
		w = 350,
		h = 220,
		raster_w = 1400,
		raster_h = 880,
	}

	local mapped = viewport.map_to_texture(vp, tex_rect)
	T.assert_eq(mapped.x, 0, "Expected tile X origin at 0")
	T.assert_eq(mapped.y, 0, "Expected tile Y origin at 0")
	T.assert_eq(mapped.w, 1400, "Expected full modal raster width")
	T.assert_eq(mapped.h, 880, "Expected full modal raster height")
end)

T.test("viewport.is_contained_in_texture detects when panning leaves the zoomed tile", function()
	local tile_rect = {
		x = 400,
		y = 1000,
		w = 300,
		h = 200,
		raster_w = 1200,
		raster_h = 800,
	}

	local inside_vp = { src_x = 400, src_y = 1000, src_w = 300, src_h = 200 }
	T.assert_true(
		viewport.is_contained_in_texture(inside_vp, tile_rect),
		"Expected exact camera match to be contained in tile"
	)

	local panned_vp = { src_x = 400, src_y = 1050, src_w = 300, src_h = 200 }
	T.assert_false(
		viewport.is_contained_in_texture(panned_vp, tile_rect),
		"Expected panned camera exceeding bottom edge to fall back to overview texture"
	)
end)
