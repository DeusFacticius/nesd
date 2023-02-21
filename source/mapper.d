module mapper;

import std.format;
import std.algorithm.comparison;    // for min(...)
import std.stdio;
import bus;
import util;
import rom;
import ppu;
import cpu;

immutable addr HORIZ_MIRROR_MASK    = (~0x0400) & 0xFFFF;
immutable addr VERT_MIRROR_MASK     = (~0x0800) & 0xFFFF;
immutable addr FOUR_WAY_MASK        = 0xFFFF;   // no bit masking
immutable addr NT_SELECT_MASK       = 0x0C00;

immutable addr PRG_RAM_START        = 0x6000;
immutable addr PRG_RAM_END          = 0x7FFF;
// PRG RAM size is dictated by cartridge, up to 8KiB but often less
// When size is less than 8KiB (e.g. 2 - 4KiB), the remainder of address space
// is mirrored to fill the window

/**
    Abstract class for representing a 'mapper' (onboard game-cartridge circuitry).

    Mappers define a subset of the main CPU bus address space ([$4020, $FFFF]), and fully define PPU bus address space.
    They act as the main interface between the core NES console and discrete game cartridges. Every game cartridge has
    some amount of onboard circuitry to enable access to ROM, optional additional RAM, optional bank switching
    mechanisms to overcome limited address space, and sometimes even extend system functionality with things like
    custom IRQs.
*/
class Mapper {

    this(NESFile nesFile, PPU ppu) {
        this.nesFile = nesFile;
        this.ppu = ppu;
    }

    abstract ubyte readPPU(addr address);
    abstract void writePPU(addr address, const ubyte value);

    abstract ubyte readCPU(addr address);
    abstract void writeCPU(addr address, const ubyte value);

//protected:
    NESFile nesFile;
    PPU     ppu;
}

alias MapperFactoryFunc = Mapper function(NESFile f, PPU p);

MapperFactoryFunc defaultMapperFactoryFunc(E: Mapper)() {
    MapperFactoryFunc result = (NESFile file, PPU ppu) {
        return new E(file, ppu);
    };
    return result;
}

__gshared static immutable MapperFactoryFunc[uint] MAPPER_REGISTRY;

shared static this() {
    import std.exception : assumeUnique;
    MapperFactoryFunc[uint] tmp = [
        0: defaultMapperFactoryFunc!NROMMapper(),
        2: defaultMapperFactoryFunc!UxROMMapper(),
    ];
    tmp.rehash();
    MAPPER_REGISTRY = assumeUnique(tmp);
}

Mapper createMapperForId(uint id, NESFile file, PPU ppu) {
    //auto factoryFunc = id in MAPPER_REGISTRY;
    if(id in MAPPER_REGISTRY) {
        return MAPPER_REGISTRY[id](file, ppu);
    }
    throw new Exception(format("No mapper registered for id: %d", id));
}

/// Abstract base implementation of a Mapper intended for subclassing.
// TODO: Finish me?
//class BaseMapper : Mapper {
//    this(NESFile file, PPU ppu) {
//        // Ensure the rom has at least 1 CHR ROM bank, NROM does not have a bank
//        // switching mechanism and CHR RAM not yet supported
//        //assert(file.chrRomBanks.length >= 1, "Expected 1 or more CHR ROM banks");
//        // Ensure the ROM has at least 1 (and not more than 2) PRG ROM bank(s)
//        // NROM does not have a bank switching mechanism
//        assert(file.prgRomBanks.length >= 1 && file.prgRomBanks.length <= 2, "Expected [1,2] PRG ROM banks");
//        super(file, ppu);
//    }
//
//    override ubyte readPPU(addr address) {
//        return readWritePPU!false(address);
//    }
//
//    override void writePPU(addr address, const ubyte value) {
//        readWritePPU!true(address, value);
//    }
//
//    override ubyte readCPU(addr address) {
//        return readWriteCPU!false(address);
//    }
//
//    override void writeCPU(addr address, const ubyte value) {
//        readWriteCPU!true(address, value);
//    }
//}

class NROMMapper : Mapper {

    // Unclear whether NROM actually supports PRG RAM / WRAM, but just in case...
    // This reference says it may have 2-4 KiB: https://www.nesdev.org/wiki/NROM
    // NES file dictates this in header (?), but 0 infers 8KiB (conflicting(?))
    // For now -- provide 2KiB and mirror
    ubyte[] prgRAM;

    alias ChrRamBank = ubyte[8192];
    ChrRamBank chrRamBank;

