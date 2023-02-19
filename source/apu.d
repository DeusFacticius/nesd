/// Module for modeling / simulating / emulating the NES APU (Audio Processing Unit)

module apu;

import std.bitmanip;
import std.stdio;
import std.algorithm.searching;
import std.traits;
import util;

alias real_t = float;

shared immutable APU_MAX_WAVEFORM_VOLUME = 15;   // e.g. 4 bits (0-F)
shared immutable APU_MAX_DMC_VOLUME = 127;

pure real_t calcPulseLookup(size_t n) {
    return (95.52 / (8128.0 / n + 100));
}

pure real_t calcTndLookup(size_t n) {
    return 163.67 / (24329.0 / n + 100);
}

// TODO: There's probably a bettery way to to do this ...

pure immutable(T[]) makeLUT(T, alias F, size_t n)() {
    T[n] result;
    foreach(i; 0..n) {
        result[i] = F(i);
    }
    return result.idup;
}

private static immutable real_t[31] PULSE_LUT = makeLUT!(real_t, calcPulseLookup, 31);
private static immutable real_t[203] TND_LUT = makeLUT!(real_t, calcTndLookup, 203);

private pure real_t lookupPulseMixerOutput(size_t pulse1, size_t pulse2) {
    assert(pulse1 >= 0 && pulse1 <= APU_MAX_WAVEFORM_VOLUME, "Pulse1 output out of range [0,15]");
    assert(pulse2 >= 0 && pulse2 <= APU_MAX_WAVEFORM_VOLUME, "Pulse2 output out of range [0,15]");
    auto index = pulse1+pulse2;
    assert(index < PULSE_LUT.length);
    return PULSE_LUT[index];
}

private pure real_t lookupTndMixerOutput(size_t triangle, size_t noise, size_t dmc) {
    assert(triangle >= 0 && triangle <= APU_MAX_WAVEFORM_VOLUME, "Triangle output out of range [0,15]");
    assert(noise >= 0 && noise <= APU_MAX_WAVEFORM_VOLUME, "Noise output out of range [0,15]");
    assert(dmc >= 0 && dmc <= APU_MAX_DMC_VOLUME, "DMC output out of range [0,127]");
    auto index = (3*triangle) + (2*noise) + dmc;
    assert(index < TND_LUT.length);
    return TND_LUT[index];
}

private pure real_t lookupMixerOutput(size_t pulse1, size_t pulse2, size_t triangle, size_t noise, size_t dmc) {
    return lookupPulseMixerOutput(pulse1, pulse2) + lookupTndMixerOutput(triangle, noise, dmc);
}

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

union PulseSweepCtrl {
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
static assert(PulseSweepCtrl.sizeof == ubyte.sizeof);

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
        PulseSweepCtrl sweep;
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
            bool, "controlFlag", 1,
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

union FrameCounterCtrl {
    ubyte raw;
    struct {
        mixin(bitfields!(
            uint, "unused", 6,
            bool, "mode", 1,
            bool, "interruptInhibit", 1,
        ));
    }
}
static assert(FrameCounterCtrl.sizeof == ubyte.sizeof);

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

/// Length Counter Load lookup table, as defined by APU hardware
private shared static immutable ubyte[32] LENGTH_LUT = [
    10, 254, 20,  2, 40,  4, 80,  6, 160,  8, 60, 10, 14, 12, 26, 14,
    12,  16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30,
];

private shared static immutable ubyte[4] PULSE_DUTY_WAVEFORM_LUT = [
    0x01,   //0x40,   // 00 - (0) = 0 1 0 0 0 0 0 0   (12.5%)
    0x02,   //0x60,   // 01 - (1) = 0 1 1 0 0 0 0 0   (25%)
    0x0F,   //0x78,   // 10 - (2) = 0 1 1 1 1 0 0 0   (50%)
    0xFC,   //0x9F,   // 11 - (3) = 1 0 0 1 1 1 1 1   (75%, or 25% negated)
];

// TODO: Ugly / verbose, generate from bit sequences above?

private shared static immutable bool[8][4] PULSE_DUTY_SEQUENCES = [
    [false, false, false, false, false, false, false, true],
    [false, false, false, false, false, false, true, true],
    [false, false, false, false, true, true, true, true],
    [true, true, true, true, true, true, false, false],
];

struct Divider(T) if(isIntegral!T && isUnsigned!T) {
    alias TockFunc = void delegate();
    T period;
    TockFunc tock;
    T counter;

