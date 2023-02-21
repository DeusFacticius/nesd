/// Module for the actual 'emulator app', i.e. the mediator between
/// the NES model(s) and host application

module emu;

import std.stdio;
import std.format;
import std.typecons;
import std.algorithm;
import std.range;
import bindbc.sdl;
import sdl_wrapper;
import nes;
import ppu;
import rom;
import palette;
import peripheral;

class KeyboardController : StandardNESController {
    alias ButtonMapping = int[Button];

    ButtonMapping mapping;

    this(in ButtonMapping mapping = null) {
        // TODO: make this betterer
        if(mapping) {
            this.mapping = cast(typeof(this.mapping))mapping.dup;
        } else {
            this.mapping = [
                Button.A:       SDL_SCANCODE_LGUI,
                Button.B:       SDL_SCANCODE_LALT,
                Button.SELECT:  SDL_SCANCODE_TAB,
                Button.START:   SDL_SCANCODE_RETURN,
                Button.UP:      SDL_SCANCODE_UP,
                Button.DOWN:    SDL_SCANCODE_DOWN,
                Button.LEFT:    SDL_SCANCODE_LEFT,
                Button.RIGHT:   SDL_SCANCODE_RIGHT,
            ];
        }
    }

    override void readButtons() {
        const ubyte* keyStates = SDL_GetKeyboardState(null);
        foreach(k,v; mapping) {
            if(keyStates[v]) {
                // Set the corresponding bit using the flag as a mask
                buttons.raw |= (k & 0xFF);
            } else {
                // Clear the corresponding bit using the 1's complement
                // of the flag as a mask
                buttons.raw &= (~k & 0xFF);
            }
        }
    }
}

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

    void renderScreen(const ref NtscNesScreen screen) {
        assert(rawSurface && mappedSurface);
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

    auto window = scoped!SDLWindow("NESScreenRenderer test");

    auto nesRend = scoped!NESScreenRenderer(window);
    assert(nesRend);
}

class NESSoundRenderer {
    private static immutable int DESIRED_FREQ = 44100;
    private static immutable SDL_AudioFormat DESIRED_FORMAT = AUDIO_F32SYS;
    private static immutable int DESIRED_CHANNELS = 1;
    private static immutable int DESIRED_SAMPLES = 2048;

    //private static enum BYTES_PER_SAMPLE = SDL_AUDIO_BITSIZE(AUDIO_F32SYS) / 8;
    // bindbc / dlang is being stupid ^, so just hardcode for now...
    private static enum BYTES_PER_SAMPLE = float.sizeof;

    private static enum SDL_AUDIO_DEFAULT_DEVICE_ID = 1;  // Doesn't seem to be an official symbol for this
    // Min and max thresholds for adjusting APU sample period
    // Ideal min -- at least 1/8th of a second
    private static immutable uint MIN_THRESHOLD_BUFFERED_BYTES = (DESIRED_FREQ / 8) * BYTES_PER_SAMPLE;
    // Ideal max -- no more than 1/2 of a second
    private static immutable uint MAX_THRESHOLD_BUFFERED_BYTES = (DESIRED_FREQ / 2) * BYTES_PER_SAMPLE;

    SDL_AudioSpec desired;
    uint deviceId;
    NES nes;

    this(NES nes) {
        this.nes = nes;
        desired.freq = DESIRED_FREQ;
        desired.format = DESIRED_FORMAT;
        desired.channels = DESIRED_CHANNELS;
        desired.samples = DESIRED_SAMPLES;

        sdlEnforce(SDL_OpenAudio(&desired, null));
        deviceId = SDL_AUDIO_DEFAULT_DEVICE_ID;
        //debug writefln("[NESSoundRenderer] Opened audio with specs: %s", spec);

        nes.apu.sampleBufferListener = &onSampleBufferFlush;

        // Unpause audio (starts paused by default)
        SDL_PauseAudioDevice(deviceId, false);
    }

    ulong lastTuneTs;
    private static immutable ulong RETUNE_COOLDOWN = 0;
    private static immutable double TARGET_FRAME_SAMPLES = 44100 / 60;  // ~735

