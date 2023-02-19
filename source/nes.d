module nes;

// Master / facade / mediator for the aggregate of individual
// NES components

debug import std.stdio;
debug import std.format;
import ppu;
import cpu;
import apu;
import cpu_bus;
import util;
import rom;
import mapper;

// Helpful symbolic constants

// The master clock speed, in MHz
// (Approximate period of 46.56 nanoseconds / cycle)
immutable NES_MASTER_CLOCK_FREQ_MHZ = 21.477272; // +- 40 Hz
// 'By definition'
immutable NES_IDEAL_MASTER_CLOCK_FREQ_MHZ = 236.25 / 11.0;

immutable size_t NES_CPU_CLOCK_DIVIDER = 12;
immutable size_t NES_NTSC_PPU_CLOCK_DIVIDER = 4;

class NES {
    CPU cpu;
    APU apu;
    PPU ppu;
    CPUBus cpuBus;
    NESFile nesFile;
    Mapper  mapper;
    size_t tickCounter;

    this() {
        cpu = new CPU();
        apu = new APU();
        ppu = new PPU();
        cpuBus = new CPUBus(cpu, apu, ppu);
        cpu.bus = cpuBus;

        ppu.vblankInterruptListener = &this.onVBlankInterrupt;
    }

    void onVBlankInterrupt(PPU ppu) {
        assert(this.ppu is ppu);
        cpu.enqueueNMIInterrupt();
    }

    void insertCartridge(NESFile crt) {
        // Eject any existing cartridge
        ejectCartridge();
        if(crt) {
            // Initialize cartridge-dependent components
            nesFile = crt;
            mapper = createMapperForId(crt.mapperId, crt, ppu);
            cpuBus.mapper = mapper;
            ppu.mapper = mapper;

            reset();
        }
    }

    void ejectCartridge() {
        // Clear the cartridge dependent components
        // TODO: destroy? or just set null and let GC pickup?
        mapper = null;
        nesFile = null;
        ppu.mapper = null;
        cpuBus.mapper = null;
    }

    void reset() {
        tickCounter = 0;
        cpu.reset();
        apu.reset();
        ppu.reset();
    }

    void tick() {
        ++tickCounter;
        if(tickCounter % NES_CPU_CLOCK_DIVIDER == 0) {
            cpu.doTick();
            apu.doTick();
        }
        if(tickCounter % NES_NTSC_PPU_CLOCK_DIVIDER == 0)
            ppu.doTick();
    }

    void altTick() {
        // Alternative tick mechanism --
        // Instead of ticking the NES master clock once per
        // tick, instead just run: 1x CPU tick, 3X PPU ticks,
        // and add 12 ticks to counter (e.g. skip ticks that do
        // nothing but increment counter
        ppu.doTick();
        cpu.doTick();
        apu.doTick();
        ppu.doTick();
        ppu.doTick();
        tickCounter += NES_CPU_CLOCK_DIVIDER;
    }

    void cpuStep() {
        // Another alternative progression mechanism --
        // Tick cpu & ppu in sync until CPU has completed
        // an instruction, as indicated by response from cpu.doTick()
        bool cpuInstructionFinished = false;
        do {
            ppu.doTick();
            apu.doTick();
            cpuInstructionFinished = cpu.doTick();
            ppu.doTick();
            ppu.doTick();
            tickCounter += NES_CPU_CLOCK_DIVIDER;
        } while(!cpuInstructionFinished);
    }

    void altTick2() {
        // Another, ideally faster tick mechanism --
        // Tick for a full PPU frame
        auto frameCounter = ppu.frameCounter;
        while(frameCounter == ppu.frameCounter) {
            altTick();
        }
    }

    debug string buildTraceLine() {
        string cpuTrace = cpu.getStatusString();
        cpuTrace ~= format(" PPU:%3d,%3d CYC:%d",ppu.scanline, ppu.cycle, cpu.tickCounter);
        return cpuTrace;
    }
}

@("nestest sanity")
unittest {
    import fluentasserts.core.expect;

    auto nes = new NES();
    auto rom = new NESFile("nestest.nes");
    nes.insertCartridge(rom);

    // Run for N ticks
    immutable N = 1000;
    foreach(i; 0..N) {
        nes.tick();
        expect(nes.cpu.tickCounter).to.equal(nes.tickCounter / NES_CPU_CLOCK_DIVIDER);
        expect(nes.ppu.tickCounter).to.equal(nes.tickCounter / NES_NTSC_PPU_CLOCK_DIVIDER);
        expect(nes.tickCounter).to.equal(i+1);
    }
    // Assert respective components ticked at their prescaled rates
    writefln("NES Ticks:%d\tCPU Ticks: %d\tPPU Ticks: %d", nes.tickCounter, nes.cpu.tickCounter, nes.ppu.tickCounter);
    expect(nes.cpu.tickCounter).to.equal(N / NES_CPU_CLOCK_DIVIDER);
    expect(nes.ppu.tickCounter).to.equal(N / NES_NTSC_PPU_CLOCK_DIVIDER);
}

@("auto_nestest")
unittest {
    import fluentasserts.core.expect;
    auto nes = new NES();
    auto rom = new NESFile("nestest.nes");
    nes.insertCartridge(rom);

    // Set to a defined state
    nes.cpu.regs.PC = 0xC000;
    nes.cpu.regs.P.P = 0x24;
    nes.cpu.regs.S = 0xFD;
    // starting at CPU cycle 4 (12*4 = 48 master clock cycles)
    nes.cpu.tickCounter = 7;
    nes.tickCounter = nes.cpu.tickCounter*NES_CPU_CLOCK_DIVIDER;
    // = 12 PPU cycles
    foreach(i; 0..(3*nes.cpu.tickCounter))
        nes.ppu.doTick();

    auto f = File("auto_nestest.log", "wb");
    scope(exit) f.close();
    // Run ~ 100 cpu instructions
    immutable auto CPU_INSTRUCTIONS = 8991;
    foreach(i; 0..CPU_INSTRUCTIONS) {
        string line = nes.buildTraceLine();
        //writeln(line);
        f.writeln(line);
        nes.cpuStep();
    }
}