    bool tick() {
        if(counter <= 0) {
            // tock
            if(tock)
                tock();
            counter = period;
            return true;
        } else {
            --counter;
            return false;
        }
    }

    void reset() {
        counter = period;
    }

    void reset(T newPeriod) {
        counter = period = newPeriod;
    }
}

struct Sequencer(T) {
    const(T)[] sequence;
    size_t current;

    T getCurrent() {
        assert(sequence, "Sequencer not initialized!");
        assert(current >= 0 && current < sequence.length, "Sequence generator out of range");
        return sequence[current];
    }

    void advance() {
        // Sequencer counts downwards rather than upwards
        if(current <= 0)
            current = sequence.length-1;
        else
            --current;
    }

    void reset() {
        current = 0;
    }
}

class Envelope {
    Divider!ubyte divider;
    bool startFlag;
    bool loopFlag;
    bool constantVolume;
    ubyte decayLevel;
    ubyte v;

    this() {
        divider.tock = () {
            divider.period = v;
            if(decayLevel > 0)
                --decayLevel;
            else if(loopFlag)
                decayLevel = APU_MAX_WAVEFORM_VOLUME;
        };
    }

    void tick() {
        if(startFlag) {
            decayLevel = APU_MAX_WAVEFORM_VOLUME;
            divider.reset(v);
            startFlag = false;
        } else {
            divider.tick();
        }
    }

    ubyte getOutput() {
        return (constantVolume ? v : decayLevel);
    }

    void reset() {
        startFlag = true;
    }
}

class AbstractApuChannel {
    void onApuTick() {}
    void onCpuTick() {}
    void onQuarterFrame() {}
    void onHalfFrame() {}

    abstract void disable();
    abstract ubyte getOutput();
}

enum PulseChannelID {
    PULSE1,
    PULSE2,
}

class PulseChannel : AbstractApuChannel {
    PulseChannelID pulseChannelId;
    Divider!ushort pulseTimer;
    Envelope envelope;
    SweepUnit sweep;
    Sequencer!bool sequencer;
    ubyte lengthCounter;
    bool lengthCounterHalt;

    this(PulseChannelID pulseChannelId) {
        this.pulseChannelId = pulseChannelId;
        envelope = new Envelope();
        sweep = new SweepUnit();
        setPulseCtrl(PulseCtrl(0));
        setSweepCtrl(PulseSweepCtrl(0));
        setTimerLow(0);
        setTimerHigh(TimerHigh(0));
        pulseTimer.tock = () { sequencer.advance(); };
    }

    /*
    For reference, from: https://www.nesdev.org/wiki/APU_Pulse

                         Sweep -----> Timer
                       |            |
                       |            |
                       |            v
                       |        Sequencer   Length Counter
                       |            |             |
                       |            |             |
                       v            v             v
    Envelope -------> Gate -----> Gate -------> Gate --->(to mixer)
     */

    void setPulseCtrl(in PulseCtrl ctrl) {
        sequencer.sequence = PULSE_DUTY_SEQUENCES[ctrl.duty & 0x3][];
        lengthCounterHalt = envelope.loopFlag = ctrl.halt;
        envelope.constantVolume = ctrl.constant;
        envelope.v = ctrl.volEnv & 0xF;
        envelope.reset();
    }

    void setSweepCtrl(in PulseSweepCtrl swp) {
        sweep.enabled = swp.enabled;
        sweep.sweepPeriod = swp.period & 0x7;
        sweep.negate = swp.negate;
        sweep.shiftCount = swp.shift & 0x7;
        sweep.reset();
    }

    void setTimerLow(in ubyte value) {
        // set only the low 8 (of 11) bits of the timer, without resetting it
        pulseTimer.period = (pulseTimer.period & 0x700) | value;
        // changing the timer period causes the sweep unit's target period to be updated
        sweep.calcTargetPeriod();
    }

    void setTimerHigh(in TimerHigh value) {
        // Set the high 3 (of 11) bits of the timer, set the length counter from LUT
        // also reset the sequencer & envelope, but the period timer is _not_ reset
        pulseTimer.period = ((value.timerHigh << 8) | (pulseTimer.period & 0xFF)) & 0x7FF;
        lengthCounter = LENGTH_LUT[value.lengthCounterLoad];
        sequencer.reset();
        envelope.reset();

        // Changing the timer period causes the sweep unit's target period to be udpated
        sweep.calcTargetPeriod();
    }

