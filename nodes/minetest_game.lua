-- Node registrations for Minetest Game (the default Luanti game).
-- Game-specific node knowledge belongs here, not in api.lua: the
-- engine core only operates on nodes registered by category (e.g.
-- "openable"), and each game's mods register their own nodes in
-- their own file under nodes/.

-- Beds ("beds" mod)
if minetest.get_modpath("beds") then
npc.env.register_node("beds:bed_bottom", 
	{"bed"},
	{},
	function(self, args)
		local pos = args.pos
		local node = minetest.get_node_or_nil(pos)
		if (not node) then return end
		local dir = minetest.facedir_to_dir(node.param2)
		-- Calculate bed_pos
		local bed_pos = {
			x = pos.x + dir.x / 2,
			y = pos.y,
			z = pos.z + dir.z / 2
		}
		-- Move to position
		self.object:move_to(bed_pos)
		self.object:set_yaw(minetest.dir_to_yaw(minetest.facedir_to_dir((node.param2 + 2) % 4)))
		-- Set animation
		npc.model.set_animation(self, {name = "lay"})
	end)
end

-- Doors ("doors" mod)
--
-- The doors mod registers every door type as four variants and
-- toggles them by swapping the variant name (doors.door_toggle):
--   _a, _b : closed (left- / right-hinged)
--   _c, _d : open
-- All variants share the same on_rightclick, so one generic
-- operation can operate any variant of any door type.
if minetest.get_modpath("doors") then
	-- The door types registered by Minetest Game's doors mod.
	local door_bases = {
		"doors:door_wood",
		"doors:door_steel",
	}

	-- Whether the door at args.pos is open: the doors mod encodes
	-- it in the node name suffix (_a/_b closed, _c/_d open).
	local function door_is_open(self, args)
		local node = minetest.get_node_or_nil(args.pos)
		if node == nil then return nil end
		local suffix = node.name:sub(-2)
		return (suffix == "_c" or suffix == "_d")
	end

	-- Operate the door at args.pos: call the node's own
	-- on_rightclick (doors.door_toggle by default) with the NPC as
	-- the clicker.
	local function door_operate(self, args)
		local node = minetest.get_node_or_nil(args.pos)
		if node == nil then return end
		local def = minetest.registered_nodes[node.name]
		if def == nil or def.on_rightclick == nil then return end
		local clicker = self
		clicker.is_player = function() return true end
		clicker.get_player_name = function() return "npc" end
		def.on_rightclick(args.pos, node, clicker, nil, nil)
	end

	for _, base in ipairs(door_bases) do
		for _, suffix in ipairs({ "_a", "_b", "_c", "_d" }) do
			npc.env.register_node(base .. suffix,
				{"openable", "doors"},
				{ is_open = door_is_open },
				door_operate)
		end
	end
end
