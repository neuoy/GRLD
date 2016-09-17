/* see copyright notice in grldc.h */

#include "grldc.h"

#ifdef _MSC_VER
#define WIN32_LEAN_AND_MEAN
#include "windows.h" // for GetTickCount
#else
#include <time.h>
unsigned int GetTickCount()
{
	struct timespec t;
	clock_gettime( CLOCK_MONOTONIC, &t );
	unsigned int ms = (unsigned int)(t.tv_nsec / (long)1000000);
	ms += (unsigned int)(t.tv_sec * 1000);
	return ms;
}
#endif

#include "lauxlib.h"
#include "lstate.h"
#include "luajit_ex.h"
#include "lapi.h"

#if !defined( LUA_VM_LUAJIT ) && LUA_VERSION_NUM < 502
#define GRLD_ENABLE_STANDARD_LUA_VM_OPTIMIZATIONS // remove this if you use another VM that is incompatible with low level optimizations
#endif

#define GRLD_ENABLE_THREAD_UNSAFE_OPTIMIZATIONS // remove this if you use GRLD on more than one lua state at the same time, and each state runs from a different system thread

#ifdef _DEBUG
#define assert( cond ) { if( !(cond) ) assertImpl( #cond, __FILE__, __LINE__ ); }
#else
#define assert( cond ) {}
#endif

typedef char bool;
const bool false = 0;
const bool true = 1;

#ifdef _DEBUG
void assertImpl( const char* cond, const char* file, int line )
{
	printf( "Assertion failed: %s\n%s(%d)\n", cond, file, line );
	__asm
	{
		int 3;
	}
}
#endif

const char* const LUA_GRLDCLIBNAME = "grldc";

#if LUA_VERSION_NUM < 502
#define api_incr_top(L)   {api_check(L, L->top < L->ci->top); L->top++;}
int GRLDC_getmainthread( lua_State* L )
{
	// I did not find a way to push the main thread on the stack of L by using only the public lua API
	// lua_pushthread almost does the job, but unfortunately it pushes the thread on the stack of the same thread
	// The consequence is that this code is specific to each VM

	#ifdef LUA_VM_LUAJIT
	lua_pushthread_ex( L, G(L)->mainthread );
	#else
	lua_lock(L);
	setthvalue(L, L->top, G(L)->mainthread);
	api_incr_top(L);
	lua_unlock(L);
	#endif
	
	return 1;
}
#endif

typedef enum
{
	SM_None = 0,
	SM_Inside = 1,
	SM_Over = 2,
	SM_Outside = 3
} StepMode;

typedef struct
{
	bool hookActive;
	bool inLdb;
	#ifndef LUA_VM_LUAJIT
	bool hookLineEmulationEnabled;
	#endif
	unsigned int lastRunningUpdate;
	StepMode stepMode;
	lua_State* stepThread;
	int initialCallstackDepth;
	int callstackDepth;
	const char* lastBreakFile;
	int lastBreakLine;

	#ifdef GRLD_ENABLE_STANDARD_LUA_VM_OPTIMIZATIONS
	// cached data (these values must not be garbaged collected)
	TValue breakpointAliases;
	TValue currentFileBreakpoints;
	const char* currentFile;
	#endif
} DebugState;

void updateCallstackDepth( lua_State* L, DebugState* state )
{
	lua_Debug outAR;
	while( lua_getstack( L, state->callstackDepth, &outAR ) )
		++state->callstackDepth;
	while( state->callstackDepth > 0 && !lua_getstack( L, state->callstackDepth, &outAR ) )
		--state->callstackDepth;
}

DebugState* getDebugState( lua_State* L )
{
	DebugState* state;

	#ifdef GRLD_ENABLE_THREAD_UNSAFE_OPTIMIZATIONS
	// these static variables could be protected by a mutex so that the optimization becomes thread safe, but the mutex overhead may be bigger than the time saved by the optimization...
	// if your platform supports it, the best way to handle multithreading would be to store these variable as thread local data
	static DebugState* lastDebugState = NULL;
	static lua_State* lastLuaState = NULL;
	if( lastLuaState == L )
		return lastDebugState;
	#endif

	lua_getfield( L, LUA_REGISTRYINDEX, "GRLDC_DebugState" );
	state = (DebugState*)lua_touserdata( L, -1 );
	assert( state != NULL );
	lua_pop( L, 1 );

	#ifdef GRLD_ENABLE_THREAD_UNSAFE_OPTIMIZATIONS
	lastDebugState = state;
	lastLuaState = L;
	#endif

	return state;
}