    override void disable() {
        // immediately silence (by setting lengthCounter = 0) as a result of writing 0 to respective bit in
        // APU status ($4015)
        lengthCounter = 0;
    }

    override ubyte getOutput() {
        // Any of the series of 'gates' (see diagram above) may mute / silence the signal to 0
        if(sweep.isMuted() || lengthCounter <= 0 || !sequencer.getCurrent())
            return 0;
        // Otherwise, the channel outputs the current envelope value
        return envelope.getOutput();
    }

    void tickLengthCounter() {
        if(lengthCounter > 0 && !lengthCounterHalt)
            --lengthCounter;
    }

    override void onApuTick() {
        // The pulse timer (period) is clocked on every APU tick
        pulseTimer.tick();
    }

    override void onQuarterFrame() {
        // Only the envelope timer is clocked on quarter-frame ticks
        envelope.tick();
    }

    override void onHalfFrame() {
        // Only the sweep and length counters are clocked on half-frame ticks
        sweep.tick();
        tickLengthCounter();
    }

    // Given the sweep unit's interaction with the period timer (since it manipulates frequency), declaring it
    // as a nested class gives it implicit access to outer class.
    // N.B.: Must be a class, structs do not have outer class instance access ^
    class SweepUnit {
        Divider!ubyte sweepTimer;
        ubyte sweepPeriod;
        bool reload;
        ubyte shiftCount;
        bool negate;
        bool enabled;
        short targetPeriod;

        void tick() {
            // If sweep timer triggers AND the sweep unit is enabled AND the channel is not muted AND shift count is
            // not zero, update the pulse channel period
            if(sweepTimer.tick() && enabled && !isMuted() && shiftCount > 0) {
                // Assert the target period is less than the max range of an 11 bit timer (isMuted should be false
                // otherwise)
                assert(targetPeriod < 0x800);
                // Update the period to the targetPeriod, clamping to 0 if it would be negative
                pulseTimer.period = (targetPeriod > 0 ? (targetPeriod & 0x7FF) : 0);
                // target period always responds immediately to changes of period
                calcTargetPeriod();
            }
            if(reload) {
                sweepTimer.reset(sweepPeriod);
                reload = false;
            }
        }

        void calcTargetPeriod() {
            short changeAmount = cast(short)(pulseTimer.period >> shiftCount);
            if(negate) {
                // Pulse 1 uses 1's complement, pulse 2 uses 2's complement
                if(pulseChannelId == PulseChannelID.PULSE1)
                    changeAmount = -(changeAmount+1); //cast(typeof(changeAmount))(~changeAmount);
                else
                    changeAmount = cast(typeof(changeAmount))(-changeAmount); //(~changeAmount)+1;
            }
            targetPeriod = cast(typeof(targetPeriod))(pulseTimer.period + changeAmount);
        }

        bool isMuted() {
            // Sweep unit mutes channel if pulse timer period is < 8, OR if the _target_ period is > $7FF (range of
            // 11 bit timer)
            return (pulseTimer.period < 8) || (targetPeriod > 0x07FF);
        }

        void reset() {
            reload = true;
        }
    }
}

private static immutable ubyte[] TRIANGLE_SEQ = [
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
];
static assert(TRIANGLE_SEQ.length == 32);

class TriangleChannel : AbstractApuChannel {
    Divider!ushort seqTimer;
    bool controlFlag;
    Sequencer!ubyte sequencer;
    ubyte linearCounter;
    ubyte linearCounterReloadValue;
    bool reload;
    ubyte lengthCounter;

    /*
        For reference, from: https://www.nesdev.org/wiki/APU_Triangle

                   Linear Counter   Length Counter
                    |                |
                    v                v
        Timer ---> Gate ----------> Gate ---> Sequencer ---> (to mixer)
     */

    this() {
        sequencer.sequence = TRIANGLE_SEQ[];
        seqTimer.tock = () { sequencer.advance(); };
    }

    override void onCpuTick() {
        // The sequencer timer is clocked off of CPU ticks rather than APU ticks
        // The sequencer timer is only clocked if both linear & length counters are nonzero
        if(linearCounter && lengthCounter)
            seqTimer.tick();
    }

    override void disable() {
        lengthCounter = 0;
    }

