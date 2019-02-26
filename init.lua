
-- Zombie by BlockMen

mobs:register_mob("zombie2:zombie", {
	type = "monster",
	passive = false,
	attack_type = "dogfight",
	damage = 4,
	hp_min = 12,
	hp_max = 35,
	armor = 150,
	collisionbox = {-0.25, -1, -0.3, 0.25, 0.75, 0.3},
	visual = "mesh",
	mesh = "creatures_mob.x",
	textures = {
		{"mobs_zombie.png"},
	},
	visual_size = {x=1, y=1},
	makes_footstep_sound = true,
	sounds = {
		random = "mobs_zombie.1",
		damage = "mobs_zombie_hit",
		attack = "mobs_zombie.3",
		death = "mobs_zombie_death",
	},
	walk_velocity = 0.5,
	run_velocity = 1.75,
	jump = true,
	floats = 0,
	view_range = 12,
	drops = {
		{name = "zombie:rotten_flesh",
		chance = 2, min = 3, max = 5,},
	},
	water_damage = 0,
	lava_damage = 1,
	light_damage = 0,
	animation = {
		speed_normal = 10,		speed_run = 15,
		stand_start = 0,		stand_end = 79,
		walk_start = 168,		walk_end = 188,
		run_start = 168,		run_end = 188,
--		punch_start = 168,		punch_end = 188,
	},
	on_rightclick = function(self, clicker)
		minetest.log(dump(self))
	end,
	on_die = function(self, pos)
		local meta = minetest.get_meta(self.spawn.pos)
		meta:set_int("entity_killed_count", meta:get_int("entity_killed_count") + 1)
	end
})

--name, nodes, neighbours, minlight, maxlight, interval, chance, active_object_count, min_height, max_height
-- mobs:spawn({
-- 	name = "zombie:zombie",
-- 	nodes = {"default:dirt_with_grass"},
-- 	min_light = 0,
-- 	max_light = 7,
-- 	chance = 9000,
-- 	active_object_count = 2,
-- 	min_height = 0,
-- 	day_toggle = false,
-- })

local min_player_distance = 5 --20
local max_mob_count = 5 --15
local max_spawn_interval = 10 --300
local min_spawn_interval = 5 --120
local spawn_radius = 5
local min_kill_count = 5
local max_kill_count = 10
local min_deactivation_time = 5
local max_deactivation_time = 5
local spawner_textures = {"wool_red.png"}
local spawn_on_dig = true

local function spawn(pos, entity_name, force)
	-- Check for players nearby
	local objects = minetest.get_objects_inside_radius(pos, min_player_distance)
	local timer = minetest.get_node_timer(pos)
	local interval = math.random(min_spawn_interval, max_spawn_interval)

	local entity_count = 0
	for _,object in pairs(objects) do
		if object and object:is_player() and not force then
			minetest.log("Player too close")
			-- Re-schedule
			timer:start(interval)
			minetest.log("Next spawning scheduled in "..interval.." seconds")
			return
		end
	end

	local meta = minetest.get_meta(pos)
	local entity_spawn_count = meta:get_int("entity_spawn_count")

	-- Check for amount nearby
	if force or (entity_spawn_count <= max_mob_count) then
		-- Spawn
		local spawn_pos = {x=pos.x + math.random(0, spawn_radius), y=pos.y+1, z=pos.z + math.random(0, spawn_radius)}
		-- Check spawn position - if not air, then spawn just above the spawner
		local spawn_node = minetest.get_node_or_nil(spawn_pos)
		if spawn_node and spawn_node.name ~= "air" then
			spawn_pos = pos
		end
		minetest.log("Spawning "..entity_name.." at pos "..minetest.pos_to_string(spawn_pos))
		local entity = minetest.add_entity(spawn_pos, entity_name)
		if entity then
			entity:get_luaentity().entity_name = entity_name
			entity:get_luaentity().spawn = {
				pos = pos
			}
		end
	else
		minetest.log("Max spawn limit reached")
	end

	-- Re-schedule
	timer:start(interval)
	minetest.log("Next spawning scheduled in "..interval.." seconds")
end

minetest.register_node("zombie2:zombie_spawner", {
	description = "Zombie Spawner",
	drop = "zombie2:zombie_spawner",
	tiles = {"wool_red.png"},
	groups = {crumbly=2, soil = 2},
	sounds = default.node_sound_sand_defaults(),
	on_construct = function(pos)
		local meta = minetest.get_meta(pos)
		meta:set_int("entity_spawn_count", 0)
		meta:set_int("entity_killed_count", 0)
		meta:set_int("next_deactivation_count", math.random(min_kill_count, max_kill_count))
		meta:set_int("next_deactivation_time", math.random(min_deactivation_time, max_deactivation_time))

		local timer = minetest.get_node_timer(pos)
		timer:start(min_spawn_interval)
	end,
	on_timer = function(pos)
		spawn(pos, "zombie2:zombie")
	end,
	on_dig = function(pos, node, digger)
		local meta = minetest.get_meta(pos)
		local entity_killed_count = meta:get_int("entity_killed_count")
		local next_deactivation_count = meta:get_int("next_deactivation_count")
		if (entity_killed_count < next_deactivation_count) then
			if spawn_on_dig then
				spawn(pos, "zombie2:zombie", true)
			end
			minetest.chat_send_player(digger:get_player_name(), "You have killed "..entity_killed_count.." enemies!")
			return false
		else
			minetest.node_dig(pos, node, digger)
		end
	end
})

