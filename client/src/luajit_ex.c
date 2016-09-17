/* see copyright notice in grldc.h */

#include "luajit_ex.h"

#ifdef LUA_VM_LUAJIT
#include "../../../luajit/src/lj_obj.h"
#include "../../../luajit/src/lj_state.h"

int lua_pushthread_ex(lua_State *L, lua_State* thread)
{
  lua_pushthread( L );
  setthreadV(L, L->top, thread);
  return 1;
}
#endif