    override ubyte getOutput() {
        // Triangle channel always outputs the current sequencer value --
        ubyte output = sequencer.getCurrent();
        debug {
            static int c = 0;
            if (lengthCounter > 0 && c++ % 1000 == 0)
                writefln("[TriangleChannel] Triangle output: %d", output);
        }
        // Triangle channel can generate frequencies up to Fcpu/32 (~55.9kHz for NTSC), well above audible range (20kHz)
        // Although with perfect sampling rate these would be inaudible, the emulator itself runs slow and sampling
        // rate is kludged, so it results in a high pitched but audible whine. To save our ears (and speakers), we'll
        // force clamp anything of too high of frequency by disabling the output when frequency is beyond some threshold
        return (seqTimer.period > 3 ? output : 0);
    }

    override void onQuarterFrame() {
        // Linear counter is clocked on quarter frames
        // If the linear counter reload flag is set, the linear counter is reloaded with the counter reload value,
        // otherwise if the linear counter is non-zero, it is decremented.
        if(reload)
            linearCounter = linearCounterReloadValue;
        else if(linearCounter > 0)
            --linearCounter;
        // If the control flag is clear, the linear counter reload flag is cleared.
        if(!controlFlag)
            reload = false;
    }

    override void onHalfFrame() {
        // Length counters are clocked on half frames
        // length counter only decremented if halt ('controlFlag' for triangle channel) is clear
        if(lengthCounter > 0 && !controlFlag)
            --lengthCounter;
    }

    void setTriangleCtrl(in TriangleCtrl value) {
        // Does not set the reload flag (?)
        linearCounterReloadValue = value.linearCounterLoad & 0x7F;
        controlFlag = value.controlFlag;
    }

    void setTimerLow(in ubyte value) {
        seqTimer.period = (seqTimer.period & 0x700) | value;
    }

    void setTimerHigh(in TimerHigh value) {
        seqTimer.period = ((value.timerHigh << 8)  | (seqTimer.period & 0xFF)) & 0x07FF;
        lengthCounter = LENGTH_LUT[value.lengthCounterLoad];
        reload = true;
    }
}

// These are ugly, but according to data / tables from https://www.nesdev.org/wiki/APU_Frame_Counter,
// the intervals do not follow a straightforward pattern (the latter steps are off by ~1 or more and thus
// do not fall on exact intervals of 3728.
// The values here are in fixed point (1-bit fraction) since they fall _in-between_ APU frames.
private static immutable uint[] FOURSTEP_QFRAMES = [(3728<<1)+1, (7456<<1)+1, (11185<<1)+1, (14914<<1)+1];
private static immutable uint[] FOURSTEP_HFRAMES = [FOURSTEP_QFRAMES[1], FOURSTEP_QFRAMES[$-1]];
private static immutable uint FOURSTEP_RESET = 14915 << 1;

private static immutable uint[] FIVESTEP_QFRAMES = [(3728<<1)+1, (7456<<1)+1, (11185<<1)+1, (18640<<1)+1];
private static immutable uint[] FIVESTEP_HFRAMES = [FIVESTEP_QFRAMES[1], FIVESTEP_QFRAMES[$-1]];
private static immutable uint FIVESTEP_RESET = 18640 << 1;

class FrameCounter {
    bool fiveStepMode;
    bool interruptInhibit;
    /// Fixed-point (1 bit fraction), since APU ticks 'every other' CPU tick, but there's lots of things that
    /// happen on APU 'half' frames (i.e. CPU cycle following an APU cycle)
    uint apuCycleCounter;
    alias Handler = void delegate();
    Handler qtickHandler;
    Handler htickHandler;
    bool frameInterrupt;
    bool pendingReset;
    uint resetCounter;
    FrameCounterCtrl targetCtrl;

    @property uint apuTicks() const {
        return (apuCycleCounter >> 1);
    }

    void reset() {
        apuCycleCounter = 0;
        pendingReset = false;
        fiveStepMode = false;
        // Not sure about this one...
        interruptInhibit = true;
    }

    void setFrameCounterCtrl(FrameCounterCtrl ctrl) {
        // Writing to the frame counter control doesn't take effect immediately, but rather 3-4 (CPU) cycles _after_
        // the write
        targetCtrl = ctrl;
        pendingReset = true;
        // write takes effect 3 cpu cycles if _during_ an APU cycle, else 4 cycles (if _between_ APU cycles)
        resetCounter = 3 + (apuCycleCounter & 1);
    }

