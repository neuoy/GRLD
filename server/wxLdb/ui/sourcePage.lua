-- see copyright notice in wxLdb.lua

local ui =
{
	editor = require( "ui.editor" ),
}

local lfs = require( "lfs" )

local assert = assert
local setmetatable = setmetatable
local string = string
local pairs = pairs
local print = print
local table = table
local os = os

module( "ui.sourcePage" )

local meta = { __index = {} }

function new( parent, source )
	local page = {}
	setmetatable( page, meta )
	page.editor = ui.editor.new( parent )
	page.events = { onBreakPointChanged = {} }
	page:setSource_( source )
	page.editor.breakpointCallback = function( line )
		page:runEvents_( "onBreakPointChanged", line )
	end
	return page
end

function meta.__index:getRoot()
	return self.editor.editor
end

function meta.__index:setSource_( source )
	assert( string.sub( source, 1, 1 ) == "@" )
	local fileName = string.sub( source, 2 )
	self.source = source
	self.editor.editor:SetReadOnly( false )
	self.sourceDate = lfs.attributes( fileName, "modification" ) or 0
	self.editor.editor:LoadFile( fileName )
	self.editor.editor:SetReadOnly( true )
	self.lastUpdate = os.time()
end

function meta.__index:update()
	local now = os.time()
	if now > self.lastUpdate + 2 then
		self.lastUpdate = now
		assert( string.sub( self.source, 1, 1 ) == "@" )
		local fileName = string.sub( self.source, 2 )
		
		local newDate = lfs.attributes( fileName, "modification" ) or 0
		if newDate > self.sourceDate then
			print( "reloading source file "..fileName )
			self.sourceDate = newDate
			self.editor.editor:SetReadOnly( false )
			self.editor.editor:LoadFile( fileName )
			self.editor.editor:SetReadOnly( true )
			return true
		end
	end
	
	return false
end

function meta.__index:setFocus( line )
	self.editor.editor:GotoLine( line-4 )
	self.editor.editor:GotoLine( line+4 )
	self.editor.editor:GotoLine( line-1 )
end

function meta.__index:getFocus()
	local ed = self.editor.editor
	return ed:GetCurrentLine() + 1
end

function meta.__index:setCurrentLine( line )
	local editor = self.editor.editor
	if self.currentLine == line then return end
	
	if self.currentLine ~= nil then
		editor:MarkerDelete( self.currentLine - 1, ui.editor.markers.currentLine )
	end
	
	self.currentLine = line
	
	if self.currentLine ~= nil then
		editor:MarkerAdd( self.currentLine - 1, ui.editor.markers.currentLine )
	end
end

function meta.__index:addOtherLine( line )
	self.editor.editor:MarkerAdd( line - 1, ui.editor.markers.otherLine )
end

function meta.__index:clearOtherLines()
	self.editor.editor:MarkerDeleteAll( ui.editor.markers.otherLine )
end

function meta.__index:addBreakPoint( line, bad )
	local mt = ui.editor.markers.breakpoint
	if bad then
		mt = ui.editor.markers.badBreakpoint
	end
	self.editor.editor:MarkerAdd( line - 1, mt )
end

function meta.__index:clearBreakPoints()
	self.editor.editor:MarkerDeleteAll( ui.editor.markers.breakpoint )
	self.editor.editor:MarkerDeleteAll( ui.editor.markers.badBreakpoint )
end

function meta.__index:clearMarkers()
	self.currentLine = nil
	self.editor.editor:MarkerDeleteAll( ui.editor.markers.currentLine )
	self.editor.editor:MarkerDeleteAll( ui.editor.markers.otherLine )
end

function meta.__index:registerEvent( eventName, callback )
	assert( self.events[eventName] ~= nil, "Unknown event name "..eventName )
	table.insert( self.events[eventName], callback )
end

function meta.__index:runEvents_( eventName, ... )
	for _, callback in pairs( self.events[eventName] ) do
		callback( ... )
	end
end

function meta.__index:destroy()
	self.editor:destroy()
end
