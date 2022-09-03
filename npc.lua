

minetest.register_entity("natspawner:npc", {
	hp_max = 1,
	visual = "mesh",
	mesh = "creatures_mob.x",
	textures = {
		{"mobs_zombie.png"},
	},
	visual_size = {x = 1, y = 1, z = 1},
	collisionbox = {-0.6,-0.6,-0.6, 0.6,0.6,0.6},
	physical = false,
	on_activate = function(self, staticdata)

--		minetest.log("Static data: "..dump(staticdata))
--		-- Staticdata
--		local data = {}
--		if staticdata ~= nil and staticdata ~= "" then
--			local cols = string.split(staticdata, "|")
--			data["textures"] = minetest.deserialize(cols[1])
--			data["timer"] = minetest.deserialize(cols[2])
--			data["spawner"] = minetest.deserialize(cols[3])
--		end

--		if temp_spawner_data ~= nil then
--			-- Textures
--			if temp_spawner_data.textures ~= nil then
--				self.textures = temp_spawner_data.textures
--				temp_spawner_data.textures = nil
--			elseif staticdata ~= nil and staticdata ~= "" then
--				self.textures = data.textures
--			else
--				self.textures = {"wool_red.png", "wool_red.png", "wool_red.png", "wool_red.png", "wool_red.png", "wool_red.png"}
--			end
--			if self.textures ~= nil then
--				-- Set object properties
--				self.object:set_properties(self)
--			end

--			-- Timer data
--			if temp_spawner_data.timer ~= nil then
--				self.timer = temp_spawner_data.timer
--				temp_spawner_data.timer = nil
--			elseif staticdata ~= nil and staticdata ~= "" then
--				self.timer = data.timer
--			else
--				self.timer = {
--					interval = 0,
--					timer = 0
--				}
--			end
--			-- Spawner data
--			if temp_spawner_data.spawner ~= nil then
--				self.spawner = temp_spawner_data.spawner
--				temp_spawner_data.spawner = nil
--			elseif staticdata ~= nil and staticdata ~= "" then
--				self.spawner = data.spawner
--			else
--				self.spawner = {
--					entity_spawn_count = 0,
--					entity_kill_count = 0,
--					next_deactivation_count = math.random(min_kill_count, max_kill_count),
--					next_deactivation_time = math.random(min_deactivation_time, max_deactivation_time)
--				}
--			end
--		end

	end,
	get_staticdata = function(self)
--		local result = ""
--		if self.textures ~= nil then
--			result = minetest.serialize(self.textures).."|"
--		end
--		if self.timer ~= nil then
--			result = result..minetest.serialize(self.timer).."|"
--		end
--		if self.spawner ~= nil then
--			result = result..minetest.serialize(self.spawner)
--		end
--		return result
	end,
	on_step = function(self, dtime)
		self.timer.timer = self.timer.timer + dtime
		if self.timer.timer >= self.timer.interval then
			self.object:set_velocity({x=0, y=0, z=0})
			self.timer.timer = 0
			self.object:set_velocity({x=1, y=0, z=0})
			--spawn(self, "natspawner:zombie")
		end
	end,
	on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir)
		minetest.log(dump(self))
	end
})

minetest.register_craftitem("natspawner:npc_spawner", {
	description = "Spawner",
	inventory_image = "apple.png",
	on_use = function(itemstack, user, pointed_thing) {
		local entity = minetest.add_entity(minetest.pointed_thing_to_face_pos(user, pointed_thing), "natspwaner:npc")
		if entity then
			
		else
			minetest.remove_entity(entity)
		end
	}
})
