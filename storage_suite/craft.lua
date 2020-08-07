-- COPYRIGHT AUG 2020, James Gottshall --
-- Version: 0.3 --
-- Crafting manager --

local comp = require("component")
local trans = comp.transposer
local sides = require("sides")
local event = require("event")
local modem = comp.modem

-- Constants --
local input_side = sides.south
local output_side = sides.up
local crafter_side = sides.west
local template_side = sides.east
local storage_port = 86

-- Right Up There /\
print("Make Sure to Edit Constants at Top of Program!")

function craft(recipe_name)
	
end

function new_recipe()
	for i=1, 9 do
		trans.get
	end
end

function main()
	modem.open(storage_port)
	while true do
		local id, localNetworkCard, remoteAddress, port, distance, payload = event.pullMultiple("modem_message", "key_down", "interrupted")
		if id == "modem_message" and port == storage_port then
			print("Recieved Message: " .. payload)
		elseif id == "key_down" then
			if string.lower(string.char(remoteAddress)) == "n" then
				new_recipe()	
			end
		elseif id == "interrupted" then
			break
		end
	end
	modem.close(storage_port)
end

main()