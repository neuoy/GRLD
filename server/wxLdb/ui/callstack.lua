-- see copyright notice in wxLdb.lua

local print = print
local wx = require( "wx" )
_G.print = print -- override wx print function with original one

local setmetatable = setmetatable
local table = table
local debug = debug
local xpcall = xpcall
local pairs = pairs
local ipairs = ipairs
local assert = assert
local tostring = tostring
local string = string

module( "ui.callstack" )

local meta = { __index = {} }

function new( ... )
	local res = {}
	setmetatable( res, meta )
	res:init( ... )
	return res
end

function meta.__index:init( parentWidget )
	self.grid = wx.wxGrid( parentWidget, wx.wxID_ANY )
	self.grid:CreateGrid( 0, 4, wx.wxGrid.wxGridSelectRows )
	self.grid:SetRowLabelSize( 0 )
	self.grid:SetColLabelSize( 20 )
	self.grid:SetColLabelValue( 0, "Name" )
	self.grid:SetColSize( 0, 120 )
	self.grid:SetColLabelValue( 1, "Type" )
	self.grid:SetColSize( 1, 50 )
	self.grid:SetColLabelValue( 2, "Source" )
	self.grid:SetColSize( 2, 250 )
	self.grid:SetColLabelValue( 3, "Line" )
	self.grid:SetColSize( 3, 50 )
	self.grid:EnableEditing( false )
	self.grid:Connect( wx.wxEVT_GRID_CELL_LEFT_CLICK, function( event )
		self:runEvents_( "onCallstackClicked", event:GetRow() + 1 )
		event:Skip()
	end )
	self.events = { onCallstackClicked = {} }
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

function meta.__index:getRoot()
	return self.grid
end

function meta.__index:setData( callstack )
	self.grid:DeleteRows( 0, self.grid:GetNumberRows() )
	
	if callstack ~= nil then
		self.grid:AppendRows( #callstack )
		for level, entry in ipairs( callstack ) do
			self.grid:SetCellValue( level - 1, 0, entry.name )
			self.grid:SetCellValue( level - 1, 1, entry.type )
			self.grid:SetCellValue( level - 1, 2, string.gsub( entry.source, "[\n\r]+", " " ) )
			self.grid:SetCellValue( level - 1, 3, entry.line )
		end
	end
end
