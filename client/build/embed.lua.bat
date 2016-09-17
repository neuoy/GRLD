rem = rem --[[
@echo off
cd %~dp0
call ..\..\bin\win_x86\lua5.2\lua52.exe %0 %*
goto :eof
]]

local function embed( name, prefix, srcFileName, dstFileName)
	print("Embedding: "..srcFileName)
	local codeFile = assert( io.open( srcFileName, "rb" ) )
	local code = codeFile:read("*a")
	codeFile:close()

	local out = assert( io.open( dstFileName, "w" ) )
	
	out:write( "// This file contains lua code encoded from "..srcFileName.."\n" )
	out:write( "// Use script embed.lua.bat to re-generate this file if you changed the source code\n" )
	out:write( "\n" )

	out:write( "const char* "..prefix.."get"..name.."Code()\n" )
	out:write( "{\n" )
	out:write( "\tstatic unsigned char code[] =\n" )
	out:write( "\t{\n" )
	out:write( "\t\t" )

	local charsInLine = 0
	string.gsub( code, ".", function( p )
		local c = string.byte(p)
		out:write( string.format( "0x%02x, ", c ) )
		charsInLine = charsInLine + 1
		if charsInLine == 16 then
			out:write( "\n\t\t" )
			charsInLine = 0
		end
	end )

	out:write( "\n" )
	out:write( "\t};\n" )
	out:write( "\treturn (const char*)code;\n" )
	out:write( "}\n" )

	out:write( "int "..prefix.."get"..name.."CodeSize()\n" )
	out:write( "{\n" )
	out:write( "\treturn "..#code..";\n" )
	out:write( "}\n" )

	out:close()
end

embed( "ldb", "GRLDC_", "../src/grldc_ldb.lua", "../src/grldc_ldb.lua.c" )
embed( "utilities", "GRLDC_", "../../shared/grldc/utilities.lua", "../src/grldc_utilities.lua.c" )
embed( "net", "GRLDC_", "../../shared/grldc/net.lua", "../src/grldc_net.lua.c" )
embed( "socket", "GRLDC_", "../../shared/grldc/socket.lua", "../src/grldc_socket.lua.c" )