local perl1 = {SEED1 = 9130, OCTA1 = 3,	PERS1 = 0.5, SCAL1 = 250} -- Values should match minetest mapgen V6 desert noise.

local function hlp_fnct(pos, name)
	local n = minetest.get_node_or_nil(pos)
	if n and n.name and n.name == name then
		return true
	else
		return false
	end
end
local function ground(pos, old)
	local p2 = pos
	while hlp_fnct(p2, "air") do
		p2.y = p2.y -1
	end
	if p2.y < old.y then
		return p2
	else
		return old
	end
end

minetest.register_on_generated(function(minp, maxp, seed)

	-- Chance check
	if math.random(0,10) > 7 then return end

	if maxp.y < 0 then return end
	math.randomseed(seed)
	local cnt = 0

	local perlin1 = minetest.env:get_perlin(perl1.SEED1, perl1.OCTA1, perl1.PERS1, perl1.SCAL1)
	local noise1 = perlin1:get2d({x=minp.x,y=minp.y})--,z=minp.z})

	if noise1 > 0.25 or noise1 < -0.26 then
	 local mpos = {x=math.random(minp.x,maxp.x), y=math.random(minp.y,maxp.y), z=math.random(minp.z,maxp.z)}

		local p2 = minetest.find_node_near(mpos, 25, {"default:dirt_with_grass", "default:dirt_with_snow"})
		while p2 == nil and cnt < 5 do
			cnt = cnt+1
			mpos = {x=math.random(minp.x,maxp.x), y=math.random(minp.y,maxp.y), z=math.random(minp.z,maxp.z)}
			p2 = minetest.find_node_near(mpos, 25, {"default:dirt_with_grass", "default:dirt_with_snow"})
		end
		if p2 == nil then return end
		if p2.y < 0 then return end

		local off = 0

		-- Simpler finding routine - check if node immediately above is air,
		-- and if node 16 blocks above is air
		minetest.log("Checking pos to spawn: "..minetest.pos_to_string(p2))
		local next_node_above = minetest.get_node_or_nil({x=p2.x, y=p2.y+1, z=p2.z})
		local next_mapblock_above = minetest.get_node_or_nil({x=p2.x, y=p2.y+16, z=p2.z})
		if next_node_above and next_node_above.name and next_node_above.name == "air" and
			 next_mapblock_above and next_mapblock_above.name and next_mapblock_above.name == "air" then

				 -- Create spawner
				 minetest.after(0.8, function(pos)
					 minetest.log("Creating advanced spawner at "..minetest.pos_to_string(pos))
					 minetest.set_node(pos, {name="zombie2:zombie_spawner"})
				 end, p2)

		end

		-- local opos1 = {x=p2.x+22,y=p2.y-1,z=p2.z+22}
		-- local opos2 = {x=p2.x+22,y=p2.y-1,z=p2.z}
		-- local opos3 = {x=p2.x,y=p2.y-1,z=p2.z+22}
		-- local opos1_n = minetest.get_node_or_nil(opos1)
		-- local opos2_n = minetest.get_node_or_nil(opos2)
		-- local opos3_n = minetest.get_node_or_nil(opos3)
		-- if opos1_n and opos1_n.name and opos1_n.name == "air" then
		-- 	p2 = ground(opos1, p2)
		-- end
		-- if opos2_n and opos2_n.name and opos2_n.name == "air" then
		-- 	p2 = ground(opos2, p2)
		-- end
		-- if opos3_n and opos3_n.name and opos3_n.name == "air" then
		-- 	p2 = ground(opos3, p2)
		-- end
		-- p2.y = p2.y - 3
		-- if p2.y < 0 then p2.y = 0 end
		--if minetest.find_node_near(p2, 25, {"default:water_source"}) ~= nil or minetest.find_node_near(p2, 22, {"default:dirt_with_grass"}) ~= nil or minetest.find_node_near(p2, 52, {"default:sandstonebrick"}) ~= nil then return end

		--minetest.after(0.8,make,p2)
	end
end)




mobs:register_egg("zombie2:zombie", "Zombie", "zombie_head.png", 0)

minetest.register_craftitem("zombie2:rotten_flesh", {
	description = "Rotten Flesh",
	inventory_image = "mobs_rotten_flesh.png",
	on_use = minetest.item_eat(-5),
})
