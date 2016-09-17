-- see copyright notice in wxLdb.lua

local wx = require( "wx" )

module( "ui.id" )

local lastId = wx.wxID_HIGHEST + 1

function new()
	lastId = lastId + 1
	return lastId
end
