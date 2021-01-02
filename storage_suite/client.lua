-- COPYRIGHT AUG 2020, James Gottshall --
-- Version 0.8 --
-- Thin Client for the storage system suite --
local minitel = require "minitel" -- requires minitel
local comp = require("component")
local event = require("event")
local gpu = comp.gpu
local serial = require("serialization")
local modem = comp.modem
local storage_port = 86
modem.open(storage_port)
local Swidth, Sheight = gpu.getResolution()

-- Activate Wireless Card --
if modem.isWireless() then
	modem.setStrength(200);
end

-- I hate tier 1 GPUs, they only have buffer space for a single screen
local ADV_GPU = gpu.maxDepth() > 1 -- Whether to use VRAM buffers and colors

local message_bar = ""
local global_options = {}
-- Network Callback --
function network_message(_,_,from_addr,port,dist,...)
	msg = {...}
	if port ~= storage_port then return end
	if msg[1] == "UPDATE" then
		global_options = serial.unserialize(msg[2])
        message_bar = "Ledger Rebuilt"
        event.push("rebuilt")
	elseif msg[1] == "REQUEST_STATUS" then
        message_bar = math.floor(msg[2]) .. " Items Fetched"
        event.push("motion") -- Easy way to display how many items were fetched
	end
end
event.listen("modem_message", network_message)

-- Popup for entering amount. Default is 64. Backspace not supported.
function amount_popup()
	local popup_fg = 0xffffff
	local popup_bg = 0x0000ff
	local oldbg, oldfg
	
	if ADV_GPU then 
		oldbg = gpu.setBackground(popup_bg)
		oldfg = gpu.setForeground(popup_fg)
	end
	gpu.set(Swidth/2-4,Sheight/2,"/--------\\")
	gpu.set(Swidth/2-4,Sheight/2+1,"| Amount |")
	gpu.set(Swidth/2-4,Sheight/2+2,"|        |")
	gpu.set(Swidth/2-4,Sheight/2+3,"\\--------/")
	
	local input = ""
	while true do
		gpu.set(Swidth/2-(string.len(input)/2)+1,Sheight/2+2,input)
		id,_,char,code = event.pullMultiple("key_down","interrupted")
		if id == "interrupted" then return 0 end
		if id == "key_down" then
			if code==28 then
				if ADV_GPU then 
					gpu.setBackground(oldbg)
					gpu.setForeground(oldfg)
				end
				if string.len(input) > 0 then
					return tonumber(input)
				else
					return 64
				end
			end
			if char and tonumber(string.char(char)) then
				input = input .. string.char(char)
			end
		end
	end
end


-- The main part of the request GUI
function request_menu()
	modem.broadcast(storage_port, "GET")
	
	-- GUI Variables
	local cursor = {x=1,y=1} -- Where the selection cursor is. Holy Crap I did this backwards but its too late now
	local scroll = 0
	local loop = true
	-- local Swidth,Sheight = gpu.getResolution()
	local search = ""
	local cursor_color = 0x03fcf4
	local bg_color = 0x2e3b3a
	local options = global_options
	local motionTimer = true
	local buffer = gpu.allocateBuffer(Swidth, Sheight - 2)
    if not buffer then gpu.freeAllBuffers() buffer = gpu.allocateBuffer(Swidth, Sheight -2) end
	
	local function convert(x,y)
		-- Converts 2D coords to 1D, only necessary because I am big dumb. Could probably do this different
		return x*2 - y%2
	end
	
	if ADV_GPU then gpu.setBackground(bg_color) end
	gpu.fill(1,1,Swidth,Sheight," ") -- Clear Screen
	
	-- GUI Loop --
	while loop do
		-- Get User Input Events
		id,addr,char,code,playerName = event.pullMultiple("key_up","key_down","interrupted","rebuilt","motion")
		if id=="interrupted" then 
			gpu.fill(1,1,Swidth,Sheight," ")
            gpu.freeBuffer(buffer)
			modem.close(storage_port)
			return
		end
		if id=="key_down" then
			if code==200 then --Up Arrow
				if cursor.x > 1 then
					cursor.x = cursor.x - 1
				end
				if scroll > 0 and cursor.x - scroll < 2 then
					scroll = scroll - 1
				end
			elseif code==203 then --Left Arrow
				cursor.y = 1
			elseif code==205 then --Right Arrow
				if #options%2==0 or cursor.x*2 - 1 < #options then
					cursor.y = 2
				end
			elseif code==208 then --Down Arrow
				if 2*cursor.x < #options and (convert(cursor.x+1,2) <= #options or cursor.y == 1) then
					cursor.x = cursor.x + 1
				end
				if cursor.x - scroll >= Sheight - 2 then
					scroll = scroll + 1
				end
			elseif code==28 then -- Enter
				local amt = amount_popup()
				message_bar = "Trying to Fetch "..amt.." "..options[convert(cursor.x,cursor.y)][1]
				gpu.fill(1,2,Swidth,Sheight-2, " ")
				modem.broadcast(storage_port, "FETCH", options[convert(cursor.x,cursor.y)][1], tonumber(amt))
				search = ""
			elseif char then
				search = string.char(char)
				for i=1,#options do
					if string.lower(string.sub(options[i][1],1,1)) == string.lower(search) then
						cursor.x = math.ceil(i/2)
						cursor.y = 2 - (i%2)
						scroll = cursor.x - 1
						break
					end
				end
			end
		end
		if id=="rebuilt" then
			options = global_options
		elseif id=="motion" then
			if motionTimer then
				modem.broadcast(storage_port, "GET")
				motionTimer = false
				event.timer(10, function() motionTimer = true end)
			end
		end
		
		if options[convert(cursor.x,cursor.y)] then
			gpu.set(Swidth/2,1,"Amount: ".. math.floor(options[convert(cursor.x,cursor.y)][2]) .."x            ")
		end
		-- Display item list --
		if ADV_GPU then 
            gpu.setActiveBuffer(buffer) 
            gpu.setBackground(bg_color)
        end -- Use Buffers if not on tier 1
        gpu.fill(1,1,Swidth,Sheight-2," ")
		for i=1,2*(Sheight-2) do
			if ADV_GPU and convert(cursor.x - scroll,cursor.y) == i then
				gpu.setBackground(cursor_color)
			elseif ADV_GPU then
				gpu.setBackground(bg_color)
			end
			if not options[i + 2*scroll] then break end 
			local label = options[i + 2*scroll][1]
			label = string.sub(label,1,math.min(#label,Swidth/2 - 3))
			if i%2~=0 then
				gpu.set(1,math.floor(i/2) + 1," ".. label)
			else
				gpu.set(Swidth/2 + 1,i/2," ".. label)
			end
		end
		if ADV_GPU then gpu.setBackground(cursor_color) end
		gpu.set((cursor.y-1)*(Swidth/2)+1,cursor.x - scroll,">")
		if ADV_GPU then 
			gpu.setActiveBuffer(0)
			gpu.bitblt(0,1,2,Swidth,Sheight - 2,buffer)
			gpu.setBackground(bg_color)
		end
        gpu.fill(1,Sheight,Swidth,1, " ")
        gpu.set(Swidth/2 - string.len(message_bar)/2,Sheight, message_bar)
	end
end

request_menu()