    this(NESFile file, PPU ppu) {
        super(file, ppu);
        // Ensure the rom has at least 1 CHR ROM bank, NROM does not have a bank
        // switching mechanism and CHR RAM not yet supported
        //assert(file.chrRomBanks.length >= 1, "Expected 1 or more CHR ROM banks");
        // Ensure the ROM has at least 1 (and not more than 2) PRG ROM bank(s)
        // NROM does not have a bank switching mechanism
        //assert(file.prgRomBanks.length >= 1 && file.prgRomBanks.length <= 2, "Expected [1,2] PRG ROM banks");
        auto prgRAMSize = (nesFile.header.prgRAMSize == 0 ? 8192 : nesFile.header.prgRAMSize);
        this.prgRAM = new ubyte[prgRAMSize];

        // Copy the contents of CHR ROM to CHR RAM, if available
        if(this.nesFile.chrRomBanks.length > 0)
            this.chrRamBank[] = this.nesFile.chrRomBanks[0][];
    }

    override ubyte readPPU(addr address) {
        return readWritePPU!false(address);
    }

    override void writePPU(addr address, const ubyte value) {
        readWritePPU!true(address, value);
    }

    override ubyte readCPU(addr address) {
        return readWriteCPU!false(address);
    }

    override void writeCPU(addr address, const ubyte value) {
        readWriteCPU!true(address, value);
    }

    /// Perform a read or write for the PPU
    ubyte readWritePPU(bool write)(addr address, const ubyte value = 0) {
        assert(address <= PPU_ADDR_MASK);
        // use the high-byte/'page' to broadly classify the target address range
        auto page = (address >> 8) & 0xFF;
        switch(page) {
            case 0x00: .. case 0x1F:
                // pattern tables, aka CHR ROM (sometimes RAM)
                static if(write) {
                    // If the NES ROM file provided CHR ROM banks, assume this write was a mistake (?)
                    if(nesFile.chrRomBanks.length > 0) {
                        debug writefln("[MAPPER] Attempted to write $%02X into pattern rom @ $%04X", value, address);
                    } else {
                        // Otherwise, assume the cartridge expects (writable) CHR RAM to fill pattern space
                        chrRamBank[(address & 0x1FFF)] = value;
                    }
                    // vestigal return value
                    return value;
                } else {
                    // NROM does not have a bank switching mechanism for multiple
                    // CHR ROM banks, assume first is only active bank (if provided by ROM),
                    // otherwise fall back to CHR RAM

                    if(nesFile.chrRomBanks.length > 0)
                        return nesFile.chrRomBanks[0][(address & 0x1FFF)];
                    else {
                        return chrRamBank[(address & 0x1FFF)];
                    }
                }

            case 0x20: .. case 0x2F:
                // Nametables
                // NROM delegates to PPU internal VRAM, but mirroring arrangement depends on
                // solder pad configuration
                // TODO: Consider 4-screen mode, which means ignoring this bit
                addr target;
                if(nesFile.header.mirrorMode == MIRROR_MODE_HORIZONTAL) {
                    // $2400 mirrors $2000, $2C00 mirrors $2800, so value of bit 10 is ignored
                    // Physical RAM is linear though, so $2800 is mapped to $2400 by replacing
                    // bit 10 with the value of bit 11, and bit 11 is cleared
                    target = (address & ~NT_SELECT_MASK) | ((address) >> 1 & NT_SELECT_MASK);
                } else {
                    // bit 11 is ignored
                    target = (address & ~(1 << 11));
                }
                static if(write) {
                    ppu.writeVRAM(target, value);
                    return value;
                } else {
                    return ppu.readVRAM(target);
                }
            case 0x30: .. case 0x3E:
                // nametable mirrors
                // Call self, masking the address to the source address of the mirror
                return readWritePPU!(write)(address & 0x2FFF, value);
            case 0x3F:
                // palettes
                return ppu.readWritePalettes!(write)(address, value);
            default:
                // TODO: throw an exception instead of hard-fail assertion?
                assert(false, format("Invalid PPU I/O operation (write=%s, $%04X)", write, address));
        }
    }

