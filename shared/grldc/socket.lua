-- see copyright notice in grldc.h

-- This module follows approximately the same interface as the lua socket module, but implements only the subset needed by GRLD for easier port on platforms that lua socket does not support

local socket = require( "socket" )

local setmetatable = setmetatable
local ipairs = ipairs
local table = table
local assert = assert
local print = print
local error = error
local type = type

module( "grldc.socket" )

local listenerMeta = { __index = {} }
local connectionMeta = { __index = {} }

function sleep( time )
	socket.sleep( time )
end

-- Wait until one of the sockets in the recvt list is receiving data, or the timeout has expired (if timeout is nil, wait forever)
function select( recvt, timeout )
	local sockets = {}
	for _, s in ipairs( recvt ) do
		table.insert( sockets, s )
	end
	socket.select( sockets, nil, timeout )
end

-- Start listening for connections. See listener:accept
function bind( address, port )
	local listener = assert( socket.bind( address, port ) )
	listener:settimeout( 0 )
	local self = { listener_ = listener }
	setmetatable( self, listenerMeta )
	return self
end

-- Connects to a listening server. Throws an error with message "connection refused" if the connection is refused by the server.
function connect( address, port )
	print( "Connecting to "..address..":"..port.."..." )
	local con, msg = socket.connect( address, port )
	if not con and msg == "connection refused" then error( msg, 0 ) end
	assert( con, msg )
	con:setoption( "tcp-nodelay", true )
	local res = { connection = con }
	setmetatable( res, connectionMeta )
	return res
end

-- If a client is connecting, returns a connection with it, otherwise returns nil (no waiting)
function listenerMeta.__index:accept()
	local con, msg = self.listener_:accept()
	if con == nil and msg ~= "timeout" then
		error( msg )
	end
	if con == nil then return nil end
	con:setoption( "tcp-nodelay", true )
	--con:setoption( "keepalive", true )
	local res = { connection = con }
	setmetatable( res, connectionMeta )
	return res
end

function connectionMeta.__index:getpeername()
	return self.connection:getpeername()
end

function connectionMeta.__index:send( data )
	return self.connection:send( data )
end

-- Receives a string until first "\n" character if what is nil, or the specified number of bytes if what is a number. The result is returned as a string. If the connection is closed, throws an error "closed"
function connectionMeta.__index:receive( what )
	assert( what == nil or type( what ) == "number" )
	return self.connection:receive( what )
end

-- Sets the timeout for the next receive operations
function connectionMeta.__index:settimeout( timeout )
	self.connection:settimeout( timeout )
end