    private void checkReset() {
        if(pendingReset) {
            if(resetCounter <= 0) {
                pendingReset = false;
                apuCycleCounter = 0;
                fiveStepMode = targetCtrl.mode;
                interruptInhibit = targetCtrl.interruptInhibit;
                // If mode flag is set (e.g. 5-step mode), then both q/h events are triggered
                // According to https://www.nesdev.org/wiki/APU_Frame_Counter, this does _not_ happen
                // when mode flag is clear (4-step mode).
                if(fiveStepMode) {
                    if(qtickHandler)
                        qtickHandler();
                    if(htickHandler)
                        htickHandler();
                }
            } else {
                --resetCounter;
            }
        }
    }

    void doCpuTick() {
        if(!fiveStepMode) {
            fourStepTick();
        } else {
            fiveStepTick();
        }
        ++apuCycleCounter;
    }

    // TODO: Consolidate these nearly identical tick routines
    // TODO: Implement a Sequencer variant to optimize the checks
    void fourStepTick() {
        if(qtickHandler && FOURSTEP_QFRAMES.canFind(apuCycleCounter))
            qtickHandler();
        if(htickHandler && FOURSTEP_HFRAMES.canFind(apuCycleCounter))
            htickHandler();

        frameInterrupt = !interruptInhibit &&
            (apuCycleCounter >= (14914<<1) && apuCycleCounter <= (14915<<1));
        if(apuCycleCounter >= FOURSTEP_RESET)
            apuCycleCounter = 0;
    }

    void fiveStepTick() {
        if(qtickHandler && FIVESTEP_QFRAMES.canFind(apuCycleCounter))
            qtickHandler();
        if(htickHandler && FIVESTEP_HFRAMES.canFind(apuCycleCounter))
            htickHandler();
        if(apuCycleCounter >= FIVESTEP_RESET)
            apuCycleCounter = 0;
    }
}

private static immutable size_t SAMPLE_RATE = 44100;    // 44.1 KHz (44100)
// Buffer size = sample rate (44100Hz) * buffer duration (1/8s) = ~5644.8 samples (5512)
private static immutable size_t BUFFER_SIZE = SAMPLE_RATE / 8;

private static immutable size_t SAMPLES_PER_FRAME = SAMPLE_RATE / 60;

private static immutable uint CPU_FREQ = 1789773;   // ~1.79MHz
// APU ticks at _half_ the frequency of the CPU
private static immutable uint APU_FREQ = 1789773 / 2;
// Ratio of APU tick rate to sample rate (~20)
private static immutable uint SAMPLE_TICKS = 30; // APU_FREQ / SAMPLE_RATE;

// We run sample capture off the CPU clock, so calculate the cycles per sample
private static immutable double CYCLES_PER_SAMPLE = cast(double)(CPU_FREQ) / cast(double)(SAMPLE_RATE); // ~40.5844217...

private static immutable double TIME_PER_CYCLE = 1.0 / cast(double)CPU_FREQ;
private static immutable double TIME_PER_SAMPLE = 1.0 / cast(double)(SAMPLE_RATE);

static immutable uint DEFAULT_SAMPLE_PERIOD = 40; //30;
static immutable uint MIN_SAMPLE_PERIOD = 30;
static immutable uint MAX_SAMPLE_PERIOD = 50;

class APU {
    //alias SampleBuffer = CircularBuffer!(real_t, BUFFER_SIZE);
    alias SampleBuffer = FixedSizeBuffer!(real_t, BUFFER_SIZE);
    alias SampleTimer = Divider!uint;
    alias SampleBufferListener = SampleBuffer.FlushListener;

    PulseChannel[2] pulse;
    TriangleChannel triangle;
    AbstractApuChannel[] channels;
    FrameCounter frameCounter;
    SampleBuffer sampleBuffer;

    /// Tracks CPU ticks, APU ticks: tickCounter >> 1
    ulong tickCounter;
    //SampleTimer sampleTimer;
    double sampleTs = 0;
    double sampleRateMultiplier = 1.30;

    this() {
        pulse[0] = new PulseChannel(PulseChannelID.PULSE1);
        pulse[1] = new PulseChannel(PulseChannelID.PULSE2);
        triangle = new TriangleChannel();
        channels = [pulse[0], pulse[1], triangle];
        frameCounter = new FrameCounter();

        frameCounter.qtickHandler = &onQuarterFrame;
        frameCounter.htickHandler = &onHalfFrame;

        //sampleTimer.reset(DEFAULT_SAMPLE_PERIOD);
        //sampleTimer.tock = &sampleOutput;
        sampleTs = 0;
    }

    @property SampleBufferListener sampleBufferListener() {
        return sampleBuffer.listener;
    }

