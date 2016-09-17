-- see copyright notice in wxLdb.lua

local wx = require( "wx" )

local coroutine = coroutine
local assert = assert
local debug = debug

module( "mainthread" )

local mainObj = nil
local eventsData = {}
local id = 194283

function init( obj )
	assert( coroutine.running() == nil )
	assert( obj ~= nil )
	assert( mainObj == nil )
	mainObj = obj
	mainObj:Connect( wx.wxEVT_NULL, function( event )
		if event:GetId() == id then
			local data = assert( eventsData[event:GetInt()] )
			eventsData[event:GetInt()] = nil
			local ok, msg = coroutine.resume( data.coroutine, data.func() )
			assert( ok, debug.traceback( data.coroutine, msg ) )
		end
	end )
end

function execute( f )
	assert( mainObj ~= nil )
	if coroutine.running() == nil then
		return f()
	else
		local e = wx.wxCommandEvent() -- event ID is wxEVT_NULL ; if someone else post this event for another purpose, it will conflict with this system...
		local data = {}
		data.coroutine = coroutine.running()
		data.func = f
		local dataId = #eventsData + 1 -- we don't care if dataId does not increment each time a new event is created ; in any case, we are sure that, by definition of the length operator, eventsData[#eventsData+1] is nil
		eventsData[dataId] = data
		e:SetInt( dataId )
		e:SetId( id )
		wx.wxPostEvent( mainObj, e )
		return coroutine.yield()
	end
end
