module mapper;

import std.format;
import std.algorithm.comparison;    // for min(...)
debug import std.stdio;
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

class Mapper {

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

class NROMMapper : Mapper {

    // Unclear whether NROM actually supports PRG RAM / WRAM, but just in case...
    // This reference says it may have 2-4 KiB: https://www.nesdev.org/wiki/NROM
    // NES file dictates this in header (?), but 0 infers 8KiB (conflicting(?))
    // For now -- provide 2KiB and mirror
    ubyte[] prgRAM;

    this(NESFile file, PPU ppu) {
        // Ensure the rom has at least 1 CHR ROM bank, NROM does not have a bank
        // switching mechanism and CHR RAM not yet supported
        assert(file.chrRomBanks.length >= 1);
        // Ensure the ROM has at least 1 (and not more than 2) PRG ROM bank(s)
        // NROM does not have a bank switching mechanism
        assert(file.prgRomBanks.length >= 1 && file.prgRomBanks.length <= 2);
        this.nesFile = file;
        this.ppu = ppu;
        auto prgRAMSize = (nesFile.header.prgRAMSize == 0 ? 8192 : nesFile.header.prgRAMSize);
        this.prgRAM = new ubyte[prgRAMSize];
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
                    // TODO: should this be allowed?
                    //assert(false, "Attempted to write to pattern ROM!");
                    debug writefln("[MAPPER] Attempted to write $%02X into pattern rom @ $%04X", value, address);
                    // vestigal return value
                    return value;
                } else {
                    // NROM does not have a bank switching mechanism for multiple
                    // CHR ROM banks, assume first is only active bank
                    return nesFile.chrRomBanks[0][(address & 0x1FFF)];
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
    ubyte readWriteCPU(bool write)(addr address, const ubyte value=0) {
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
                assert(false, format("Invalid CPU -> mapper access: (Write: %s, $%04X)", write, address));
        }
    }
}