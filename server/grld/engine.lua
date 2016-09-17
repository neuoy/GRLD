-- see copyright notice in wxLdb.lua

local net = require( "grldc.net" )
local socket = require( "grldc.socket" )

local print = print
local assert = assert
local pairs = pairs
local ipairs = ipairs
local type = type
local debug = debug
local xpcall = xpcall
local setmetatable = setmetatable
local error = error
local table = table
local tonumber = tonumber

module( "grld.engine" )

local clients
local activeClient
local nextClient = 1
local listeners = {}
local nextListener = 1
local events =
{
	onNewClient = {},
	onClientBreak = {},
	onClientLost = {},
}

local clientMeta = { __index = {} }

local function addClient( listenerIdx, connection, name )
	print( "New client connected on listener "..listenerIdx.." : assigned client ID "..nextClient )
	local client = { clientId = nextClient, listenerIdx = listenerIdx, connection = connection, status_ = "running", activeThread_ = "current", name_ = name, ip_ = connection:getpeername(), breakPoints_ = {} }
	setmetatable( client, clientMeta )
	clients[nextClient] = client
	if activeClient == nil or clients[activeClient] == nil then
		setactiveclient( nextClient )
	end
	runEvents_( "onNewClient", nextClient )
	nextClient = nextClient + 1
end

function init()
	print( "Initializing grld.engine..." )
	assert( clients == nil, "Trying to initialize grld.engine twice" )
	clients = {}
end

function initialized()
	return clients ~= nil
end

function listen( address, port )
	print( "Listening for new clients on "..address..":"..port..", listener ID "..nextListener )
	local listener = net.bind( address, port )
	listeners[nextListener] = listener
	nextListener = nextListener + 1
end

function registerEvent( eventName, callback )
	assert( events[eventName] ~= nil, "Unknown event name "..eventName )
	table.insert( events[eventName], callback )
end

function runEvents_( eventName, ... )
	for _, callback in pairs( events[eventName] ) do
		callback( ... )
	end
end

function update( timeout )
	local active = false
	
	for idx, listener in pairs( listeners ) do
		local connection = listener:accept()
		if connection ~= nil then
			local name = connection:receive()
			addClient( idx, connection, name )
			active = true
		end
	end
	
	local sockets = {}
	for idx, client in pairs( clients ) do
		table.insert( sockets, client.connection )
	end
	socket.select( sockets, timeout )
	
	for idx, client in pairs( clients ) do
		local ok, msg = xpcall( function() active = active or client:update() end, client.errorHandler )
		if not ok then
			active = true
			if msg == "closed" then
				print( "Connection with client "..idx.." closed" )
				runEvents_( "onClientLost", idx )
				clients[idx] = nil
			else
				error( msg )
			end
		end
	end
	
	return active
end

function clientMeta.__index:checkConnection()
	self.connection:send( "", "ka" )
end

function clientMeta.__index:update()
	local command = self.connection:tryReceive()
	if command ~= nil then
		self["cmd_"..command]( self )
		return true
	end
	return false
end

function clientMeta.__index:setactivethread( thread )
	self.activeThread_ = thread
end

function clientMeta.__index:getactivethread()
	return self.activeThread_
end

function clientMeta.__index:getcurrentthread()
	assert( self.status_ == "break", "Bad status: "..self.status_ )
	self.connection:send( "currentthread" )
	return self.connection:receive()
end

function clientMeta.__index:name()
	return self.name_
end

function clientMeta.__index:ip()
	return self.ip_
end

function clientMeta.__index:status()
	return self.status_
end

function clientMeta.__index:source()
	assert( self.status_ == "break", "Bad status: "..self.status_ )
	return self.source_
end

function clientMeta.__index:line()
	assert( self.status_ == "break", "Bad status: "..self.status_ )
	return self.line_
end

function clientMeta.__index:setbreakpoint( source, line, value )
	local setValue = value or nil
	local sourceBp = self.breakPoints_[source]
	if sourceBp == nil then
		sourceBp = {}
		self.breakPoints_[source] = sourceBp
	end
	sourceBp[line] = setValue
	self.connection:send( "setbreakpoint", "running" )
	self.connection:send( { source = source, line = line, value = value }, "running" )
