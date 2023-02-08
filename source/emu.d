module emu;

import std.stdio;
import bindbc.sdl;
import sdl_wrapper;
import nes;
import ppu;
import rom;
import palette;

/// Module for the actual 'emulator app', i.e. the mediator between
/// the NES model(s) and host application

class NESScreenRenderer {
    SDLSurface rawSurface;
    SDLSurface mappedSurface;
    SDLWindow window;

    this(SDLWindow window) {
        this.window = window;
        // Create a 'raw' palettized surface that uses NTSC NES palette, for copying
        // the raw PPU screen to
        rawSurface = new SDLSurface(NTSC_SCREEN_W, NTSC_SCREEN_H, 8, SDL_PIXELFORMAT_INDEX8);
        SDLPalette palette = new SDLPalette(RGB_LUT.length);
        scope(exit) destroy!false(palette);

        foreach(int i; 0..RGB_LUT.length) {
            palette.setColor(i, RGB_LUT[i].red, RGB_LUT[i].green, RGB_LUT[i].blue);
        }
        rawSurface.setPalette(palette);

        // Create a corresponding 'mapped' surface, that matches the display window's
        // pixel format. SDL won't do scaling AND format mapping at the same time via
        // BlitScaled, so format mapping done first (raw -> mapped), and _then_ blit scaled
        // to the screen
        SDL_PixelFormat *format = window.getSurface().surface.format;
        mappedSurface = new SDLSurface(NTSC_SCREEN_W, NTSC_SCREEN_H, format.BitsPerPixel, format.format);
    }

    void renderScreen(in NtscNesScreen screen) {
        //assert(surface);
        // Perform the lock / copy / unlock in a block for auto scope
        // events
        {
            rawSurface.lock();
            scope(exit) rawSurface.unlock();
            ubyte* surfacePtr = cast(ubyte*)rawSurface.surface.pixels;

            foreach(scanline; 0..NTSC_SCREEN_H) {
                // Copy the scanline to surface pixels
                surfacePtr[0..NTSC_SCREEN_W] = screen[scanline][];
                // Advance the dest ptr by surface pitch
                surfacePtr += rawSurface.surface.pitch;
            }
        }

        // Blit raw -> mapped, SDL will convert pixel format for us
        sdlEnforce(SDL_BlitSurface(rawSurface.surface, null, mappedSurface.surface, null));
        // Now do scaled blit from mapped -> window
        SDL_Surface *windowSurf = window.getSurface().surface;
        sdlEnforce(SDL_BlitScaled(mappedSurface.surface, null, windowSurf, null));
    }

    ~this() {
        // This may not be necessary, but doesn't seem to hurt
        if(rawSurface) {
            destroy!false(rawSurface);
            rawSurface = null;
        }
        if(mappedSurface) {
            destroy!false(mappedSurface);
            mappedSurface = null;
        }
    }
}

@("NESScreenRenderer")
unittest {
    InitSDL();
    scope(exit) ShutdownSDL();

    auto nesRend = new NESScreenRenderer();
    scope(exit) destroy!false(nesRend);
    assert(nesRend);
    assert(nesRend.surface);
}

class EmulatorApp {
    NES nes;
    NESScreenRenderer screenRenderer;
    SDLWindow window;
    bool quit;

    this() {
        InitSDL();
        nes = new NES();
        window = new SDLWindow("NESD");
        screenRenderer = new NESScreenRenderer(window);

        nes.ppu.addFrameListener(&onPPUFrame);
    }

    void onPPUFrame(in PPU ppu, in NtscNesScreen screen) {
        screenRenderer.renderScreen(screen);
        //SDL_Surface *windowSurf = window.getSurface().surface;
        //SDL_Rect destRect = SDL_Rect(0,0,windowSurf.w, windowSurf.h);
        //sdlEnforce(SDL_BlitScaled(screenRenderer.surface.surface, null, windowSurf, &destRect));
        window.updateWindow();
    }

    void run() {
        while(!quit) {
            processEvents();
            // naive speed control, just tick NES as fast as
            // possible :-/
            nes.altTick();
        }
    }

    void processEvents() {
        SDL_Event evt;
        while(SDL_PollEvent(&evt)) {
            switch(evt.type) {
                case SDL_QUIT:
                case SDL_APP_TERMINATING:
                    quit = true;
                    break;

                case SDL_WINDOWEVENT:
                    handleWindowEvent(evt.window);
                    break;

                case SDL_DISPLAYEVENT:
                    // do something (?)
                    break;

                case SDL_KEYDOWN:
                    // do something
                    handleKeyEvent!true(evt.key);
                    break;

                case SDL_KEYUP:
                    // do something
                    handleKeyEvent!false(evt.key);
                    break;

                default:
                    // Log?
                    break;
            }
        }
    }

    void handleWindowEvent(in SDL_WindowEvent evt) {
        SDLWindow target = SDLWindow.getWindowByID(evt.windowID);
        if(target != window) {
            // Not our chair
            return;
        }
        switch(evt.event) {
            case SDL_WINDOWEVENT_RESIZED:
            case SDL_WINDOWEVENT_SIZE_CHANGED:
                window.invalidateSurface();
                break;

            case SDL_WINDOWEVENT_CLOSE:
                quit = true;
                break;

            default:
                // Log?
                break;
        }
    }

    void handleKeyEvent(bool down)(in SDL_KeyboardEvent evt) {
        switch(evt.keysym.scancode) {
            case SDL_Scancode.SDL_SCANCODE_ESCAPE:
                static if(down)
                    quit = true;
                break;

            debug {
                case SDL_Scancode.SDL_SCANCODE_P:
                    static if(down)
                        dumpPalette();
                    break;
            }
            default:
                break;
        }
    }

    void loadROM(in string filename) {
        NESFile cart = new NESFile(filename);
        nes.insertCartridge(cart);
    }

debug:
    void dumpPalette() {
        string buf="";
        foreach(i; 0..4) {
            writefln("PPU Palette %d: %s", i, nes.ppu.bgPalettes[i]);
        }
    }
}