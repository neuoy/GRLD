-- see copyright notice in wxLdb.lua

local print = print
local wx = require( "wx" )
_G.print = print -- override wx print function with original one

module( "ui.about" )

function popup()
	wx.wxMessageBox( "Graphical Remote Lua Debugger @VERSION@\nCopyright (C) 2010-2012 Youen Toupin.  All rights reserved.\nSee file GRLD-license.txt for permission notice.\nSee file contact.txt if you have any question,\nor go to http://cushy-code.com/grld/", "About GRLD" )
end
