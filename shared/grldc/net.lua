-- see copyright notice in grldc.h

local socket = require( "grldc.socket" )

local assert = assert
local setmetatable = setmetatable
local print = print
local error = error
local type = type
local tonumber = tonumber
local tostring = tostring
local loadstring = loadstring
local string = string
local table = table
local pairs = pairs
local globals = _G

module( "grldc.net" )

local listenerMeta = { __index = {} }
local connectionMeta = { __index = {} }

local function debugPrint( ... )
	--print( ... )
end

function serialize( value )
	local t = type( value )
	if t == "number" then
		local res = tostring( value )
		if string.find( value, "[^%.,%-0-9]" ) ~= nil then
			res = "function() return 0/0 end"
		end
		return res
	elseif t == "boolean" then
		if value then return "true" end
		return "false"
	elseif t == "string" then
		return string.format( "%q", value )
	elseif t == "table" then
		local res = "{ "
		for k, v in pairs( value ) do
			res = res.."["..serialize( k ).."] = "..serialize( v )..", "
		end
		res = res.." }"
		return res
	else
		error( "Can't serialize a value of type "..t )
	end
end

local function fixUp( value )
	local t = type( value )
	if t == "table" then
		local res = {}
		for k, v in pairs( value ) do
			res[fixUp(k)] = fixUp(v)
		end
		return res
	elseif t == "function" then
		return value()
	else
		return value
	end
end

function deserialize( str )
	local f = loadstring( "return "..str )
	if f then
		local res = f()
		return fixUp( res )
	else
		error( "Unable to parse serialized value: "..tostring(str) )
	end
end

function bind( address, port )
	local self = { listener = socket.bind( address, port ) }
	setmetatable( self, listenerMeta )
	return self
end

function listenerMeta.__index:accept()
	local res = self.listener:accept()
	if res ~= nil then
		res = { connection = res }
		setmetatable( res, connectionMeta )
		res:init_()
	end
	return res
end

function connect( address, port )
	local self = { connection = socket.connect( address, port ) }
	print( "Connected to "..address..":"..port )
	setmetatable( self, connectionMeta )
	self:init_()
	return self
end

function connectionMeta.__index:init_()
	self.received_ = {}
end

function connectionMeta.__index:getpeername()
	return self.connection:getpeername()
end

function connectionMeta.__index:send( data, channel )
	channel = channel or "default"
	debugPrint( "Sending "..tostring( data ).." on channel "..channel )
	local sdata = serialize( data )
	local packet = channel.."\n"..(#sdata).."\n"..sdata
	local res, msg = self.connection:send( packet )
	if res == nil then
		error( msg, 0 )
	else
		return res
	end
end

function connectionMeta.__index:waitData()
	local needResumeHook = false
	if globals.grldc.suspendHook ~= nil then
		-- the grldc module is loaded, we need to avoid the debug hook to be called from the receive function (because the hook internally uses receive too)
		globals.grldc.suspendHook()
		needResumeHook = true
	end
	local hasData = false
	for _, received in pairs( self.received_ ) do
		if #received > 0 then
			hasData = true
			break
		end
	end
	if hasData then
		if needResumeHook then globals.grldc.resumeHook() end
		return
	end
	debugPrint( "updating channels..." )
	self:updateChannels_( nil )
	if needResumeHook then globals.grldc.resumeHook() end
end

function connectionMeta.__index:receive( channel )
	channel = channel or "default"
	debugPrint( "Blocking receive on channel "..channel )
	local data = self:popReceived_( channel )
	while data == nil do
		self:updateChannels_( nil )
		data = self:popReceived_( channel )
	end
	debugPrint( "received "..tostring(data).." on channel "..channel )
	return data
end

function connectionMeta.__index:tryReceive( channel )
	channel = channel or "default"
	local data = self:popReceived_( channel )
	if data == nil then
		self:updateChannels_( 0 )
		data = self:popReceived_( channel )
	end
	if data ~= nil then
		debugPrint( "received "..tostring(data).." on channel "..channel )
	end
	return data
end

function connectionMeta.__index:updateChannels_( timeout )
	local needResumeHook = false
	if globals.grldc.suspendHook ~= nil then
		-- the grldc module is loaded, we need to avoid the debug hook to be called from the receive function (because the hook internally uses receive too)
		globals.grldc.suspendHook()
		needResumeHook = true
	end
	self.connection:settimeout( timeout )
	local channel, msg = self.connection:receive()
	self.connection:settimeout( nil )
	if channel == nil and msg == "timeout" then
		if needResumeHook then globals.grldc.resumeHook() end
		return
	end
	local size
	if channel ~= nil then
		debugPrint( "receiving..." )
		size, msg = self.connection:receive()
	end
	local data
	if size ~= nil then
		size = assert( tonumber( size ) )
		data, msg = self.connection:receive( size )
	end
	if data == nil then
		if needResumeHook then globals.grldc.resumeHook() end
		error( msg, 0 )
	end
	if channel == "ka" then
		-- special channel keepalive, we simply ignore data received on this channel
	else
		local received = self.received_[channel]
		if received == nil then
			received = {}
			self.received_[channel] = received
		end
		table.insert( received, deserialize( data ) )
		debugPrint( "queued "..tostring(data).." on channel "..channel )
	end
	if needResumeHook then globals.grldc.resumeHook() end
end

function connectionMeta.__index:popReceived_( channel )
	local received = self.received_[channel]
	if received == nil then return nil end
	local res = received[1]
	if res == nil then return nil end
	table.remove( received, 1 )
	return res
end
