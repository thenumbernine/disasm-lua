local ffi = require 'ffi'
local template = require 'template'
local assert = require 'ext.assert'
local class = require 'ext.class'
local string = require 'ext.string'
local table = require 'ext.table'


local Cmd = class()	-- parent abstract class

-- ends .classCmdSet assigned
function Cmd:digest(read)
	local args = table()
	if self.argtypes then
		for _,ctype in ipairs(self.argtypes) do
			args:insert(read(ctype))
		end
	end
	self:getargs(args:unpack())
end

function Cmd:getargs(...)
	if self.argnames then
		for i=1,math.min(#self.argnames, (select('#', ...))) do
			self[self.argnames[i]] = select(i, ...)
		end
	else
		self.args = table{...}
	end
end

Cmd.__concat = string.concat

function Cmd:__tostring()
	if self.descstr then return self.descstr end

	if type(self.desc) ~= 'string' then
		error("for cmdset="..tostring(self.classCmdSet)..' cmd='..tostring(self.cmd).." __tostring failed to find self.desc")
	end

	assert.eq(self.self, nil)
	self.self = self	-- ugly hack for template cuz i dont want to do an ugly metatable __index hack
	local s = template(self.desc, self)
	self.self = nil

	return s
end

-- used by run-event-script.lua (should rename to run-script since it does multiple right now)
-- default impl:
function Cmd.toCode(self, indent)
	return tostring(self)
end

-- return comment with address, bytes, and disasm code
-- TODO how about a few columsn on the left instead of every-other-line ?
-- and if the byte dump is too big then give this a few newlines
function Cmd.getAsmLine(self)
	if not self.addr then return end
	assert.index(self, 'cmdset')
	assert.index(self, 'sizeInBytes')
	-- print addr
	local disasm = self.trace.disasm
	local cmdSetAbbrev = disasm.cmdSetAbbrev
	return
		('%06x '):format(self.addr)

		-- print shorthand cmdset
		..(cmdSetAbbrev and cmdSetAbbrev[self.cmdset] or '')

		-- print out bytes
		-- TODO for cmds too big, put their data on multiple lines?
		..ffi.string(disasm.data + self.addr, self.sizeInBytes)
			:gsub('.', function(b)
				return (' %02x'):format(b:byte())
			end)
end

return Cmd