#ifdef LUA_VM_LUAJIT
void hook( lua_State *L, lua_Debug *ar )
{
	DebugState* state = getDebugState( L );
#else
// standard lua misses a LUA_HOOKLINE event after returning from a function (it only sends the event for the next line executed after the return, not the line that called the function). This means users are not reminded where they were before the function was called, which is not intuitive.
// the following code emulates this missing event

void hookImpl_( lua_State *L, lua_Debug *ar, DebugState* state );
void hook( lua_State *L, lua_Debug *ar )
{
	DebugState* state = getDebugState( L );

	if( ar->event == LUA_HOOKCOUNT )
		ar->event = LUA_HOOKLINE;
	hookImpl_( L, ar, state );
	if( state->stepMode != SM_None && !state->hookLineEmulationEnabled && (ar->event == LUA_HOOKRET
	#if LUA_VERSION_NUM < 502 // LUA_HOOKTAILRET does not exist starting from lua5.1
		|| ar->event == LUA_HOOKTAILRET) )
	#else
		) )
	#endif
	{
		state->hookLineEmulationEnabled = true;
		lua_sethook( L, hook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKLINE | LUA_MASKCOUNT, 1 );
	}
	else if( state->hookLineEmulationEnabled )
	{
		state->hookLineEmulationEnabled = false;
		lua_sethook( L, hook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKLINE, 0 );
	}
}

