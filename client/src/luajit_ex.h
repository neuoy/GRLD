/* see copyright notice in grldc.h */

#ifndef _GRLDC_LUAJIT_EX_H_
#define _GRLDC_LUAJIT_EX_H_

#include "lua.h"

#ifdef LUA_VM_LUAJIT
int lua_pushthread_ex(lua_State *L, lua_State* thread);
#endif

#endif
