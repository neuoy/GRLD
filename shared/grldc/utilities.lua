-- see copyright notice in grldc.h

local string = string
local assert = assert
local print = print

module( "grldc.utilities" )

function normalizePath( path, base )
	--print( "Normalizing "..path )
	assert( string.sub( path, 1, 1 ) ~= "@" )
	local n
	
	path = string.gsub(path, "\\", "/")
	path = string.lower( path )
	
	--make sure the drive letter, if any, is upper case
	if string.find(path, "^.:/") == 1 then
		path = string.upper(string.sub(path, 1, 1))..string.sub(path, 2)
	elseif string.sub( path, 1, 1 ) == "/" then
		-- absolute linux-style path, nothing to do
	elseif string.sub( path, 1, 2 ) == "./" then
		-- explicit relative path, nothing to do
	else
		path = "./"..path
	end
	
	if string.sub( path, 1, 2 ) == "./" and base ~= nil then
		-- if the lfs module is available, we convert relative path to absolute
		path = base..string.sub( path, 2 )
		path = string.gsub(path, "\\", "/")
	end
	
	--add end "/" if needed (simplifies pattern matchings below)
	if string.sub(path, -1) ~= "/" then
		path = path.."/"
	end
	
	--replace "//" by "/"
	n = 1
	while n > 0 do
		path, n = string.gsub(path, "//", "/", 1)
	end
	
	--replace "/./" by "/"
	n = 1
	while n > 0 do
		path, n = string.gsub(path, "/%./", "/", 1)
	end
	
	--replace "/something/../" by "/"
	n = 1
	while n > 0 do
		n = 0
		local s = 0, e
		local something = ".."
		while something == ".." do
			s, e, something = string.find( path, "/([^/]*)/%.%./", s+1 )
		end
		if s ~= nil then
			n = 1
			path = string.sub( path, 1, s-1 ).."/"..string.sub( path, e+1 )
		end
	end
	
	path = string.sub( path, 1, -2 ) -- remove end "/"
	--print( path )
	
	return path
end
