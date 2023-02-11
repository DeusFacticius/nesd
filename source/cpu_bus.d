module cpu_bus;

import std.format;
import std.stdio;
import cpu;
import bus;
import ppu;
import util;
import mapper;
import peripheral;

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

immutable size_t NUM_PERIPHERALS = 2;
immutable addr JOYSTICK1 = 0x4016;
immutable addr JOYSTICK2 = 0x4017;

class CPUBus : NESBus {
public:
    // TODO: Revise visibility of members
    CPU cpu;
    PPU ppu;
    Mapper mapper;
    AbstractPeripheral[NUM_PERIPHERALS] inputs;

    this(CPU cpu, PPU ppu, Mapper mapper=null, AbstractPeripheral input1=null, AbstractPeripheral input2=null) {
        this.cpu = cpu;
        this.ppu = ppu;
        this.mapper = mapper;
        inputs[0] = (input1 ? input1 : new NullPeripheral(PeripheralPort.PORT1));
        inputs[1] = (input2 ? input2 : new NullPeripheral(PeripheralPort.PORT2));
    }

    void setInput(PeripheralPort port, AbstractPeripheral input) {
        input = (input ? input : new NullPeripheral());
        input.port = port;
        final switch(port) {
            case PeripheralPort.PORT1:
                inputs[0] = input;
                break;

            case PeripheralPort.PORT2:
                inputs[1] = input;
                break;
        }
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
                    ppu.writeOAMADDR(value);
                    // vestigal return value
                    return value;
                } else {
                    // TODO: Emit a warning? This is odd behavior
                    return readPPUOpenBus();
                }

            case 4:
                // OAM Data -- read/write
                static if(write) {
                    ppu.writeOAMDATA(value);
                    // vestigal return value
                    return value;
                } else {
                    return ppu.readOAMDATA();
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
        assert(address == OAMDMA_ADDRESS);
        static if(write) {
            // do the thing
            cpu.dmaTransfer(value);
            // vestigal return value
            return value;
        } else {
            // TODO: Emit a warning? this is unusual behavior
            return readOpenBus();
        }
    }

    ubyte readWriteSND_CHN(bool write)(const ubyte value) {
        // TODO: Implement me
        static if(write) {
            debug writefln("[CPU BUS] Attempted to write ($%02X) to SND_CHN ($4015)", value);
        } else {
            debug writefln("[CPU BUS] Attempted to read from SDN_CHN ($4015)");
        }
        return 0;
    }

    ubyte readWriteJoystickIO(bool write)(addr address, const ubyte value=0) {
        assert(address >= 0x4016 && address <= 0x4017);
        static if(write) {
            // Somewhat conmplicated here -- a write to 4016 (JOY1)
            // strobes the input devices based on the low bit,
            // while a write to 4017 (JOY2) actually controls the
            // APU(?) frame counter controller
            // There is more to it than this, but this is a good-enough
            // solution for now
            // See: https://www.nesdev.org/wiki/Input_devices
            if(address == JOYSTICK1) {
                // Strobe all the inputs
                foreach(input; inputs) {
                    input.setStrobe(value & 1);
                }
            } else {
                assert(address == JOYSTICK2);
                writeFrameCounterControl(value);
            }
            // vestigal return value
            return value;
        } else {
            // Reading from inputs
            if(address == JOYSTICK1) {
                // Only the low bit is controlled by the input, the rest
                // are open bus, but some games _expect_ a specific value
                // in these upper bits, so we cheat and hard-code that value
                return (0x40 | inputs[0].readAndShift());
            } else {
                assert(address == JOYSTICK2);
                return (0x40 | inputs[1].readAndShift());
            }
        }
        //assert(false, "Should not happen");
    }

    void writeFrameCounterControl(const ubyte value) {
        // TODO: implement me
        //assert(false, "Not implemented yet!");
        debug writefln("[CPU BUS] Attempted to write $%02X to $4017 (frame counter control)!", value);
    }

    ubyte read(const addr address) {
        return readWrite!false(address);
    }

    void write(const addr address, const ubyte value) {
        readWrite!true(address, value);
    }
}