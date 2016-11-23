-- see copyright notice in wxLdb.lua

local print = print
local wx = require( "wx" )
_G.print = print -- override wx print function with original one

module( "ui.about" )

function popup()
	wx.wxMessageBox( "Graphical Remote Lua Debugger\nCopyright (C) 2010-2016 Youen Toupin.  All rights reserved.\nSee file LICENSE for permission notice.\nSee github repository https://github.com/neuoy/GRLD if you have any question", "About GRLD" )
end
