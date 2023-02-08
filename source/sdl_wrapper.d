module sdl_wrapper;

// Wrapper for SDL2 via bindbc-sdl

import bindbc.sdl;
import std.traits;
import std.exception;
import std.string;
import palette;

/// SDL-flavored exception class, automatically pulls exception
/// message / description from `SDL_GetError()`.
class SDLException : Exception {
    this(string msg=null, string file=__FILE__, size_t line=__LINE__, Throwable next=null) nothrow {
        msg = (msg ? fromStringz(SDL_GetError()).idup : msg);
        super(msg, file, line, next);
    }
}

/// Helper method alå `std.exception.enforce` that is intended for
/// wrapping calls to SDL functions that can potentially fail, to
/// adapt legacy C-style return code errors into modern exceptions.
/// Beyond changing the default exception class to SDLException, the
/// only other difference with `std.exception.enforce` is that it adapts
/// to SDL's 0-means-success policy for functions that use integer return
/// codes. Functions that return pointers (where 0/null indicates error)
/// are still handled properly as well.
T sdlEnforce(E:Throwable = SDLException, T)(T value, lazy const(char)[] msg=null, string file=__FILE__, size_t line=__LINE__) {
    static if(isIntegral!T) {
        if(value != 0)
            throw new E((msg ? msg.idup : null), file, line);
        return value;
    } else {
        return enforce!E(value);
    }
}

void InitSDL(int flags = SDL_INIT_TIMER | SDL_INIT_VIDEO | SDL_INIT_EVENTS) {
    if((SDL_WasInit(0) & flags) != flags)
        sdlEnforce(SDL_Init(flags));
}

void ShutdownSDL() {
    SDL_Quit();
}

// As a last resort safety
shared static ~this() {
    SDL_Quit();
}


class SDLSurface {
    SDL_Surface *surface;
    bool ownSurface;

    this(SDL_Surface *surface, bool ownSurface=true) {
        this.surface = surface;
        ownSurface = false;
    }

    this(int width, int height, int depth, int format) {
        this(sdlEnforce(SDL_CreateRGBSurfaceWithFormat(0, width, height, depth, format)));
    }

    ~this() {
        if(surface && ownSurface) {
            SDL_FreeSurface(surface);
            surface = null;
        }
    }

    void setPalette(SDLPalette pal) {
        assert(surface);
        SDL_Palette *palette = (pal ? pal.palette : null);
        sdlEnforce(SDL_SetSurfacePalette(surface, palette));
    }

    void lock() {
        assert(surface);
        if(SDL_MUSTLOCK(surface))
            sdlEnforce(SDL_LockSurface(surface));
    }

    void unlock() {
        assert(surface);
        if(SDL_MUSTLOCK(surface))
            sdlEnforce(SDL_UnlockSurface(surface));
    }
}

class SDLPalette {
    SDL_Palette *palette;

    this(int numColors) {
        palette = sdlEnforce(SDL_AllocPalette(numColors));
    }

    ~this() {
        if(palette) {
            SDL_FreePalette(palette);
            palette = null;
        }
    }

    void setColor(int index, ubyte r, ubyte g, ubyte b, ubyte a=0xFF) {
        assert(palette);
        assert(index < palette.ncolors);
        SDL_Color color = SDL_Color(r,g,b,a);
        sdlEnforce(SDL_SetPaletteColors(palette, &color, index, 1));
    }
}

class SDLWindow {
    SDL_Window *window;
    SDLSurface surface;

    __gshared const char* WD_KEY_WRAPPER = "wrapper";

    // TODO: Invalidate surface on window resize events

    void invalidateSurface() {
        if(surface) {
            destroy!false(surface);
            surface = null;
        }
    }

    int width() {
        return getSurface().surface.w;
    }

    int height() {
        return getSurface().surface.h;
    }

    this(string title, int width=640, int height=480, int flags=0) {
        // Ensure video was initialized
        InitSDL(SDL_INIT_VIDEO);
        window = sdlEnforce(SDL_CreateWindow(title.toStringz(), SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, width, height, flags));
        SDL_SetWindowData(window, WD_KEY_WRAPPER, cast(void*)this);
    }

    SDLSurface getSurface() {
        if(!surface) {
            SDL_Surface *rawSurface = sdlEnforce(SDL_GetWindowSurface(window));
            surface = new SDLSurface(rawSurface, false);
        }
        return surface;
    }

    uint getWindowID() {
        assert(window);
        // Unlike many other SDL functions, SDL_GetWindowID returns
        // 0 on error (rather than success)
        uint result = SDL_GetWindowID(window);
        if(!result)
            throw new SDLException();
        return result;
    }

    static SDLWindow getWindowByID(uint windowID) {
        SDLWindow result = null;
        SDL_Window *window = SDL_GetWindowFromID(windowID);
        if(window) {
            result = cast(SDLWindow)SDL_GetWindowData(window, WD_KEY_WRAPPER);
            assert(result);
        }
        return result;
    }

    ~this() {
        if(window) {
            // Not sure if removing the window data is necessary, but better safe than sorry
            SDL_SetWindowData(window, WD_KEY_WRAPPER, null);
            SDL_DestroyWindow(window);
            window = null;
        }
    }

    void updateWindow() {
        assert(window);
        sdlEnforce(SDL_UpdateWindowSurface(window));
    }
}

@("SDLWindow")
unittest {
    import fluentasserts.core.expect;

    InitSDL();
    scope(exit) ShutdownSDL();
    auto window = new SDLWindow("SDLWindowTest");
    uint windowID = window.getWindowID();
    assert(windowID);
    auto result = SDLWindow.getWindowByID(windowID);
    assert(result is window);
    immutable uint garbage = 1337;
    expect(garbage).to.not.equal(windowID);
    result = SDLWindow.getWindowByID(garbage);
    expect(result).to.beNull();

    // Destroy the window, ensure the ID now returns null
    destroy!false(window);
    result = SDLWindow.getWindowByID(windowID);
    expect(result).to.beNull();
}

version(SDL_tests) {
    @("SDL")
    unittest {
        InitSDL();
        scope(exit) ShutdownSDL();

        auto window = new SDLWindow("NESD");
        destroy!false(window);
    }
}

