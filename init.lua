npc = {
	model    = {},
	proc     = {},
	env      = {},
	schedule = {}
}

local path = minetest.get_modpath("anpc")
dofile(path .. "/api.lua")
dofile(path .. "/pathfinder.lua")
dofile(path .. "/vegetarian.lua")
