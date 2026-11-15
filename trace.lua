local ffi = require 'ffi'
local assert = require 'ext.assert'
local table = require 'ext.table'
local class = require 'ext.class'
local tolua = require 'ext.tolua'

local int8_t = ffi.typeof'int8_t'
local uint8_t = ffi.typeof'uint8_t'
local int16_t = ffi.typeof'int16_t'
local uint16_t = ffi.typeof'uint16_t'
local int32_t = ffi.typeof'int32_t'
local uint32_t = ffi.typeof'uint32_t'
local float = ffi.typeof'float'
local double = ffi.typeof'double'

--[[
TODO here instead of assuming the next-in-order address marks the end ...
- we should be tracing until 'return'
- and upon branch, recursive call the trace ...
- and then warn if we ever trace over the same code block but offset or with a different opcode set...
- and then ... i should be properly decoding world-vs-events, and also not decoding extra things past 'return'
--]]

local Trace = class()

Trace.indent = 0

function Trace:init(args)
	local disasm = assert.index(args, 'disasm')
	self.disasm = disasm
	self.addr = assert.index(args, 'addr')

	local reverseRefInfo = args.reverseRefInfo

--[==[ debugging
print('decompiling from '..require'ext.tolua'(reverseRefInfo, {
indent = false,
serializeForType = {
	number = function(state, x, tab, luapath, keyRef)
		return disasm:addrLabel(x)
	end,
},
}))
--]==]
	disasm.whatsPointingToAddr[self.addr] = disasm.whatsPointingToAddr[self.addr] or table()
	disasm.whatsPointingToAddr[self.addr]:insert(reverseRefInfo)

	self.cmds = table()
	self.cmdObjForAddr = {}	-- keys are cmds[i].addr

	-- optional?
	self.lastDialogPromptCount = args.lastDialogPromptCount

	local cmdset = assert.index(args, 'cmdset')
--DEBUG:assert.type(cmdset, 'string')

	-- force override addrs here
	if self.addr == 0x0a5eb4 then
		cmdset = 'EventCmds'	-- end-script used by event and world cmds
	end

	-- not sure about this
	self.stateStack = table()
	self.stateStack:insert{
		cmdset = cmdset,
	}

	if args.inVehicle then
		self.stateStack:insert{
			cmdset = 'VehicleCmds',
		}
	end

	self.newBranches = table()

	self.pc = self.addr
end

function Trace:readAndInc(ctype)
	ctype = ffi.typeof(ctype)
	local ptrtype = ffi.typeof('$*', ctype)

	assert.lt(self.pc, self.disasm.len)
	local o = ffi.cast(ptrtype, self.disasm.data + self.pc)[0]
	self.pc = self.pc + ffi.sizeof(ctype)

	return self:getValue(o, ctype)
end

function Trace:getValue(o, ctype)
	-- if it's a primitive and bitness <= 32
	if ctype == uint8_t
	or ctype == int8_t
	or ctype == uint16_t
	or ctype == int16_t
	or ctype == uint32_t
	or ctype == int32_t
	or ctype == float
	or ctype == double
	then
		o = tonumber(o)
	else
		o = ctype(o)
	end

	return o
end

function Trace:readNext()
	local cmdaddr = self.pc
	local cmd = self:readAndInc(uint8_t)