    //void tuneSamplePeriod() {
    //    ulong ts = SDL_GetTicks64();
    //    if(ts - lastTuneTs > RETUNE_COOLDOWN) {
    //        lastTuneTs = ts;
    //        uint bytesBuffered = SDL_GetQueuedAudioSize(deviceId);
    //        if(bytesBuffered < MIN_THRESHOLD_BUFFERED_BYTES) {
    //            // Increase frequency / decrease sample timer period
    //            debug writefln("[NESSoundRenderer] Device buffer below threshold (%d < %d), lowering sample period (from %d)", bytesBuffered, MIN_THRESHOLD_BUFFERED_BYTES, nes.apu.sampleTimer.period);
    //            nes.apu.decSamplePeriod();
    //        } else if(bytesBuffered > MAX_THRESHOLD_BUFFERED_BYTES) {
    //            // Decrease frequency / increase sample timer period
    //            nes.apu.incSamplePeriod();
    //            debug writefln("[NESSoundRenderer] Device buffer above threshold (%d > %d), raising sample period (from %d)", bytesBuffered, MAX_THRESHOLD_BUFFERED_BYTES, nes.apu.sampleTimer.period);
    //        }
    //    }
    //}

    void onSampleBufferFlush(in float[] buffer) {
        // Handler for the APU sample buffer flush
        //tuneSamplePeriod();
        // TODO: This is a poor solution for audio buffer underrun, and only marginally better than
        //  dropout. Adaptive sampling is probably ideal, but right now it seems there is too much variation
        //  in framerate to reliably adapt the sample rate -- there are still dropouts, and frequenty pitch
        //  shifts. Timestretching / pitch-preserving resampling might also be the answer, but that requires more
        //  signal processing than I'm familiar with, and may also be too resource intensive. In the meantime,
        //  oversampling and skipping are tolerable for now until this can be re-examined.
        auto length = buffer.length;
        auto queuedBytes = SDL_GetQueuedAudioSize(deviceId);
        auto queuedSamples = queuedBytes / float.sizeof;
        auto targetSamples = 2 * desired.samples;
        auto nextSamples = queuedSamples+buffer.length;
        if(nextSamples > targetSamples) {
            auto diff = nextSamples - targetSamples;
            // Slice a few samples off the end to prevent latency build up
            length -= diff;
        }
        auto ratio = (buffer.length > 0 ? TARGET_FRAME_SAMPLES / buffer.length : 1.0);
        //nes.apu.sampleRateMultiplier = ratio;
        //debug writefln("[NESSoundRenderer] Queueing buffer of %d (%d) samples (Buffered: %d / %ds) Ratio: %f", buffer.length, length, queuedBytes, queuedSamples, ratio);
        sdlEnforce(SDL_QueueAudio(deviceId, buffer.ptr, cast(uint)(length * float.sizeof)));
    }

    ~this() {
        SDL_CloseAudio();
    }

    //void onCallback(ubyte* dest, size_t len) nothrow {
    //    try {
    //        ubyte[] subBuffer;
    //        synchronized(nes) {
    //            auto currentPos = nes.apu.output.position;
    //            auto samplesAvailable = currentPos-readPos;
    //            if(samplesAvailable > nes.apu.output.length) {
    //                // The circular buffer has overrun since we last consumed from it
    //                debug writefln("[NESAPUSoundRenderer] Circular buffer overrun! (samplesAvailable: %d, bufferLength: %d)", samplesAvailable, nes.apu.output.length);
    //                // Clamp the backlog to the size of the buffer
    //                samplesAvailable = nes.apu.output.length;
    //            }
    //            // Copy samples to local buffer
    //            copy(nes.apu.output.reader().tail(samplesAvailable), cast(nes.apu.output.ElementType[])buffer);
    //            subBuffer = buffer[0..(samplesAvailable*nes.apu.output.ElementType.sizeof)];
    //        }
    //        // Warn if we can't fill the destination buffer (:-/)
    //        if(subBuffer.length < len) {
    //            debug writefln("[NESAPUSoundRenderer] Buffer underflow (SrcLen: %d, DestLen: %d, Delta: %d)", subBuffer.length, len, (len-subBuffer.length));
    //        }
    //        // TODO: warn buffer overflow?
    //        ubyte[] wrapped = dest[0..len];
    //        wrapped[] = 0;
    //        // Fill the destination buffer up to len bytes
    //        auto bytesToCopy = min(len, subBuffer.length);
    //        copy(subBuffer[0..bytesToCopy], dest[0..bytesToCopy]);
    //        // advance the read position by (bytes delivered / bytes per sample)
    //        readPos += bytesToCopy / BYTES_PER_SAMPLE;
    //        debug writefln("[NESSoundRenderer] Writing %d samples to audio device...", bytesToCopy / BYTES_PER_SAMPLE);
    //    } catch(Throwable err) {
    //        debug writefln("[NESAPUSoundRenderer] Swallowing exception during callback: %s", err);
    //    }
    //}
    //
    //ubyte[] convertBuffer(ubyte[] input) {
    //    assert(cvt.needed);
    //    assert(buffer.ptr == input.ptr);
    //    cvt.buf = input.ptr;
    //    cvt.len = input.length;
    //    assert(buffer.length >= input.length * cvt.len_mult, format("Audio CVT buffer not large enough for conversion! (current: %d, required: %d)", buffer.length, cvt.len * cvt.len_mult));
    //    sdlEnforce(SDL_ConvertAudio(&cvt));
    //    assert(cvt.len_cvt <= buffer.length);
    //    return cvt.buf[0..cvt.len_cvt];
    //}
}

