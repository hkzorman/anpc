npc = {
	model    = {},
	proc     = {},
	env      = {},
	schedule = {}
}

local path = minetest.get_modpath("anpc")
dofile(path .. "/api.lua")
dofile(path .. "/pathfinder.lua")
dofile(path .. "/builtin.lua")
-- Test/utility NPCs and debug items (chest mover, torcherer,
-- vegetarian, test craft items) were moved to
-- anpc-dev/test_utilities/ (loaded by anpc-dev/init.lua).
-- Game-specific node registrations (nodes of the game's own mods).
dofile(path .. "/nodes/minetest_game.lua")
