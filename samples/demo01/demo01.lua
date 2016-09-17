
-- Initialize search paths so that lua can find the required DLLs

-- path to socket.dll
package.cpath = package.cpath..";../../client/3rdparty/lua5.2/?.dll"

-- path to grldc.dll
package.cpath = package.cpath..";../../client/visual/Debug/?.dll"

-- Load the GRLD client package and connect to the server which we assume to be running on the same machine and listening on port 4242
require( "grldc" )
grldc.connect( "127.0.0.1", 4242, "demo01" )

-- Now execute some basic lua statements with no particular purpose, just to demonstrate the debugger functionalities

-- some variables that can be explored from the server

local someTable = { "a", "a big string that won't be downloaded until requested by the user", subtable = setmetatable( { "another table" }, { "and its metatable" } ) }

someGlobalVariable = "Hello world"

local aRecursiveTable = { test = someTable }
aRecursiveTable.r = aRecursiveTable

local tableWithComplexKeys = { [aRecursiveTable] = function() print( "bouh" ) end }
tableWithComplexKeys[tableWithComplexKeys[aRecursiveTable]] = someTable

-- some functions to demonstrate stepping in code

function test()
	local a = 1
	return a
end

local function test1()
	local b = 2
	test()
	return b
end

function testMulCall( a, b )
	local c = a + b
	print( c )
end

function testTail()
	return test()
end

-- lua call
test()

-- C call
print( "a" )

-- tail call
testTail()

-- multiple calls, same line
testMulCall( test(), test1() )

-- and this file does not demonstrates all the debugger features, you can debug code that uses coroutines, userdata, multiple source files, directory mappings to make the server use a copy of the source files if the debugged program does not run on the same machine, etc.

print( "done" )