class EmulatorApp {
    NES nes;
    NESScreenRenderer screenRenderer;
    NESSoundRenderer soundRenderer;
    SDLWindow window;
    bool quit;

    this() {
        InitSDL();
        nes = new NES();
        nes.cpuBus.setInput(PeripheralPort.PORT1, new KeyboardController());
        window = new SDLWindow("NESD", 512, 480);
        screenRenderer = new NESScreenRenderer(window);
        nes.ppu.addFrameListener(&onPPUFrame);
        soundRenderer = new NESSoundRenderer(nes);
    }

    void onPPUFrame(in PPU ppu, const ref NtscNesScreen screen) {
        screenRenderer.renderScreen(screen);
        //SDL_Surface *windowSurf = window.getSurface().surface;
        //SDL_Rect destRect = SDL_Rect(0,0,windowSurf.w, windowSurf.h);
        //sdlEnforce(SDL_BlitScaled(screenRenderer.surface.surface, null, windowSurf, &destRect));
        window.updateWindow();

        // EXPERIMENTAL -- flush audio buffer
        nes.apu.sampleBuffer.flush();
    }

    // Not to be called externally, called automatically when existing run()
    private void shutdown() {
        if(nes) {
            nes.stop();
        }
    }

    void run() {
        import std.datetime.stopwatch : StopWatch, AutoStart;
        import core.thread;

        scope(exit) shutdown();

        //ulong baseTime = SDL_GetTicks64();
        ulong frameCounter = 0;

        auto watch = StopWatch(AutoStart.yes);
        auto baseTime = watch.peek();

        while(!quit) {
            processEvents();
            // naive speed control, just tick NES as fast as
            // possible :-/
            synchronized(nes) {
                debug(trace) {
                    nes.altTick3();
                } else {
                    nes.altTick2();
                }
            }

            //ulong endTime = SDL_GetTicks64();
            //auto frameTime = (endTime - baseTime);
            //auto fps = 1000.0 / frameTime;
            //writefln("[EMU] FPS: %.4f", fps);
            //if(frameTime < 16) {
            //    Thread.sleep(msecs(16 - frameTime));
                //SDL_Delay(cast(uint)(16 - frameTime));
            //}

            auto endTime = watch.peek();
            auto frameTimeUsec = (endTime - baseTime).total!"usecs";
            auto fps = 1000000.0 / frameTimeUsec;
            //debug writefln("[EMU] FPS: %.4f", fps);
            static enum ftime = 1000000 / 60;
            if(frameTimeUsec < ftime) {
                Thread.sleep(usecs(ftime - frameTimeUsec));
            }

            //if(frameTime < )
            //baseTime = endTime;

            baseTime = endTime;
            ++frameCounter;
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
        synchronized(nes) {
            nes.insertCartridge(cart);
            debug(trace) {
                nes.startLogging("trace.log");
            }
        }
    }

debug:
    void dumpPalette() {
        string buf="";
        synchronized(nes) {
            foreach (i; 0..4) {
                writefln("PPU Palette %d: %s", i, nes.ppu.bgPalettes[i]);
            }
        }
    }
}