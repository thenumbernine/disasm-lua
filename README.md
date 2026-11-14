Usage:

```
local Disasm = require 'disasm'

Disasm[cmdsetName] = {
	[opcode] = Cmd:subclass{
		cmd = opcode,		-- redundant?
		argtypes = {ffi types...},
		argnames = {field names...},
		desc = 'code output...',
	}
}

local d = Disasm(data, len)

d:run(addr)
```