    /// Read / write for the CPU, but only within the address space governed by
    /// the cartridge ($4020-$FFFF)
    ubyte readWriteCPU(bool write, bool permissive=true)(addr address, const ubyte value=0) {
        // Assert the target is within the address range governed by mappers (cartridge)
        assert(address >= CPU_CARTRIDGE_SPACE_START && address <= CPU_CARTRIDGE_SPACE_END);
        // Use the high-byte / 'page' to broadly classify target
        ubyte page = (address >> 8) & 0xFF;
        switch(page) {
            case 0x60: .. case 0x7F:
                // mask to local prgRAM space
                auto offset = address % prgRAM.length;
                static if(write) {
                    prgRAM[offset] = value;
                    return value;
                } else {
                    return prgRAM[offset];
                }

            case 0x80: .. case 0xFF:
                // PRG ROM
                static if(write) {
                    // TODO: throw exception (?)
                    assert(false, format("Invalid CPU write to ROM space: $%04X", address));
                } else {
                    // If only 1 bank is provided, lower bank is mirrored into upper bank
                    // mask to local ROM bank space
                    auto offset = address & 0x3FFF;
                    // bit 14 dictates whether its upper or lower bank
                    auto bankIdx = (address >> 14) & 1;
                    // In the case of only a single bank + mirroring, constrain the bank
                    // index to 0 if upper bank is a mirror
                    bankIdx = min(bankIdx, nesFile.prgRomBanks.length-1);
                    assert(bankIdx >= 0 && bankIdx < nesFile.prgRomBanks.length);
                    return nesFile.prgRomBanks[bankIdx][offset];
                }
            default:
                // TODO: throw exception (?)
                // TODO: Re-enable this assertion?
                debug writefln("[MAPPER] Attempted access to invalid region -- A:$%04X V:$%02X W:%s", address, value, write);
                static if(permissive) {
                    static if(write) {
                        // just disregard the write ...
                        // vestigal return value
                        return value;
                    } else {
                        // Return fixed value (?)
                        return 0xFF;
                    }
                } else {
                    // Non permissive, error out / abort
                    assert(false, format("Invalid CPU -> mapper access: (Write: %s, $%04X)", write, address));
                }
        }
    }
}

class UxROMMapper : NROMMapper {
    ubyte bankSelect = 0;
    ubyte bankSelectMask;
    ubyte frozenBank;

    this(NESFile nesFile, PPU ppu) {
        super(nesFile, ppu);
        // The 'upper' bank ($C000-$FFFF) is fixed (cannot be bank switched), but unable to find specs on _which_
        // bank that is within the file :-/
        // For now -- assume its always the last one (?)
        auto numBanks = nesFile.prgRomBanks.length;
        assert(numBanks > 0);
        frozenBank = (numBanks - 1) & 0xFF;
        //debug(verbose) {
        //    writefln("[UxROM] Constructed UxROM mapper for nesfile: %s", nesFile);
        //}
        // Try to autodetect the appropriate bank select mask
        assert(numBanks == 8 || numBanks == 16);
        bankSelectMask = (numBanks == 8 ? 0x7 : 0xF);
    }

    // Override the base methods to utilize our decorated read/write method
    override ubyte readCPU(addr address) {
        return readWriteCpuUxRom!false(address);
    }

    override void writeCPU(addr address, const ubyte value) {
        readWriteCpuUxRom!true(address, value);
    }

    // Templated methods can't be overridden (because they can't be virtual), so we have to call this something else
    ubyte readWriteCpuUxRom(bool write)(addr address, const ubyte value=0) {
        // Assert the target is within the address range governed by mappers (cartridge)
        assert(address >= CPU_CARTRIDGE_SPACE_START && address <= CPU_CARTRIDGE_SPACE_END);
        // override the PRG ROM address space
        ubyte page = (address >> 8) & 0xFF;
        if(page >= 0x80 && page <= 0xFF) {
            static if(write) {
                // Writing to the normally read-only PRG ROM address space is the mechanism for controlling the
                // bank select register
                bankSelect = value & bankSelectMask;
                debug writefln("[UxROM] Setting bankSelect register to $%02X ($%02X) from write to $%04X", value, bankSelect, address);
                // vestigal return value
                return value;
            } else {
                // bit 14 determines whether target is lower ($8000-$BFFF) bank or upper ($C000-$FFFF) bank
                auto bankIdx = (address >> 14) & 1;
                // Bits 13-0 determine offset within the bank
                auto offset = (address & 0x3FFF);

                // Redundant but harmless safety checks
                assert(bankIdx >= 0 && bankIdx <= 1);
                assert(offset >= 0 && offset <= 0x3FFF);

                // The lower bank is defined by bankSelect, upper bank is fixed
                if(bankIdx == 0) {
                    // Dynamic bank
                    //auto wrapped = bankIdx % nesFile.prgRomBanks.length;
                    return nesFile.prgRomBanks[bankSelect][offset];
                } else {
                    // Fixed bank
                    return nesFile.prgRomBanks[frozenBank][offset];
                }
            }
        }
        // delegate to default / superclass
        return readWriteCPU!write(address, value);
    }
}