-- COPYRIGHT AUG 2020, James Gottshall --
-- Version: 2.8 --
local minitel = require "minitel" -- requires minitel, for data streams
local comp = require "component" 
local sides = require "sides"
local event = require "event"
local gpu = comp.gpu
local thread = require("thread")
local color = gpu.maxDepth() > 1
local modem = false
-- search for modems
for addr, name in comp.list("modem", true) do
   modem = comp.proxy(addr)
   break -- break out of the loop, we got him boys
end
-- if modem doesn't exist, override it's metatable to act as a "Yes Man"
if not modem then
    modem = {}
    setmetatable(modem,  {__index = function() return function(...) return true end end})
end

local storage_port = 86

modem.open(storage_port)
-- Open wireless modem, if it exists
if modem.isWireless() then
	modem.setStrength(200)
end
local serial = require("serialization")
local gui = require("gui")

local transposers = {}
for address, name in comp.list("transposer", true) do
	table.insert(transposers, comp.proxy(address))
end


-- Item Ledger is a table with indexed by the names of items holding table 
-- {size, slots={slot, size, side, transposer}
-- Currently can not tell the difference between certain items such as wool and stained glass
local item_ledger = {} -- Reachable from all functions
local free_space = 0
local global_options = {} -- Formatted indexable version of the ledger
function build_ledger()
	if thread.current() then thread.current():suspend() end
	item_ledger = {}
	free_space = 0
	local sidesList = {sides.north, sides.south, sides.east, sides.west}
	for i,t in ipairs(transposers) do
		for j,side in ipairs(sidesList) do
			local count = 1
			for item in t.getAllStacks(side) do
				if item.name then
					if item_ledger[item.label] then
						item_ledger[item.label].size = item_ledger[item.label].size + item.size
						table.insert(item_ledger[item.label].slots, {slot=count, size=item.size, side=side, transposer=i})
					else
						item_ledger[item.label] = {} 
						item_ledger[item.label].size = item.size
						item_ledger[item.label].slots = {{slot=count, size=item.size, side=side, transposer=i}}
						item_ledger[item.label].label = item.label
					end
				else
					free_space = free_space + 1
				end
				count = count + 1
			end
		end
	end
	-- Options table entry looks like this {label, amount} --
	global_options = {}
	for name, v in pairs(item_ledger) do
		table.insert(global_options, {name,v.size})
	end
	table.sort(global_options, function(a,b) return a[1] < b[1] end)
	event.push("rebuilt")
    modem.broadcast(storage_port, "UPDATE", serial.serialize(global_options))
	return true, global_options
end

-- Popup for entering amount. Default is 64. Backspace not supported.
function amount_popup()
	local width,height = gpu.getResolution()
	local popup_fg = 0xffffff
	local popup_bg = 0x0000ff
	local oldbg, oldfg
	
	if color then 
		oldbg = gpu.setBackground(popup_bg)
		oldfg = gpu.setForeground(popup_fg)
	end
    -- Draw the amount dialog
	gpu.set(width/2-4,height/2,"/--------\\")
	gpu.set(width/2-4,height/2+1,"| Amount |")
	gpu.set(width/2-4,height/2+2,"|        |")
	gpu.set(width/2-4,height/2+3,"\\--------/")
	
	local input = ""
	while true do
		gpu.set(width/2-(string.len(input)/2)+1,height/2+2,input)
		id,_,char,code = event.pullMultiple("key_down","interrupted")
		if id == "interrupted" then return 0 end
		if id == "key_down" then
			if code==28 then
				if color then 
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
function request_menu(ledger)
	-- GUI Variables
	local cursor = {x=1,y=1} -- Where the selection cursor is. Holy Crap I did this backwards but its too late now
	local scroll = 0
	local loop = true
	local screenX,screenY = gpu.getResolution()
	local search = ""
	local cursor_color = 0xff0000
	local bg_color = 0x004455
	local build_thread = nil
	local request_thread = nil
	local options = ledger
	local motionTimer = true
	
	local function convert(x,y)
		-- Converts 2D coords to 1D, only necessary because I am big dumb. Could probably do this different
		return x*2 - y%2
	end
	
	if color then gpu.setBackground(bg_color) end
	gpu.fill(1,1,screenX,screenY," ") -- Clear Screen
	
	-- GUI Loop --
	while loop do
		-- Get User Input Events
		id,addr,char,code,playerName = event.pullMultiple("key_up","key_down","interrupted","rebuilt","motion")
		if id=="interrupted" then 
			gpu.fill(1,1,screenX,screenY," ")
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
					gpu.fill(1,2,screenX,screenY," ")
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
				if cursor.x - scroll >= screenY - 2 then
					scroll = scroll + 1
					gpu.fill(1,2,screenX,screenY," ")
				end
			elseif code==28 then -- Enter
				local amt = amount_popup()				
				gpu.fill(1,2,screenX,screenY-2, " ")
				request_thread = thread.create(fill_request, options[convert(cursor.x,cursor.y)][1], amt)
				build_thread = thread.create(build_ledger)
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
				gpu.fill(1,1,screenX,screenY," ")
				motionTimer = false
				build_thread = thread.create(build_ledger)
				event.timer(10, function() motionTimer = true end)
			end
		end
		
		gpu.fill(1,1,screenX,1," ")
		gpu.set(1,1,"Free Slots: "..free_space)
		-- gpu.set(screenX/2,1,"Key: "..char.." Code: "..code)
		if options ~= global_options then
			options = global_options
		end
		if options[convert(cursor.x,cursor.y)][2] then
			gpu.set(screenX/2 + 1,1,"Amount: "..math.floor(options[convert(cursor.x,cursor.y)][2]).."x")
		end
		-- gpu.set(1,screenY,"X: "..cursor.x.." Y: "..cursor.y) -- For testing cursor position
		-- Display item list
		for i=1,2*(screenY-2) do
			if color and convert(cursor.x - scroll,cursor.y) == i then
				gpu.setBackground(cursor_color)
			elseif color then
				gpu.setBackground(bg_color)
			end
			if not options[i + 2*scroll] then break end 
			local label = options[i + 2*scroll][1]
			label = string.sub(label,1,math.min(#label,screenX/2 - 3))
			label = gui.rpad(label, screenX / 2 - 1)
			if i%2~=0 then
				gpu.set(1,math.floor(i/2)+2," ".. label)
			else
				gpu.set(screenX/2 + 1,i/2+1," ".. label)
			end
		end
		if color then gpu.setBackground(cursor_color) end
		gpu.set((cursor.y-1)*(screenX/2)+1,cursor.x+1-scroll,">")
		if color then gpu.setBackground(bg_color) end
		
		-- This solution seems to be marginally faster, allows graphics to display before calling a ton of yield calls
		if request_thread then
			request_thread:resume()
			request_thread = nil
		end
		if build_thread then
			build_thread:resume()
			build_thread = nil
		end
	end
end

function empty_slot(trans, side)
	local count = 1
	for i in trans.getAllStacks(side) do
		if i.name == nil then return count end
		count = count + 1
	end
end

-- Grabs requested item, returns amount fetched
function fill_request(item_name, amount)
	if thread.current() then thread.current():suspend() end
	local item = item_ledger[item_name] -- Ledger info about the item, see build_ledger
	if amount > item.size then
		amount = item.size
	end
	local total = 0
	while amount > 0 do
		local slot = item.slots[#item.slots]
		local empty = empty_slot(transposers[slot.transposer], sides.up)
		local transfer = transposers[slot.transposer].transferItem(slot.side, sides.up, math.min(slot.size, amount), slot.slot, empty)
		-- TODO actually update ledger
		amount = amount - transfer
		total = total + transfer
		slot.size = slot.size - transfer
		if slot.size <= 0 then table.remove(item.slots, #item.slots) end
	end
	return total
end

local hosts = {}
-- Network Callback Function
function network_request(_,_,from_addr,port,dist,...)
	local msg = {...}
	if port ~= storage_port then return end
	if msg[1] == "GET" then
		-- msg[2] is the start index and msg[3] is the end index
		-- TODO: implement above
        -- Send updated ledger over available streams
		minitel.send(storage_port, "UPDATE", serial.serialize(global_options))
	elseif msg[1] == "FETCH" then
		-- msg[2] is the item name and msg[3] is the amount
		modem.send(from_addr, port, "REQUEST_STATUS", fill_request(msg[2], tonumber(msg[3])))
    elseif msg[1] == "REGISTER" then
       -- Register API call, adds the sender to the hosts table
        table.insert(hosts, from)
        minitel.send(hosts[#hosts], storage_port, "Successfully Registered")
    end
end

event.listen("modem_message", network_request)

-- Program Starts Here --
print("Building Ledger\n")
local _,ledger = build_ledger()
print("Free Slots Remaining: "..free_space)
request_menu(ledger)
