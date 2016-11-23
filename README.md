### NOTE
This is a modified fork of the [original GRLD project](https://github.com/neuoy/GRLD/master/) for personal use and should be considered **unstable**. Anyone looking to use GRLD should check out the [official repo](https://github.com/neuoy/GRLD/master/) unless they are specifically looking for the modifications provided in this version. The original readme contents remain below. 


# GRLD
Graphical Remote Lua Debugger, a debugger for the lua programming language

Documentation is embedded in the git repository and can also be [browsed online](http://htmlpreview.github.io/?https://raw.githubusercontent.com/neuoy/GRLD/master/doc/index.html).

The debugger was created to debug lua code on video game consoles (Xbox 360 and DS), but can of course be used for many other purposes. The network layer may be a bit overkill for local debugging, but works well nonetheless. It can also work through other communication layers (such as USB debugging connection) with little adaptations.

The debugger features step-by-step execution, breakpoints, complete lua state exploration (call stack, global and local variables, upvalues, coroutines, etc.), and custom lua expression evaluation (which can have side effects in the debugged application).

The original distribution was commercial (a $50 fee was aksed for each developer), but as I had less and less time to dedicate to improvement and support, I stopped this commercial activity, and felt that it was time to release it under an open source license, so that it can still be of use to anyone working with lua. I hope you'll enjoy it. Though I don't intend to further work on this project myself at this time, feel free to fork and send your pull-requests if you have improvements or bug fixes to propose.