    @property SampleBufferListener sampleBufferListener(SampleBufferListener listener) {
        sampleBuffer.listener = listener;
        return sampleBuffer.listener;
    }

    //bool incSamplePeriod() {
    //    if(sampleTimer.period < MAX_SAMPLE_PERIOD) {
    //        ++sampleTimer.period;
    //        return true;
    //    }
    //    return false;
    //}
    //
    //bool decSamplePeriod() {
    //    if(sampleTimer.period > MIN_SAMPLE_PERIOD) {
    //        --sampleTimer.period;
    //        return true;
    //    }
    //    return false;
    //}

    void sampleTick() {
        sampleTs += TIME_PER_CYCLE * sampleRateMultiplier;
        if(sampleTs >= TIME_PER_SAMPLE) {
            sampleOutput();
            sampleTs -= TIME_PER_SAMPLE;
        }
    }

    void doTick() {
        // this is the main control flow entry point -- called on every _CPU_ tick
        // The frame counter has its own cpu/apu cycle track logic
        frameCounter.doCpuTick();

        // Run individual channel CPU tick handlers
        // For most this is a no-op, but triangle at least does something meaningful
        foreach(c; channels)
            c.onCpuTick();

        // If this is (the first half of) an APU tick, clock APU events
        if((tickCounter & 1) == 0) {
            foreach(c; channels)
                c.onApuTick();
        }
        // Tick the sampling clock
        sampleTick();
        // Increment the tick counter
        ++tickCounter;
    }

    void sampleOutput() {
        real_t sample = calcCurrentOutput();
        //debug if(frameCounter.apuCycleCounter % 10000 == 0) writefln("[APU] writing sample to output (%f)", sample);
        sampleBuffer.put(sample);
    }

    void onQuarterFrame() {
        foreach(c; channels)
            c.onQuarterFrame();
    }

    void onHalfFrame() {
        foreach(c; channels)
            c.onHalfFrame();
    }

    real_t calcCurrentOutput() {
        return lookupMixerOutput(
            pulse[0].getOutput(), pulse[1].getOutput(),
            triangle.getOutput(), 0, 0);
    }

    void reset() {
        // Disable all channels by mimicing a write of $00 to the status register ($4015)
        writeStatus(APUStatus(0));
        // Clear the sample output buffer & reset the sample timer (?)
        sampleBuffer.reset();
        //sampleTimer.reset();
        // Reset the frame counter
        frameCounter.reset();
    }

    void writePulseCtrl(size_t channel, in PulseCtrl ctrl) {
        assert(channel >= 0 && channel < pulse.length);
        pulse[channel].setPulseCtrl(ctrl);
    }

    void writePulseSweepCtrl(size_t channel, in PulseSweepCtrl swpCtrl) {
        assert(channel >= 0 && channel < pulse.length);
        pulse[channel].setSweepCtrl(swpCtrl);
    }

    void writePulseTimerLow(size_t channel, in ubyte value) {
        assert(channel >= 0 && channel < pulse.length);
        pulse[channel].setTimerLow(value);
    }

    void writePulseTimerHigh(size_t channel, in TimerHigh value) {
        assert(channel >= 0 && channel < pulse.length);
        pulse[channel].setTimerHigh(value);
    }

    void writeTriangleCtrl(in TriangleCtrl ctrl) {
        triangle.setTriangleCtrl(ctrl);
    }

    void writeTriangleTimerLow(in ubyte value) {
        triangle.setTimerLow(value);
    }

    void writeTriangleTimerHigh(in TimerHigh value) {
        triangle.setTimerHigh(value);
    }

    void writeStatus(in APUStatus value) {
        if(!value.pulse1)
            pulse[0].disable();
        if(!value.pulse2)
            pulse[1].disable();
        if(!value.triangle)
            triangle.disable();
        // TODO: noise, DMC channels
    }

    APUStatus readStatus() {
        APUStatus result;
        result.frameInterrupt = frameCounter.frameInterrupt;
        // Reading this register clears the frame interrupt flag
        frameCounter.frameInterrupt = false;
        // TODO: DMC interrupt flag
        result.pulse1 = pulse[0].lengthCounter > 0;
        result.pulse2 = pulse[1].lengthCounter > 0;
        result.triangle = triangle.lengthCounter > 0;
        // TODO: noise, and DMC channels
        return result;
    }

    void writeFrameCounterCtrl(in FrameCounterCtrl value) {
        frameCounter.setFrameCounterCtrl(value);
    }

    // Linear approximation methods
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