--DEBUG:assert.gt(#self.stateStack, 0, "someone popped the last cmdset...")
	local cmdset = self.stateStack:last().cmdset
--DEBUG:assert.type(cmdset, 'string')

	return self:readInstr(cmdaddr, cmdset, cmd)
end

-- cmdaddr has to be abstracted because typical cmds addrs are pc-1 from args, for reading the type of cmd
-- but some hard-coded cmds for addrs dont have the extra byte and so they have to use pc itself
function Trace:readInstr(cmdaddr, cmdset, cmd)
	local disasm = self.disasm
	local cl = disasm[cmdset][cmd]
	if not cl then error("failed to find cmd "..tolua(cmd).." in cmdset "..tolua(cmdset)) end

	local cmdobj = cl()
	cmdobj.trace = self
	cmdobj.addr = cmdaddr
	cmdobj.cmdset = cmdset
	cmdobj.indent = self.indent

	-- self:less function to pass to cmd digest()
	local function read(ctype)
		local o
		o = self:readAndInc(ctype)
		return o
	end

	-- hmm instead of just 'read' with 'addr', how about a whole interpretation-state, with 'cmdset' too?
	cmdobj:digest(read)

	-- track all bytes used here, in case someone cares?
	cmdobj.sizeInBytes = self.pc - cmdaddr

	disasm.eventScriptCmds:insert(cmdobj)
	self.cmds:insert(cmdobj)
	self.cmdObjForAddr[cmdaddr] = cmdobj

--[==[ debugging print as we go
io.write(disasm:addrLabel(cmdobj.addr), '\t')
io.write(({
	EventCmds = 'EV ',
	WorldCmds = 'WO ',
	ObjectCmds = 'OB ',
	VehicleCmds = 'VE ',
})[cmdobj.cmdset])
local function align(n, s)
	s = tostring(s)
	return s..(' '):rep(n - #s)
end
io.write(align(
	24,
	ffi.string(disasm.data + cmdobj.addr, cmdobj.sizeInBytes)
		:gsub('.', function(b)
			return ('%02x '):format(b:byte())
		end)
))
print((tostring(cmdobj)
	:gsub('\t', '\\t')
	:gsub('\r', '\\r')
	:gsub('\n', '\\n')
))
--]==]

	if cmdobj.getBranchAddrs then
		-- decode branches ... now or later?
		for _,newBranch in ipairs(cmdobj:getBranchAddrs()) do
			newBranch.cmdset = newBranch.cmdset or self.stateStack[1].cmdset		-- make sure we record the current cmdset
			newBranch.inVehicle = self.stateStack:last().cmdset == 'VehicleCmds'	-- right now self.stateStack is just 1 or 2 in size, and 2 is always VehicleCmds, and 1 is always not...
			newBranch.lastDialogPromptCount = self.lastDialogPromptCount
			newBranch.reverseRefInfo = {
				cmdobj = cmdobj,
				branchFromAddr = cmdaddr,
				cmdset = newBranch.cmdset,
			}
			self.newBranches:insert(newBranch)
		end
	end

	-- this is gonna go before cmds very soon
	local newCmdSet = ({
		-- these are all SetMap's:
		[0x0a0096] = 'WorldCmds',	-- doomgaze defeated - the setmap sets vehicle but I guess don't?
		[0x0a00e3] = 'WorldCmds',	-- from map touch, specifically doomgaze
		[0x0a7a86] = 'EventCmds',	-- branch
		[0x0a8ff0] = 'EventCmds',	-- branch
		[0x0af4c1] = 'WorldCmds',	-- branch
		[0x0af4d7] = 'WorldCmds',	-- branch
		[0x0af4f3] = 'WorldCmds',	-- branch, so it matters
		[0x0af567] = 'EventCmds',	-- branch, so it matters
		[0x0af596] = 'EventCmds',	-- branch
		[0x0b4505] = 'EventCmds',	-- branch
		[0x0b67f7] = 'WorldCmds',	-- branch ... everything8215's event_main.asm says first set to World ... then after endScript set to Events ... does endScript always set cmdset to Events?
		[0x0c3383] = 'EventCmds',	-- branch
		-- sometimes just a goto, or a conditional-goto will change things?
		[0x0af4c7] = 'EventCmds',	-- $0af4c7	WO b0 76 01 b4 5e 00       if not mapFlagGet(374) then goto $0a5eb4 end
		[0x0af4dd] = 'EventCmds',	-- $0af4dd	WO b0 76 01 b4 5e 00       if not mapFlagGet(374) then goto $0a5eb4 end
		[0x0a8ca8] = 'EventCmds',	-- $0a8ca8	VE b0 27 01 e3 8b 00       if not mapFlagGet(295) then goto $0a8be3 end
	})[cmdaddr]
	if newCmdSet then
		for i=2,#self.stateStack do self.stateStack[i] = nil end	-- clear VehicleCmds too
		self.stateStack[1].cmdset = newCmdSet
	end

	return cmdobj
end

function Trace:run()
	local disasm = self.disasm
	local startCmdSet = self.stateStack:last().cmdset

	-- make sure we haven't decoded this already
	for _,otherTrace in pairs(disasm.decompileTraces) do
		local cmdobj = otherTrace.cmdObjForAddr[self.addr]
		if cmdobj then
			if cmdobj.cmdset ~= self.stateStack:last().cmdset then
				print('!!! DANGER !!! '
					..disasm:addrLabel(self.addr)
					..' decoding address from differing cmdset!'
					..' previous cmdset '..cmdobj.cmdset
					..' from trace at '..disasm:addrLabel(otherTrace.cmds[1].addr)
					..' vs new cmdset '..self.stateStack:last().cmdset
				)
			else
				return otherTrace
			end
		end
	end

	disasm.decompileTraces[self.addr] = self

--[==[ debugging:
print(('BEGIN '..disasm:addrLabel(self.addr))
--]==]

	while true do
		local cmdobj = self:readNext()
		if not cmdobj or cmdobj.endTrace then break end
	end

	-- set this before trying recursive, so they know this trace's address interval
	self.endAddr = self.pc

--[==[ debugging:
print('END '..disasm:addrLabel(self.endAddr))
print()
--]==]

	assert.ge(#self.stateStack, 1, "somehow we popped all our states...")

	if self.stateStack:last().objectScriptCmd then
		print('!!! DANGER !!! event-script ended still inside an object-script:',
			'script start = '..disasm:addrLabel(self.addr),
			'object-script start = '..disasm:addrLabel(self.stateStack:last().objectScriptCmd.addr)
		)
	end

	for _,newBranch in ipairs(self.newBranches) do
		local trace = disasm:trace(newBranch)

		-- [[ why can't I just do this in Trace:run?
		-- because I only should do this when the previous cmdset was different
		if startCmdSet ~= 'BattleAnimCmds'
		and newBranch.cmdset == 'BattleAnimCmds'
		then
			trace:readInstr(trace.pc, newBranch.cmdset, 'SpeedAndAlign')
		end
		--]]

		trace:run()
	end

	return self
end

function Trace:printInterval()
	local disasm = self.disasm
	return disasm:addrLabel(self.addr)..' - '..disasm:addrLabel(self.endAddr)
end

return Trace
