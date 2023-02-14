/// Module for modeling / simulating / emulating the NES APU (Audio Processing Unit)

module apu;

import std.bitmanip;
import std.traits;

alias real_t = float;

union PulseCtrl {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "volEnv", 4,
            bool, "constant", 1,
            bool, "halt", 1,
            uint, "duty", 2,
        ));
    }
}
static assert(PulseCtrl.sizeof == ubyte.sizeof);

union PulseSweep {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "shift", 3,
            bool, "negate", 1,
            uint, "period", 3,
            bool, "enabled", 1
        ));
    }
}
static assert(PulseSweep.sizeof == ubyte.sizeof);

union TimerHigh {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "timerHigh", 3,
            uint, "lengthCounterLoad", 5,
        ));
    }
}
static assert(TimerHigh.sizeof == ubyte.sizeof);

union PulseRegisterSet {
    ubyte[4] rawBytes;
    struct {
        PulseCtrl ctrl;
        PulseSweep sweep;
        ubyte timerLow;
        TimerHigh timerHigh;
    }
}
static assert(PulseRegisterSet.sizeof == 4*ubyte.sizeof);

union TriangleCtrl {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "linearCounterLoad", 7,
            bool, "counterCtrl", 1,
        ));
    }
}

union TriangleRegisterSet {
    ubyte[4] rawBytes;
    struct {
        TriangleCtrl ctrl;
        ubyte unused;
        ubyte timerLow;
        TimerHigh timerHigh;
    }
}
static assert(TriangleRegisterSet.sizeof == 4*ubyte.sizeof);

union NoiseCtrl {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "volEnv", 4,
            bool, "constant", 1,
            bool, "halt", 1,
            uint, "unused", 2,
        ));
    }
}
static assert(NoiseCtrl.sizeof == ubyte.sizeof);

union NoiseCtrl3 {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "period", 4,
            uint, "unused", 3,
            bool, "loop", 1,
        ));
    }
}
static assert(NoiseCtrl3.sizeof == ubyte.sizeof);

union NoiseCtrl4 {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "unused", 3,
            uint, "loopCounterLoad", 5,
        ));
    }
}
static assert(NoiseCtrl4.sizeof == ubyte.sizeof);

union DMCCtrl1 {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "frequency", 4,
            uint, "unused", 2,
            bool, "loop", 1,
            bool, "irqEnable", 1,
        ));
    }
}
static assert(DMCCtrl1.sizeof == ubyte.sizeof);

union DMCCtrl2 {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "loadCounter", 7,
            uint, "unused", 1,
        ));
    }
}
static assert(DMCCtrl2.sizeof == ubyte.sizeof);

union DMCRegisterSet {
    ubyte[4] rawBytes;
    struct {
        DMCCtrl1 ctrl1;
        DMCCtrl2 ctrl2;
        ubyte sampleAddr;
        ubyte sampleLength;
    }
}
static assert(DMCRegisterSet.sizeof == 4*ubyte.sizeof);

union APUControl {
    ubyte raw;
    struct {
        mixin(bitfields!(
            bool, "pulse1", 1,
            bool, "pulse2", 1,
            bool, "triangle", 1,
            bool, "noise", 1,
            bool, "dmc", 1,
            uint, "unused", 3,
        ));
    }
}
static assert(APUControl.sizeof == ubyte.sizeof);

union APUStatus {
    ubyte raw;
    struct {
        mixin(bitfields!(
            bool, "pulse1", 1,
            bool, "pulse2", 1,
            bool, "triangle", 1,
            bool, "noise", 1,
            bool, "dmc", 1,
            uint, "unused", 1,
            bool, "frameInterrupt", 1,
            bool, "dmcInterrupt", 1,
        ));
    }
}
static assert(APUStatus.sizeof == ubyte.sizeof);

private shared static immutable ubyte[32] LENGTH_LUT = [
    10, 254, 20,  2, 40,  4, 80,  6, 160,  8, 60, 10, 14, 12, 26, 14,
    12,  16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30,
];

private shared static immutable ubyte[4] PULSE_DUTY_WAVEFORM_LUT = [
    0x40,   // 00 - (0) = 0 1 0 0 0 0 0 0   (12.5%)
    0x60,   // 01 - (1) = 0 1 1 0 0 0 0 0   (25%)
    0x78,   // 10 - (2) = 0 1 1 1 1 0 0 0   (50%)
    0x9F,   // 11 - (3) = 1 0 0 1 1 1 1 1   (75%, or 25% negated)
];

struct Divider(T) if(isIntegral!T && isUnsigned!T) {
    alias TockFunc = void delegate(Divider);
    T period;
    TockFunc tock;
    T counter;

    void tick() {
        if(counter == 0) {
            // tock
            if(tock)
                tock();
            counter = period;
        } else {
            --counter;
        }
    }

    void reset() {
        counter = period;
    }
}

struct Sequencer(T) if(isIntegral!T && isUnsigned!T) {
    const T[] sequence;
    size_t current;

    T getCurrent() {
        assert(current >= 0 && current < sequence.length, "Sequence generator out of range");
        return sequence[current];
    }

    void advance() {
        ++current;
        if(current >= sequence.length)
            current = 0;
    }
}

class APU {

    static real_t calcPulseOutput(T)(in T pulse1, in T pulse2) if(isIntegral!T) {
        return 0.00752 * (pulse1 + pulse2);
    }

    static real_t calcTndOutput(T)(in T triangle, in T noise, in T dmc) if(isIntegral!T) {
        return (0.00851 * triangle) + (0.00494 * noise) + (0.00335 * dmc);
    }

    static real_t calcOutput(T)(in T pulse1, in T pulse2, in T triangle, in T noise, in T dmc) if(isIntegral!T) {
        return calcPulseOutput(pulse1, pulse2) + calcTndOutput(triangle, noise, dmc);
    }
}