void hookImpl_( lua_State *L, lua_Debug *ar, DebugState* state )
{
#endif

	unsigned int now = 0;
	bool needBreak = false;

	if( !state->hookActive )
		return;

	// check if we are executing code inside GRLDC (we don't want to break in GRLD internal code)
	if( state->inLdb )
	{
		int err = 0;

		//luaL_dostring( L, "print( debug.traceback() )" );
		lua_getglobal( L, "grldc" );
		lua_getfield( L, -1, "getAppLevel_" );
		lua_remove( L, -2 );
		lua_pushthread( L );
		lua_pushinteger( L, 0 );
		err = lua_pcall( L, 2, 1, 0 );
		if( err )
		{
			const char* msg = lua_tostring( L, -1 );
			printf( "Error executing grldc.getAppLevel_: %s\n", msg );
			assert( false );
		}

		if( lua_isnil( L, -1 ) )
		{
			//int oldCsDepth = state->callstackDepth;

			state->inLdb = false;
			//luaL_dostring( L, "print( \"leaving grldc at \"..debug.traceback() )" );
			//updateCallstackDepth( L, state );
			//state->initialCallstackDepth += state->callstackDepth - oldCsDepth;
		}
		else
		{
			//int level = lua_tointeger( L, -1 );
			//printf( "current app level: %d\n", level );
		}
		lua_pop( L, 1 );
	}

	if( state->inLdb )
		return;

	//updateCallstackDepth( L, state );

	// periodically check if we have received something from the server
	now = GetTickCount();
	if( now > state->lastRunningUpdate + 250 ) // update running requests only every 250ms
	{
		int err = 0;
		state->lastRunningUpdate = now;
		lua_getglobal( L, "grldc" );
		lua_getfield( L, -1, "updateRunningRequests_" );
		lua_remove( L, -2 );
		err = lua_pcall( L, 0, 0, 0 );
		if( err )
		{
			const char* msg = lua_tostring( L, -1 );
			printf( "Error executing grldc.updateRunningRequests: %s\n", msg );
			assert( false );
		}
	}
	

	if( ar->event == LUA_HOOKLINE && state->stepMode != SM_None )
	{
		bool needCheckThread = state->stepMode != SM_Inside;
		bool deadThread = false;
		
		// check if the coroutine we are monitoring is dead (in which case we break, whatever coroutine we are in)
		if( needCheckThread && state->stepThread != L && state->stepThread != G(L)->mainthread )
		{
			assert( state->stepThread != NULL );
			switch( lua_status(state->stepThread) )
			{
				case LUA_YIELD:
					break;
				case 0:
				{
					lua_Debug ar;
					if( lua_getstack( state->stepThread, 0, &ar) <= 0  /* does it have frames? */
						&& lua_gettop( state->stepThread ) == 0 )
						deadThread = true;
					break;
				}
				default:  /* some error occured */
					deadThread = true;
			}
		}

		// update stack depth to know if we need to break because we are stepping in lua code
		if( !needCheckThread || deadThread || state->stepThread == L )
		{
			//printf( "event %d, line %d\n", ar->event, ar->currentline );
			//luaL_dostring( L, "print( debug.traceback() )" );

			int stepDepth = -1;
			if( deadThread )
			{
				// always break if the tracked coroutine is dead
			}
			else
			{
				updateCallstackDepth( L, state );

				stepDepth = state->callstackDepth - state->initialCallstackDepth;
			}
				

			if( state->stepMode == SM_Inside )
			{
				if( ar->currentline >= 0 || stepDepth != 0 ) // reject useless emulated HOOKLINE events
					needBreak = true;
			}
			else if( state->stepMode == SM_Over && stepDepth <= 0 && ar->event == LUA_HOOKLINE )
			{
				lua_getinfo( L, "S", ar );
				if( ar->currentline != state->lastBreakLine || ar->source != state->lastBreakFile ) // don't break twice on the same line in step over mode
				{
					if( ar->currentline >= 0 || stepDepth < 0 ) // reject useless emulated HOOKLINE events
						needBreak = true;
				}
			}
			else if( state->stepMode == SM_Outside && stepDepth < 0 )
				needBreak = true;
		}
	}

	// check if we have hit a breakpoint
	if( !needBreak && ar->event == LUA_HOOKLINE )
	{
		lua_getinfo( L, "S", ar );
		#ifdef GRLD_ENABLE_STANDARD_LUA_VM_OPTIMIZATIONS
		if( ar->source == state->currentFile )
		{
			lua_lock( L );
			setobj2s( L, L->top, &state->currentFileBreakpoints );
			api_incr_top( L );
			lua_unlock( L );
		}
		else
		{
			lua_lock( L );
			//lua_getfield( L, LUA_REGISTRYINDEX, "GRLDC_breakPointAliases" );
			setobj2s( L, L->top, &state->breakpointAliases );
			api_incr_top( L );
			lua_unlock( L );
			lua_getfield( L, -1, ar->source );
			lua_remove( L, -2 );
		}
		#else
		lua_getfield( L, LUA_REGISTRYINDEX, "GRLDC_breakPointAliases" );
		lua_getfield( L, -1, ar->source );
		lua_remove( L, -2 );
		#endif
		if( lua_isnil( L, -1 ) )
		{
			if( ar->source[0] == '@' )
			{
				int err = 0;
				lua_pop( L, 1 );
				lua_getglobal( L, "grldc" );
				lua_getfield( L, -1, "registerSourceFile_" );
				lua_remove( L, -2 );
				lua_pushstring( L, ar->source );
				err = lua_pcall( L, 1, 1, 0 );
				if( err )
				{
					const char* msg = lua_tostring( L, -1 );
					printf( "Error executing grldc.registerSourceFile_: %s\n", msg );
					assert( false );
				}
			}
		}
		if( !lua_isnil( L, -1 ) )
		{
			lua_pushinteger( L, ar->currentline );
			lua_gettable( L, -2 );
			needBreak = (lua_toboolean( L, -1 ) != 0);
			lua_pop( L, 1 );
		}

		#ifdef GRLD_ENABLE_STANDARD_LUA_VM_OPTIMIZATIONS
		if( state->currentFile != ar->source )
		{
			state->currentFile = ar->source;
			lua_lock( L );
			state->currentFileBreakpoints = *(L->top-1);
			lua_unlock( L );
		}
		#endif

		lua_pop( L, 1 );
	}

	// break execution, if needed
	if( needBreak )
	{
		int err = 0;

		updateCallstackDepth( L, state );

		lua_getinfo( L, "Sl", ar );
		state->lastBreakFile = ar->source;
		state->lastBreakLine = ar->currentline;

		lua_getglobal( L, "grldc" );
		lua_getfield( L, -1, "breakNow" );
		lua_remove( L, -2 );
		err = lua_pcall( L, 0, 0, 0 );
		if( err )
		{
			const char* msg = lua_tostring( L, -1 );
			printf( "Error executing grldc.breakNow: %s\n", msg );
			assert( false );
		}
	}
}

int GRLDCI_setHook( lua_State* L )
{
	lua_State* co = lua_tothread( L, -1 );
	lua_sethook( co, hook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKLINE, 0 );
	return 0;
}

int GRLDCI_setHookActive( lua_State* L )
{
	DebugState* state = getDebugState( L );
	state->hookActive = (lua_toboolean( L, -1 ) != 0);
	if( state->hookActive )
		state->inLdb = true;
	//unsigned char oldAllowHook = L->allowhook;
	//L->allowhook = 0;
	//luaL_dostring( L, "print( debug.traceback() )" );
	//L->allowhook = oldAllowHook;
	return 0;
}

int GRLDCI_setStepMode( lua_State* L )
{
	DebugState* state = getDebugState( L );
	state->stepMode = (StepMode)lua_tointeger( L, -2 );
	state->stepThread = lua_tothread( L, -1 );
	return 0;
}

