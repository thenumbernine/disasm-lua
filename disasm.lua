local class = require 'ext.class'
local table = require 'ext.table'

local Disasm = class()

Disasm.Trace = require 'disasm.trace'

function Disasm:init(data, len)
	self.data = data
	self.len = len

	self.eventScriptCmds = table()

	-- event code, pointed into by NPCs and maybe other things
	self.whatsPointingToAddr = {}

	-- remember where we've started from so we don't go over the same area twice
	-- TODO this but for the state of decoding as well
	self.decompileTraces = {}
end

function Disasm:trace(args, ...)
	args = args or {}
	args.disasm = self
	-- TODO Trace() + :run()
	-- sometimes :run() returns a dif object (when the trace was already done)
	-- so how about merge the ctor + :run() into here
	-- and don't alloc an unused Trace() object
	return self.Trace(args, ...)
end

function Disasm:addrLabel(addr)
	return ('_%06x'):format(addr)
end

--[[
sort, remove duplicates, etc
--]]
function Disasm:done()

	-- is this a good idea, or should I double-check by storing trace address ranges and make sure none overlap so that i'm not inserting cmds between/ontop one another?
	self.eventScriptCmds:sort(function(a,b) return a.addr < b.addr end)

-- [=[ remove subsets
	local sortedTraces = table.values(decompileTraces)
	sortedTraces:sort(function(a,b) return a.addr < b.addr end)
	for i=#sortedTraces-1,1,-1 do
		local a = sortedTraces[i]
		local b = sortedTraces[i+1]
		-- if they have the same ending
		-- then chances are the smaller half decoded first then the larger earlier half
		if a.addr < b.addr
		and a.endAddr == b.endAddr
		then
--DEBUG:print('found possible subset trace '..self:addrLabel(a.addr)..' - '..self:addrLabel(a.endAddr)..' vs range '..self:addrLabel(b.addr)..' - '..self:addrLabel(b.endAddr))
			-- but first verify
			-- make sure all the cmds match
			local allmatch = true
			for j,bcmd in ipairs(b.cmds) do
				local acmd = a.cmds[#a.cmds-#b.cmds+j]
				if acmd.addr ~= bcmd.addr then
--DEBUG:print('...but cmd addr at '..self:addrLabel(acmd.addr)..' vs '..self:addrLabel(bcmd.addr).." didn't match")
					allmatch = false
					break
				end
				if acmd.cmdset ~= bcmd.cmdset then
					allmatch = false
					break
				end
				if getmetatable(acmd) ~= getmetatable(bcmd) then
--DEBUG:print('...but cmd metatable at '..self:addrLabel(acmd.addr).." didn't match")
					allmatch = false
					break
				end
			end
			if allmatch then
--DEBUG:print('removing subset trace '..self:addrLabel(b.addr)..' - '..self:addrLabel(b.endAddr))
				decompileTraces[b.addr] = nil
				sortedTraces:remove(i+1)
			end
		end
	end
--]=]

	-- double-check collisions
	local sortedTraces = table.values(decompileTraces)
	sortedTraces:sort(function(a,b) return a.addr < b.addr end)
	for i=2,#sortedTraces do
		local a = sortedTraces[i-1]
		local b = sortedTraces[i]
		if b.addr < a.endAddr then
			print('!!! collision detected between '..a:printInterval()..' and '..b:printInterval())
		end
	end

	self.decompileTraces = decompileTraces

	-- calculate eventScriptCmdIndexForAddr
	-- and remove duplicates
	self.eventScriptCmdIndexForAddr = {}
	do
		local i = 1
		while i <= #self.eventScriptCmds do
			local cmd = self.eventScriptCmds[i]
			if self.eventScriptCmdIndexForAddr[cmd.addr] then
				-- then we have duplicates ....
				assert.lt(self.eventScriptCmdIndexForAddr[cmd.addr], i)
				local ocmd = self.eventScriptCmds[self.eventScriptCmdIndexForAddr[cmd.addr]]
				assert.ne(rawequal(cmd, ocmd))
				self.eventScriptCmds:remove(i)	-- removing cmd, keeping ocmd

				-- also remove duplicate callbacks anywhere that this might have pointed...
				-- [=[
				if cmd.getBranchAddrs then
					for _,branch in ipairs(cmd:getBranchAddrs()) do
						local branchAddr = branch.addr
						assert(self.whatsPointingToAddr[branchAddr])

						-- duplicate equal cmds, so remove only one
						local found
						for j=#self.whatsPointingToAddr[branchAddr],1,-1 do
							if self.whatsPointingToAddr[branchAddr][j].cmdobj == cmd then
								self.whatsPointingToAddr[branchAddr]:remove(j)
							elseif self.whatsPointingToAddr[branchAddr][j].cmdobj == ocmd then
								found = true
							end
						end
						assert(found)
						-- shouldn't be zero because we should have a duplicate entry
						assert.gt(#self.whatsPointingToAddr[branchAddr], 0)
					end
				end
				--]=]
			else
				self.eventScriptCmdIndexForAddr[cmd.addr] = i
				i = i + 1
			end
		end
	end

	-- addr -> cmd
	local cmdForAddr = {}
	for _,cmdobj in ipairs(self.eventScriptCmds) do
		cmdForAddr[cmdobj.addr] = cmdobj
	end

	for _,cmdobj in ipairs(self.eventScriptCmds) do
		if self.ObjectCmds.Branch:isa(cmdobj) then
			local destAddr = cmdobj:getDestAddr()
			if destAddr then
				self.whatsPointingToAddr[destAddr] = self.whatsPointingToAddr[destAddr] or table()
				local destCmdObj = cmdForAddr[destAddr]
				if not destCmdObj then
print("!!! WARNING !!!! branch from "
	..('_%06x'):format(cmdobj.addr)
	..' to unknown location '
	..('_%06x'):format(destAddr))
				end
				self.whatsPointingToAddr[destAddr]:insert{
					cmdobj = cmdobj,
					branchFromAddr = cmdobj.addr,
					cmdset = cmdobj.cmdset,
				}
			end
		end
	end

end

return Disasm
