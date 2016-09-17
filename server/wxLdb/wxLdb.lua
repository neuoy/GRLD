-- Copyright (C) 2010-2016 Youen Toupin.
-- This file is part of GRLD, a Graphical Remote Lua Debugger
-- GRLD is distributed under the MIT license (http://www.opensource.org/licenses/mit-license.html), a copy of which is included below.

--[[
Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

local listenIP = arg[1] or "*"
local listenPort = tonumber( arg[2] ) or 4242

package.cpath = package.cpath..";../lua/?.dll"
package.path = package.path..";wxLdb/?.lua"
package.path = package.path..";../shared/?.lua"

local window = require( "ui.mainWindow" ).new()
local engine = require( "grld.engine" )
local controller = require( "wxLdbController" ).new( engine, window )

controller:addListener( listenIP, listenPort )

local function updateEngine()
	local active = false
	if engine.initialized() then
		active = engine.update( 0.01 )
	end
	if active then
		window:setActive()
	end
	controller:update()
end

window:addIdleUpdate( updateEngine )

if wxLdb_hook ~= nil then
	-- used by automatic tests : they need to get the controller before entering the wxWidgets main loop
	wxLdb_hook( controller )
end

wx.wxGetApp():MainLoop()

engine.shutdown()