end

function clientMeta.__index:callstack()
	assert( self.status_ == "break", "Bad status: "..self.status_ )
	self.connection:send( "callstack" )
	self.connection:send( self.activeThread_ )
	return self.connection:receive()
end

function clientMeta.__index:breakpoints()
	--if self.status_ == "break" then
	--	self.connection:send( "breakpoints" )
	--	self.breakPoints_ = self.connection:receive()
	--end
	return self.breakPoints_
end

function clientMeta.__index:locals( level )
	assert( self.status_ == "break", "Bad status: "..self.status_ )
	self.connection:send( "locals" )
	self.connection:send( self.activeThread_ )
	self.connection:send( level )
	return self.connection:receive()
end

function clientMeta.__index:upvalues( level )
	assert( self.status_ == "break", "Bad status: "..self.status_ )
	self.connection:send( "upvalues" )
	self.connection:send( self.activeThread_ )
	self.connection:send( level )
	return self.connection:receive()
end

function clientMeta.__index:evaluate( expr, level )
	assert( self.status_ == "break", "Bad status: "..self.status_ )
	self.connection:send( "evaluate" )
	self.connection:send( expr )
	self.connection:send( self.activeThread_ )
	self.connection:send( level )
	return self.connection:receive()
end

function clientMeta.__index:releaseValue( id )
	self.connection:send( "releaseValue", "running" )
	self.connection:send( id, "running" )
end

function clientMeta.__index:getValue( id )
	assert( self.status_ == "break", "Bad status: "..self.status_ )
	self.connection:send( "getValue" )
	self.connection:send( id )
	return self.connection:receive()
end

function clientMeta.__index:coroutines()
	assert( self.status_ == "break", "Bad status: "..self.status_ )
	self.connection:send( "coroutines" )
	return self.connection:receive()
end

for _, command in ipairs( { "run", "stepover", "stepin", "stepout" } ) do
	clientMeta.__index[command] = function( self )
		assert( self.status_ == "break", "Bad status: "..self.status_ )
		self.connection:send( command )
		--assert( self.connection:receive() == "ack_"..command )
		self.status_ = "running"
	end
end

function clientMeta.__index:breaknow()
	assert( self.status_ == "running", "Bad status: "..self.status_ )
	self.connection:send( "break", "running" )
end

function clientMeta.__index:cmd_synchronize()
	self.connection:send( 0 )
	self.connection:send( true )
end

function clientMeta.__index:cmd_break()
	assert( self.status_ == "running" )
	--self.connection:send( "ack_break" )
	self.source_ = self.connection:receive()
	self.line_ = self.connection:receive()
	self.status_ = "break"
	assert( type( self.source_ ) == "string" )
	assert( type( self.line_ ) == "number" )
	print( "Client "..self.clientId.." break at "..self.source_.."("..self.line_..")" )
	runEvents_( "onClientBreak", self.clientId )
end

function clientMeta.__index.errorHandler( msg )
	if msg == "closed" then return msg end
	return debug.traceback( msg )
end

function listclients()
	local res = {}
	for idx, client in pairs( clients ) do
		table.insert( res, { clientId = idx } )
	end
	return res
end

function getactiveclient()
	return activeClient or 0
end

function setactiveclient( idx )
	idx = assert( tonumber( idx ) )
	print( "Setting active client: "..idx )
	activeClient = idx
	if clients[idx] == nil then
		print( "Warning: no such client" )
	end
end

function getClient( clientId )
	return clients[clientId]
end

for _, func in ipairs( { "name", "ip", "status", "source", "line", "callstack", "locals", "coroutines", "run", "breaknow", "stepover", "stepin", "stepout", "setactivethread", "getactivethread", "getcurrentthread" } ) do
	_M[func] = function( ... )
		local idx = getactiveclient()
		local client = clients[idx]
		if client == nil then return "no such client" end
		return client[func]( client, ... )
	end
end

function shutdown()
	print( "Shuting down grld.engine..." )
	clients = nil
	listeners = {}
end
