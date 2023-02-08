module cpu_bus;

import std.format;
import cpu;
import bus;
import ppu;
import util;
import mapper;

/***************************
NES (CPU) Memory map

    Reference: https://www.nesdev.org/wiki/CPU_memory_map

    Start   End     Size    Desc.
    ---------------------------------------------
    $0000 - $07FF   $0800   2KiB Internal RAM
    $0800 - $0FFF   $0800   Mirror of RAM ($0000-$07FF)
    $1000 - $17FF   $0800   Mirror of RAM ($0000-$07FF)
    $1800 - $1FFF   $0800   Mirror of RAM ($0000-$07FF)
    $2000 - $2007   $0008   NES PPU Registers
    $2008 - $3FFF   $1FF8   Mirrors of $2000-$2007 (Repeats every 8 bytes)
    $4000 - $4017   $0018   NES APU & I/O Registers (sound, controllers, etc.)
    $4018 - $401F   $0008   'APU and I/O functionality that is normally disabled'
    $4020 - $FFFF   $BFE0   Cartridge space (Controlled by mapper)

    For _most_ mappers:
    $6000 - $7FFF   $2000   Battery backed or work RAM
    $8000 - $FFFF   $8000   'Usual ROM, commonly with mapper registers'

    Important addresses:
    $FFFA - $FFFB   $0002   NMI vector
    $FFFC - $FFFD   $0002   Reset vector
    $FFFE - $FFFF   $0002   IRQ/BRK vector

*/

class CPUBus : NESBus {
public:
    // TODO: Revise visibility of members
    CPU cpu;
    PPU ppu;
    Mapper mapper;

    this(CPU cpu, PPU ppu, Mapper mapper=null) {
        this.cpu = cpu;
        this.ppu = ppu;
        this.mapper = mapper;
    }

    ubyte readWrite(bool write)(addr address, const ubyte value=0) {
        // Use high-byte / 'page' to broadly classify target
        ubyte page = (address >> 8) & 0xFF;
        switch(page) {
            case 0x00: .. case 0x1F:
                // NES internal RAM (+ mirrors)
                // $0000 - $1FFF
                // Mask (for mirroring) to local RAM offset
                addr offset = address & CPU_RAM_MASK;
                static if(write) {
                    cpu.writeRAM(offset, value);
                    // vestigal return value
                    return value;
                } else {
                    return cpu.readRAM(offset);
                }

            case 0x20: .. case 0x3F:
                // PPU registers (and mirrors, every 8 bytes)
                // $2000 - $3FFF
                return readWritePPURegister!(write)(address, value);
            case 0x40:
                // APU + I/O registers + some cartridge space
                if(address >= 0x4000 && address <= 0x401F) {
                    return readWriteIO!(write)(address, value);
                } else {
                    static if(write) {
                        mapper.writeCPU(address, value);
                        // vestigal return value
                        return value;
                    } else {
                        return mapper.readCPU(address);
                    }
                }
            case 0x41: .. case 0xFF:
                // Cartridge space
                static if(write) {
                    mapper.writeCPU(address, value);
                    // vestigal return value
                    return value;
                } else {
                    return mapper.readCPU(address);
                }

            default:
                // Throw an exception (?)
                assert(false, "This should not happen");
        }
    }

    ubyte readWritePPURegister(bool write)(addr address, const ubyte value=0) {
        // Assert this was called with the correct target range
        assert(address >= 0x2000 && address <= 0x3FFF);
        // Because the PPU registers are mirrored every 8 bytes, only the low 3 bits matter
        ubyte target = address & 0x07;
        switch(target) {
            case 0:
                // PPUCTRL -- write only
                static if(write) {
                    ppu.writePPUCTRL(value);
                    // vestigal return value
                    return value;
                } else {
                    return readPPUOpenBus();
                }

            case 1:
                // PPUMASK -- write only
                static if(write) {
                    ppu.writePPUMASK(value);
                    // vestigal return value
                    return value;
                } else {
                    return readPPUOpenBus();
                }

            case 2:
                // PPUSTATUS -- read only
                static if(write) {
                    // not implemented (?)
                    // TODO: populate ppu address bus latch at least
                    // vestigal return value
                    return value;
                } else {
                    return ppu.readPPUSTATUS();
                }

            case 3:
                // OAM Address -- write only
                static if(write) {
                    // TODO: Implement me
                    assert(false, "OAMADDR Not implemented!");
                    // vestigal return value
                } else {
                    return readPPUOpenBus();
                }

            case 4:
                // OAM Data -- read/write
                static if(write) {
                    // TODO: Implement me
                    assert(false, "Not implemented!");
                    // vestigal return value
                } else {
                    // TODO: Implement me
                    assert(false, "Not implmented!");
                }

            case 5:
                // PPUSCROLL -- write (x2)
                static if(write) {
                    ppu.writePPUSCROLL(value);
                    // vestigal return value
                    return value;
                } else {
                    return readPPUOpenBus();
                }

            case 6:
                // PPUADDR -- write (x2)
                static if(write) {
                    ppu.writePPUADDR(value);
                    // vestigal return value
                    return value;
                } else {
                    return readPPUOpenBus();
                }

            case 7:
                // PPUDATA -- read/write
                static if(write) {
                    ppu.writePPUDATA(value);
                    // vestigal return value
                    return value;
                } else {
                    return ppu.readPPUDATA();
                }

            default:
                assert(false, "This should not happen");
        }
    }

    ubyte readPPUOpenBus() {
        // TODO: implement me (properly) -- return the PPU's data bus latch value, not the CPUs
        return readOpenBus();
    }

    ubyte readWriteIO(bool write)(addr address, const ubyte value=0) {
        // TODO: Replace magic constants here with symbols
        if(address >= 0x4000 && address <= 0x4013) {
            // APU (sound) register
            return readWriteAPURegister!(write)(address, value);
        } else if(address == 0x4014) {
            // OAM DMA
            return readWriteOAMDMA!(write)(address, value);
        } else if(address == 0x4015) {
            // Sound channels enable / sound channel and IRQ status
            return readWriteSND_CHN!(write)(value);
        } else if(address >= 0x4016 && address <= 0x4017) {
            // Joystick + framecounter I/O
            return readWriteJoystickIO!(write)(address, value);
        } else {
            assert(false, format("Invalid address passed to readWriteIO: %04X", address));
        }
    }

    ubyte readWriteAPURegister(bool write)(addr address, const ubyte value=0) {
        assert(address >= 0x4000 && address <= 0x4013);
        // TODO: implement me
        static if(write) {
            // do the thing
            // vestigal return value
            return value;
        } else {
            return readOpenBus();
        }
    }

    ubyte readOpenBus() {
        return cpu.dataLine;
    }

    ubyte readWriteOAMDMA(bool write)(addr address, const ubyte value=0) {
        // TODO: implement me
        static if(write) {
            // do the thing
            assert(false, "OAMDMA not implemented yet!");
            // vestigal return value
            //return value;
        } else {
            return readOpenBus();
        }
    }

    ubyte readWriteSND_CHN(bool write)(const ubyte value) {
        // TODO: implement me
        return 0;
    }

    ubyte readWriteJoystickIO(bool write)(addr address, const ubyte value=0) {
        // TODO: implement me
        return 0;
    }

    ubyte read(const addr address) {
        return readWrite!false(address);
    }

    void write(const addr address, const ubyte value) {
        readWrite!true(address, value);
    }
}