int GRLDCI_setStepDepth( lua_State* L )
{
	DebugState* state = getDebugState( L );
	int stepDepth = lua_tointeger( L, -1 );
	//updateCallstackDepth( L, state );
	state->initialCallstackDepth = state->callstackDepth - stepDepth;
	assert( state->initialCallstackDepth >= 0 );
	return 0;
}

int GRLDCI_init( lua_State* L )
{
	DebugState* state = getDebugState( L );
	lua_pushvalue( L, -1 );
	assert( lua_istable( L, -1 ) );
	#ifdef GRLD_ENABLE_STANDARD_LUA_VM_OPTIMIZATIONS
	lua_lock( L );
	state->breakpointAliases = *(L->top-1);
	lua_unlock( L );
	#endif
	lua_setfield( L, LUA_REGISTRYINDEX, "GRLDC_breakPointAliases" );
	return 0;
}

const luaL_Reg GRLDClib[] =
{
	#if LUA_VERSION_NUM < 502
	{ "getmainthread", GRLDC_getmainthread },
	#endif
	{ NULL, NULL }
};

const luaL_Reg GRLDCIlib[] = // internal functions
{
	{ "setHook", GRLDCI_setHook },
	{ "setHookActive", GRLDCI_setHookActive },
	{ "setStepMode", GRLDCI_setStepMode },
	{ "setStepDepth", GRLDCI_setStepDepth },
	{ "init", GRLDCI_init },
	{ NULL, NULL }
};

void registerLuaLib( lua_State* L, const char* libName, const char* code, int codeSize )
{
	char sourceName[128];
	int res = 0;

	lua_getglobal( L, "package" );
	lua_getfield( L, -1, "preload" );

	sprintf( sourceName, "%s embedded code", libName );
	res = luaL_loadbuffer( L, code, codeSize, sourceName );
	if(res == LUA_ERRSYNTAX)
	{
		const char* message = lua_tostring( L, -1 );
		printf("syntax error: %s\n", message);
	}
	else if (res == LUA_ERRMEM)
	{
		printf("memory error\n");
	}
	assert( res == 0 );

	lua_setfield( L, -2, libName );

	lua_pop( L, 3 );
};

// declare embedded source accessors (they are implemented in the corresponding cpp file)
const char* GRLDC_getldbCode();
int GRLDC_getldbCodeSize();
const char* GRLDC_getutilitiesCode();
int GRLDC_getutilitiesCodeSize();
const char* GRLDC_getnetCode();
int GRLDC_getnetCodeSize();
const char* GRLDC_getsocketCode();
int GRLDC_getsocketCodeSize();

int luaopen_grldc( lua_State* L )
{
	DebugState* state = (DebugState*)lua_newuserdata( L, sizeof( DebugState ) );
	const char* ldbCode = NULL;
	char* ldbDCode = NULL;
	int i;
	int res = 0;

	state->hookActive = false;
	#ifndef LUA_VM_LUAJIT
	state->hookLineEmulationEnabled = false;
	#endif
	state->lastRunningUpdate = 0;
	state->stepMode = SM_None;
	state->stepThread = NULL;
	state->callstackDepth = state->initialCallstackDepth = 1;
	state->inLdb = true;
	state->lastBreakLine = -100;
	#ifdef GRLD_ENABLE_STANDARD_LUA_VM_OPTIMIZATIONS
	state->breakpointAliases.tt = LUA_TNIL;
	state->currentFileBreakpoints.tt = LUA_TNIL;
	state->currentFile = NULL;
	#endif

	lua_setfield( L, LUA_REGISTRYINDEX, "GRLDC_DebugState" );

	// register dependent libraries
	registerLuaLib( L, "grldc.utilities", GRLDC_getutilitiesCode(), GRLDC_getutilitiesCodeSize() );
	registerLuaLib( L, "grldc.net", GRLDC_getnetCode(), GRLDC_getnetCodeSize() );
	registerLuaLib( L, "grldc.socket", GRLDC_getsocketCode(), GRLDC_getsocketCodeSize() );

	 // public GRLDC functions
	luaL_register(L, LUA_GRLDCLIBNAME, GRLDClib);

	// internal GRLDC functions (stored in GRLDC.internal_ table)
	lua_newtable( L );
	lua_pushvalue( L, -1 );
	lua_setfield( L, -3, "internal_" );
	luaL_register(L, NULL, GRLDCIlib );
	lua_pop( L, 1 );

	// add lua functions to the module
	ldbCode = GRLDC_getldbCode();
	res = luaL_loadbuffer( L, ldbCode, GRLDC_getldbCodeSize(), "ldb embedded code" );
	lua_remove( L, -2 );
	assert( res == 0 );
	lua_call( L, 0, 0 );

	return 1; // return GRLDC table
}
