module mapper;

import std.format;
import std.algorithm;    // for min(...)
import std.stdio;
import std.bitmanip;
import bus;
import util;
import rom;
import ppu;
import apu : Divider;   // TODO: Move this to util?
import cpu;

private immutable addr HORIZ_MIRROR_MASK    = (~0x0400) & 0xFFFF;
private immutable addr VERT_MIRROR_MASK     = (~0x0800) & 0xFFFF;
private immutable FOUR_WAY_MASK             = 0xFFFF;   // no bit masking
private immutable NT_SELECT_MASK            = 0x0C00;

// CPU address space regions //////////////////////////////////////////////////////////////////////
private enum PRG_RAM_START                  = 0x6000;
private enum PRG_RAM_END                    = 0x7FFF;
// PRG RAM size is dictated by cartridge, up to 8KiB but often less
// When size is less than 8KiB (e.g. 2 - 4KiB), the remainder of address space
// is mirrored to fill the window
private enum PRG_ROM_START                  = 0x8000;
private enum PRG_ROM_END                    = 0xFFFF;
private enum PRG_ROM_SIZE                   = 0x4000;

private enum PRG_ROM_LOWER_START            = 0x8000;
private enum PRG_ROM_LOWER_END              = 0xBFFF;
private enum PRG_ROM_UPPER_START            = 0xC000;
private enum PRG_ROM_UPPER_END              = 0xFFFF;

// PPU address space regions //////////////////////////////////////////////////////////////////////
private enum CHR_START                      = 0x0000;
private enum CHR_END                        = 0x1FFF;
private enum CHR_SIZE                       = 0x2000;
// Lower CHR bank, aka the 'left' pattern table
private enum CHR_LOWER_START                = 0x0000;
private enum CHR_LOWER_END                  = 0x0FFF;
// Upper CHR bank, aka the 'right' pattern table
private enum CHR_UPPER_START                = 0x1000;
private enum CHR_UPPER_END                  = 0x1FFF;
// Nametable regions
private enum NT_START                       = 0x2000;
private enum NT_END                         = 0x3EFF;
// Nametables are only actually 4x 1KiB (0x400) in size,
// so 0x3000 - 0x3EFF is actually a mirror of 0x2000 - 0x2EFF

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

    // overridable
    bool getIRQStatus() {
        return false;
    }

    /// Helper function to translate PPU nametable horizontal mirroring
    pure static addr horizontalMirror(addr address) {
        // For horizontal mirroring:
        // $2400 mirrors $2000, $2C00 mirrors $2800, so value of bit 10 is ignored
        // Physical RAM is linear though, so $2800 is mapped to $2400 by replacing
        // bit 10 with the value of bit 11, and bit 11 is cleared
        // TLDR: bit 10 is overwritten with bit 11
        return (address & ~NT_SELECT_MASK) | ((address >> 1) & 0x0400);
    }

    pure static addr verticalMirror(addr address) {
        // Vertical mirroring -- bit 11 is ignored / cleared
        return (address & ~(1 << 11));
    }
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
        1: defaultMapperFactoryFunc!MMC1Mapper(),
        2: defaultMapperFactoryFunc!UxROMMapper(),
        4: defaultMapperFactoryFunc!MMC3Mapper(),
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

    alias ChrBank = ubyte[8192];
    ubyte[] chrRamBank;

    alias NTMirrorFunc = addr function(addr);
    NTMirrorFunc ntMirrorFunc;

    this(NESFile file, PPU ppu) {
        super(file, ppu);
        // Ensure the ROM has at least 1 PRG ROM bank(s)
        // NROM does not have a bank switching mechanism
        assert(file.prgRomBanks.length >= 1);
        auto prgRAMSize = (nesFile.header.prgRAMSize == 0 ? 8192 : nesFile.header.prgRAMSize);
        if(prgRAMSize)
            this.prgRAM = new ubyte[prgRAMSize];

        // If no CHR ROM banks provided, assume 8KiB of on-board CHR RAM is intended
        if(this.nesFile.chrRomBanks.length == 0)
            chrRamBank = new ubyte[8192];

        if(nesFile.header.mirrorMode == MIRROR_MODE_HORIZONTAL)
            ntMirrorFunc = &horizontalMirror;
        else
            ntMirrorFunc = &verticalMirror;
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
                        // Ignore the attempt to write to CHR ROM
                        debug writefln("[MAPPER] Attempted to write $%02X into CHR rom @ $%04X", value, address);
                    } else {
                        // Otherwise, assume the cartridge has (writable) CHR RAM to fill pattern space
                        assert(chrRamBank);
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
                        assert(chrRamBank);
                        return chrRamBank[(address & 0x1FFF)];
                    }
                }

            case 0x20: .. case 0x2F:
                // Nametables
                // NROM delegates to PPU internal VRAM, but mirroring arrangement depends on
                // solder pad configuration
                // TODO: Consider 4-screen mode, which means ignoring this bit
                addr target = ntMirrorFunc(address);
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
        // The 'upper' PRG bank ($C000-$FFFF) is fixed (cannot be bank switched) to the last bank in the ROM
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

class MMC1Mapper : NROMMapper {
    union LoadRegister {
        ubyte raw;
        struct {
            mixin(bitfields!(
                uint, "dataBit", 1,
                uint, "unused", 6,
                bool, "reset", 1,
            ));
        }
    }

    union ControlRegister {
        ubyte raw;
        struct {
            mixin(bitfields!(
                uint, "mirrorMode", 2,
                uint, "prgRomBankMode", 2,
                bool, "dualBankMode", 1,
                uint, "unused", 3,
            ));
        }
        alias raw this;
    }

    private static enum MirrorMode : uint {
        OneScreen_Low = 0,
        OneScreen_High = 1,
        Vertical = 2,
        Horizontal = 3,
    }

    private static enum PrgRomBankMode: uint {
        Full = 0,   // the full 32KiB space (both lower and upper banks) is switchable, ignoring low bit of bank index
        Full2 = 1,  // Ditto ^ ... maybe this doesn't make a good enum :-/
        LowBankFixed = 2,   // The 'first' bank is fixed to $8000, high bank ($C000) swappable
        HighBankFixed = 3,  // The 'last' bank is fixed to $C000, low bank ($8000) is swappable
    }

    ControlRegister control = ControlRegister(0x0C); // supposed power up state (prgRomBankMode == 3)
    ubyte[2] chrBankSelect;
    ubyte prgBankSelect;
    ubyte shiftReg;
    ubyte writeCount;

    this(NESFile file, PPU ppu) {
        super(file, ppu);
    }

    override void writeCPU(addr address, const ubyte value) {
        // Override writes from CPU to PRG ROM space, as this is the mechanism for interacting with the mapper controls
        if(address >= 0x8000 && address <= 0xFFFF) {
            writeLoadShiftRegister(address, LoadRegister(value));
            // The actual write is effectively a NOP, no need to forward / delegate to base class
        } else {
            // Delegate to base implementation
            super.writeCPU(address, value);
        }
    }

    override ubyte readCPU(addr address) {
        // Override reads from CPU to PRG ROM space, as this mapper utilizes bank switching
        if(address >= PRG_ROM_START && address <= PRG_ROM_END) {
            return readPrgRom(address);
        } else {
            // delegate to base implementation
            return super.readCPU(address);
        }
    }

    override void writePPU(addr address, const ubyte value) {
        readWritePpuMmc1!true(address, value);
    }

    override ubyte readPPU(addr address) {
        return readWritePpuMmc1!false(address);
    }

    ubyte readWritePpuMmc1(bool write)(addr address, const ubyte value=0) {
        // Only pattern (CHR) and nametable access is overridden, the rest (palettes?) can be
        // delegated to base implementation
        ubyte page = (address >> 8) & 0xFF;
        switch(page) {
            case 0x00: .. case 0x1F:
                return readWritePpuChr!write(address, value);

            case 0x20: .. case 0x2F:
                return readWritePpuNT!write(address, value);

            default:
                return readWritePPU!write(address, value);
        }
    }

    void resetShift() {
        // Reset the shift register and write count
        shiftReg = 0;
        writeCount = 0;
        debug(verbose) writefln("[MMC1] Resetting shift & write count...");
    }

    void commit(addr address) {
        // The registers (including shift) are all only 5 bits
        ubyte value = shiftReg & 0x1F;
        // bits 14 & 13 of the address determine which mapper register receives the value
        auto dest = (address >> 13) & 0x3;
        debug ubyte*[] regs = [&control.raw, &chrBankSelect[0], &chrBankSelect[1], &prgBankSelect];
        debug writefln("[MMC1] Writing %02X to register %d (was: %02X)", value, dest, *regs[dest]);
        switch(dest) {
            case 0:
                control.raw = value;
                break;
            case 1:
                chrBankSelect[0] = value;
                break;
            case 2:
                chrBankSelect[1] = value;
                break;
            case 3:
                prgBankSelect = value;
                break;
            default:
                assert(false, "This should not happen");
        }
    }

    void writeLoadShiftRegister(addr address, in LoadRegister value) {
        if(value.reset) {
            // Writing a value with reset bit set uncondtionally clears the shift register and resets the write count
            resetShift();
            // the control register is also 'soft reset' by ORing it with 0x0C (force prgRomBankMode to mode 3)
            debug(verbose) writefln("[MMC1] Force reset shift & control |= 0x0C");
            control.raw |= 0x0C;
        } else {
            // TODO: ignore consecutive cycle writes
            // if(thisCycle-1 == lastWriteCycle) return;
            // shift the data bit into the shift register, from LSB to MSB
            // Technically we're not truely shifting, but writing bits from right to left since our model of the
            // shift register is 8-bits rather than 5 bits.
            shiftReg |= (value.dataBit & 0x1) << writeCount++;
            // On the 5th write, the address is used to determine which mapper register to target and load with
            // contents of shift register
            if(writeCount >= 5) {
                commit(address);
                // Reset the shift register and write count
                resetShift();
            }
        }
    }

    /// Translate a PPU address in CHR range ($0000-$1FFFF) to a (bitpacked) bank index and local offset
    uint mapChrAddressToBankAndOffset(addr address) {
        assert(address >= CHR_START && address <= CHR_END);

        ubyte bankIdx;
        addr localOffset;

        if(control.dualBankMode) {
            bool upper = (address >= 0x1000);
            ubyte bankSelector = (upper ? chrBankSelect[1] : chrBankSelect[0]);
            // Translate 4KiB half-bank to 8KiB full bank index by dividing by 2
            bankIdx = (bankSelector >> 1) & 0x0F;
            // Translate the 8KiB offset to local offset by masking the low 12 bits and using the LSB of the bank
            // selector as the MSB
            localOffset = ((bankSelector&1) << 12) | (address & 0x0FFF);
        } else {
            // in 8KiB bank mode, only the first chrBankSelector is used and the lowest bit is ignored
            bankIdx = chrBankSelect[0] & 0x1E;
            // no translation of the local offset is necesary
            localOffset = (address & 0x1FFF);
        }
        return (bankIdx << 16) | localOffset;
    }

    ubyte readWritePpuChr(bool write)(addr address, const ubyte value = 0) {
        assert(address >= CHR_START && address <= CHR_END);

        auto mapped = mapChrAddressToBankAndOffset(address);
        ubyte bankIdx = (mapped >> 16) & 0xFF;
        addr offset = (mapped & 0x1FFF);

        // If we have CHR RAM ...
        if(nesFile.chrRomBanks.length <= 0) {
            // double check 8KiB of CHR RAM was allocated
            assert(chrRamBank);
            // Verify bank 0 was chosen
            if(bankIdx != 0) {
                // Assume this was a mistake, and log a warning
                // TODO: Output warning to log, not stdout
                debug writefln("[MMC1] Attempted to %s CHR RAM @ $%04X (%d:$%04X) !", (write ? format("write value $%02X to",value) : "read value from"), address, bankIdx, offset);
                // TODO: Determine best option -- abort, wrap / mirror, or ignore
                // For now, just wrap / mirror by proceeding
            }
            static if(write) {
                chrRamBank[offset] = value;
                // vestigal return value
                return value;
            } else {
                return chrRamBank[offset];
            }
        } else {
            // We have static CHR ROM
            assert(nesFile.chrRomBanks.length > 0);
            static if(write) {
                // Assume attempts to write to CHR ROM are a mistake
                // Log a warning and ignore the write
                debug writefln("[MMC1] Attempt to write $%02X to CHR ROM @ $%04X (%d:$%04X) !", value, address, bankIdx, offset);
                // vestigal return value
                return value;
            } else {
                // Verify the mapped bank index is valid, otherwise assume its a mistake
                if(bankIdx >= nesFile.chrRomBanks.length) {
                    // Log a warning
                    // TODO: output warning to logfile, not stdout
                    //writefln("[MMC1] Attempted to %s CHR ROM @ $%04X (%d:$%04X) !", (write ? format("write value $%02X to",value) : "read value from"), address, bankIdx, offset);
                    // TODO: Determine best option -- abort, wrap / mirror, or ignore
                    // For now, just wrap / mirror by adjusting the bankIndex and proceeding
                    bankIdx = bankIdx % nesFile.chrRomBanks.length;
                }
                return nesFile.chrRomBanks[bankIdx][offset];
            }
        }
        assert(false, "Control flow should not reach here");
    }

    ubyte mapPrgRomBankIndex(addr address) {
        assert(address >= PRG_ROM_START && address <= PRG_ROM_END);
        PrgRomBankMode mode = cast(PrgRomBankMode)control.prgRomBankMode;
        alias M = PrgRomBankMode;
        final switch(mode) {
            case M.Full:
            case M.Full2:
                // The full 32KiB PRG ROM space is switched between contiguous pairs of 16KiB ROM banks selected by
                // prgBankSelect (ignoring LSB)
                // the first or second bank of the pair is determined by bit 14 of the address
                return (prgBankSelect & 0xE) | ((address >> 14) & 1);

            case M.LowBankFixed:
                // The lower bank is fixed to the first bank, the upper bank is switched by prgBankSelect register
                return ((address & 0x4000) == 0 ? 0 : (prgBankSelect & 0xF));

            case M.HighBankFixed:
                // The upper (high) bank is fixed to the last bank, lower bank is switched by prgBankSelect register
                return ((address & 0x4000) > 0 ? (nesFile.prgRomBanks.length-1) & 0xFF : (prgBankSelect & 0xF));
        }
    }

    ubyte readPrgRom(addr address) {
        assert(address >= PRG_ROM_START && address <= PRG_ROM_END, "Invalid PRG address");
        // Map the address to the target PRG ROM bank index, based on the current mapping configuration
        ubyte bankIdx = mapPrgRomBankIndex(address);
        assert(bankIdx >= 0 && bankIdx < nesFile.prgRomBanks.length, format("Invalid bank index: %d [0,%d)", bankIdx, nesFile.prgRomBanks.length));
        // Translate to offset within local bank by masking out the upper 2 bits
        addr localOffset = (address & 0x3FFF);
        // return the value from the target bank and offset
        return nesFile.prgRomBanks[bankIdx][localOffset];
    }

    ubyte readWritePpuNT(bool write)(addr address, const ubyte value = 0) {
        assert(address >= 0x2000 && address <= 0x2FFF);
        // Unlike basic mappers, the nametable mirroring mode is governed by control register rather than
        // hardwired solder jumper.
        // It also adds new mirroring modes (more like 1 new mode with two sub-modes) -- single-screen mode
        // the sub-mode determines whether lower bank or upper bank is mirrored
        // If the mirror mode is horizontal or vertical, behavior is identical to base implementation
        addr target = address;
        alias M = MirrorMode;
        MirrorMode mode = cast(MirrorMode)control.mirrorMode;
        final switch(mode) {
            case M.OneScreen_Low:
                // Bits 11-10 are cleared
                target = (address & 0xF3FF);
                break;
            case M.OneScreen_High:
                // Bits 11-10 = 01
                target = (address & 0xF3FF) | 0x0400;
                break;
            case M.Horizontal:
                // Bit 11 overwrites bit 10, bit 11 cleared
                target = horizontalMirror(address);
                break;
            case M.Vertical:
                // Bit 11 is ignored / cleared
                target = verticalMirror(address);
                break;
        }
        static if(write) {
            // Write the target in VRAM
            ppu.writeVRAM(target, value);
            // vestigal return value
            return value;
        } else {
            // Read target from VRAM
            return ppu.readVRAM(target);
        }
    }
}

/// Implementation of MMC3 (iNes mapper 004), used by SMB3 et al
/// Reference: https://www.nesdev.org/wiki/MMC3
class MMC3Mapper : NROMMapper {

    // The iNES mapper ID corresponding to this mapper
    immutable static uint MAPPER_ID = 4;

    union BankSelectRegister {
        ubyte raw;
        struct {
            mixin(bitfields!(
                uint, "targetDataReg", 3,
                uint, "unused", 2,
                bool, "nothing", 1, // Not used for MMC3, but possibly used on MMC6
                bool, "prgRomBankMode", 1,
                bool, "chrA12Inversion", 1,
            ));
        }
    }

    alias BankDataRegister = ubyte;

    union MirrorConfigRegister {
        ubyte raw;
        struct {
            mixin(bitfields!(
                uint, "mirrorMode", 1,
                uint, "unused", 7,
            ));
        }
    }

    union PrgRamProtectRegister {
        ubyte raw;
        struct {
            mixin(bitfields!(
                uint, "ignored", 4,
                uint, "unused", 2,  // unused on MMC3, may be used for MMC6
                bool, "writeProtectEnable", 1,
                bool, "prgRamEnable", 1,
            ));
        }
    }

    enum BANK_SELECT_START  = 0x8000;   // Only EVEN addresses within this range
    enum BANK_SELECT_END    = 0x9FFF;
    enum BANK_DATA_START    = 0x8000;   // Only ODD addresses within this range
    enum BANK_DATA_END      = 0x9FFF;
    enum MIRROR_CFG_START   = 0xA000;   // Only EVEN addresses within this range
    enum MIRROR_CFG_END     = 0xBFFF;
    enum PRG_RAM_PROTECT_START  = 0xA000;   // Only ODD addresses within this range
    enum PRG_RAM_PROTECT_END    = 0xBFFF;
    enum IRQ_LATCH_START        = 0xC000;   // Only EVEN addresses within this range
    enum IRQ_LATCH_END          = 0xDFFF;
    enum IRQ_RELOAD_START       = 0xC000;   // Only ODD addresses within this range
    enum IRQ_RELOAD_END         = 0xDFFF;
    enum IRQ_ENABLE_START       = 0xE000;   // Only EVEN addresses within this range
    enum IRQ_ENABLE_END         = 0xFFFF;
    enum IRQ_DISABLE_START      = 0xE000;   // Only ODD addresses within this range
    enum IRQ_DISABLE_END        = 0xFFFF;

    enum MirrorMode : ubyte {
        VERTICAL = 0,
        HORIZONTAL = 1,
    }

    protected BankSelectRegister bankSelect;
    protected BankDataRegister[8] bankDataRegs;
    protected MirrorConfigRegister mirrorCfg;
    protected const(ubyte)[][4] activePrgRomBanks;   // 4x 8KiB PRG ROM banks
    protected const(ubyte)[][]  prgRomBanks;        // 16KiB ROM banks mapped into 8KiB sub-banks
    protected const(ubyte)[][8] activeChrRomBanks;  // 8x 1KiB CHR banks
    protected const(ubyte)[][]  chrRomBanks;        // 8KiB ROM banks mapped into 1KiB sub-banks
    protected Divider!ubyte scanlineCounter;
    protected bool irqEnabled;
    protected ubyte ppuA12History;
    protected bool irqStatus;

    this(NESFile file, PPU ppu) {
        super(file, ppu);
        // Initialize the scanline counter trigger
        scanlineCounter.tock = &onScanlineCounterTrigger;
        // Map the 16KiB PRG ROM banks from file into 2x8KiB banks (as slices)
        prgRomBanks = new const(ubyte[])[(nesFile.prgRomBanks.length*2)];
        foreach(i; 0..nesFile.prgRomBanks.length) {
            prgRomBanks[i<<1] = nesFile.prgRomBanks[i][0..0x2000];
            prgRomBanks[(i<<1)+1] = nesFile.prgRomBanks[i][0x2000..$];
        }
        // Initialize the cached PRG mappings
        updatePrgBankMaps();
        // Map the 8KiB CHR ROM banks of the file into 8x1KiB banks as slices
        chrRomBanks = new const(ubyte[])[nesFile.chrRomBanks.length*8];
        foreach(i; 0..nesFile.chrRomBanks.length) {
            chrRomBanks[i<<3] = nesFile.chrRomBanks[i][0..0x400];
            chrRomBanks[(i<<3)+1] = nesFile.chrRomBanks[i][0x400..0x800];
            chrRomBanks[(i<<3)+2] = nesFile.chrRomBanks[i][0x800..0xC00];
            chrRomBanks[(i<<3)+3] = nesFile.chrRomBanks[i][0xC00..0x1000];
            chrRomBanks[(i<<3)+4] = nesFile.chrRomBanks[i][0x1000..0x1400];
            chrRomBanks[(i<<3)+5] = nesFile.chrRomBanks[i][0x1400..0x1800];
            chrRomBanks[(i<<3)+6] = nesFile.chrRomBanks[i][0x1800..0x1C00];
            chrRomBanks[(i<<3)+7] = nesFile.chrRomBanks[i][0x1C00..0x2000];
        }
        // Initialize the cached CHR mappings
        updateChrBankMaps();
    }

    void onScanlineCounterTrigger() {
        irqStatus = irqEnabled;
    }

    override bool getIRQStatus() {
        return irqStatus;
    }

    void forceIRQReset() {
        // Clear the scanline counter so that it will be reset on next tick
        scanlineCounter.counter = 0;
    }

    void tickScanline() {
        scanlineCounter.tick();
    }

    void checkScanlineClock(addr address) {
        // Shift the history left by 1, set bit 0 to new A12 value
        ppuA12History = ((ppuA12History << 1) | ((address >> 12) & 1)) & 0xFF;
        // Scanline counter triggered by rising edge of A12 after three consecutive lows (xxxx0001)
        if((ppuA12History & 0xF) == 1) {
            debug(scanline) tickScanline();
        }
    }

    void updateChrBankMaps() {
        if(bankSelect.chrA12Inversion == 0) {
            // 4 lowest banks are mapped to 2x contiguous 2KiB banks (ignoring lower bit of bank selector)
            ubyte idx = (bankDataRegs[0]&0xFE) % chrRomBanks.length;
            activeChrRomBanks[0] = chrRomBanks[idx];
            activeChrRomBanks[1] = chrRomBanks[idx+1];
            idx = (bankDataRegs[1]&0xFE) % chrRomBanks.length;
            activeChrRomBanks[2] = chrRomBanks[idx];
            activeChrRomBanks[3] = chrRomBanks[idx+1];
            // 4 upper banks are mapped to 1KiB banks directly by registers R2-R5
            activeChrRomBanks[4] = chrRomBanks[bankDataRegs[2] % $];
            activeChrRomBanks[5] = chrRomBanks[bankDataRegs[3] % $];
            activeChrRomBanks[6] = chrRomBanks[bankDataRegs[4] % $];
            activeChrRomBanks[7] = chrRomBanks[bankDataRegs[5] % $];
        } else {
            // Reverse of the above
            activeChrRomBanks[0] = chrRomBanks[bankDataRegs[2] % $];
            activeChrRomBanks[1] = chrRomBanks[bankDataRegs[3] % $];
            activeChrRomBanks[2] = chrRomBanks[bankDataRegs[4] % $];
            activeChrRomBanks[3] = chrRomBanks[bankDataRegs[5] % $];
            ubyte idx = (bankDataRegs[0]&0xFE) % chrRomBanks.length;
            activeChrRomBanks[4] = chrRomBanks[idx];
            activeChrRomBanks[5] = chrRomBanks[idx+1];
            idx = (bankDataRegs[1]&0xFE) & chrRomBanks.length;
            activeChrRomBanks[6] = chrRomBanks[idx];
            activeChrRomBanks[7] = chrRomBanks[idx+1];
        }
    }

    void updatePrgBankMaps() {
        if(bankSelect.prgRomBankMode == 0) {
            // R6/7 determine lower two prg ROM banks, upper two prg ROM banks are fixed to last two banks
            // PRG ROM banks from file are in 16KiB banks, so we have to adapt to 8KiB banks
            // TODO: should use a mask rather than modulus
            activePrgRomBanks[0] = prgRomBanks[bankDataRegs[6] % $];
            activePrgRomBanks[1] = prgRomBanks[bankDataRegs[7] % $];
            activePrgRomBanks[2] = prgRomBanks[$-2];
            activePrgRomBanks[3] = prgRomBanks[$-1];
        } else {
            // Mapping is less straightforward
            activePrgRomBanks[0] = prgRomBanks[$-2];    // The first bank is fixed to second-to-last bank
            activePrgRomBanks[1] = prgRomBanks[bankDataRegs[7] % $]; // always determined by R7
            activePrgRomBanks[2] = prgRomBanks[bankDataRegs[6] % $]; // determined by R6
            activePrgRomBanks[3] = prgRomBanks[$-1];    // Always fixed to last bank
        }
    }

    void setBankDataRegister(in ubyte value) {
        uint target = (bankSelect.targetDataReg & 0x7);
        bankDataRegs[target] = value;
        // TODO: Update bank mapping caches?
        //debug(mmc3) writefln("[MMC3] Setting bank data register %d to $%02X", target, value);
        if(target >= 6) {
            updatePrgBankMaps();
        } else {
            updateChrBankMaps();
        }
    }

    void setBankSelectRegister(in BankSelectRegister value) {
        bankSelect = value;
        //debug(mmc3) writefln("[MMC3] Setting bank select register to: %02X", bankSelect.raw);
        updateChrBankMaps();
        updatePrgBankMaps();
        // TODO: Update bank mapping caches?
    }

    void setPrgRamProtectRegister(in PrgRamProtectRegister value) {
        // No-op
        debug(mmc3) writefln("[MMC3] Attempted to configure PRG RAM protection register: %02X", value.raw);
    }

    void setMirrorConfigRegister(in MirrorConfigRegister value) {
        mirrorCfg = value;
        if(mirrorCfg.mirrorMode == MirrorMode.HORIZONTAL) {
            ntMirrorFunc = &horizontalMirror;
            debug(mmc3) writefln("[MMC3] Setting mirror mode to HORIZONTAL");
        } else {
            ntMirrorFunc = &verticalMirror;
            debug(mmc3) writefln("[MMC3] Setting mirror mode to VERTICAL");
        }
    }

    void setIRQLatch(in ubyte value) {
        //irqReloadValue = value;
        // TODO: Set a reset flag?
        scanlineCounter.period = value;
        debug(mmc3) writefln("[MMC3] Setting IRQ Latch to: %d", value);
    }

    void enableIRQ() {
        irqEnabled = true;
        debug(mmc3) writefln("[MMC3] Enabling IRQs");
    }

    void disableIRQ() {
        // Writing to this register both disables IRQs AND acks any pending IRQs
        debug(mmc3) writefln("[MMC3] Disabling and acknowledging IRQ (was enabled: %s, was active: %s)", irqEnabled, irqStatus);
        irqStatus = irqEnabled = false;
    }

    override void writeCPU(addr address, const ubyte value) {
        // TODO: implement prg ram protect? According to ref
        //      (https://www.nesdev.org/wiki/MMC3#PRG_RAM_protect_($A001-$BFFF,_odd), most emulators opt to
        //      omit this functionality
        // Only for addresses > 0x8000 do we need to override default behavior
        if(address < 0x8000) {
            super.writeCPU(address, value);
            return;
        }
        // Broad classify by page
        ubyte page = (address >> 8) & 0xFF;
        bool odd = (address & 1) > 0;
        switch(page) {
            case 0x80: .. case 0x9F:
                // Bank select register / bank data register
                if(odd)
                    setBankDataRegister(value);
                else
                    setBankSelectRegister(BankSelectRegister(value));
                break;

            case 0xA0: .. case 0xBF:
                // Mirror config / PRG RAM protect registers
                if(odd)
                    setPrgRamProtectRegister(PrgRamProtectRegister(value));
                else
                    setMirrorConfigRegister(MirrorConfigRegister(value));
                break;

            case 0xC0: .. case 0xDF:
                // IRQ latch / IRQ reload
                if(odd)
                    forceIRQReset();
                else
                    setIRQLatch(value);
                break;

            case 0xE0: .. case 0xFF:
                // IRQ enable / disable
                if(odd)
                    enableIRQ();
                else
                    disableIRQ();
                break;
            default:
                assert(false, "Execution should never reach here");
        }
    }

    override ubyte readCPU(addr address) {
        // Only PRG ROM address ranges need behavior overridden
        if(address < 0x8000)
            return super.readCPU(address);

        // Mask the address for the local offset within the bank
        addr localOffset = address & 0x1FFF;
        // bits 13-14 determine which 2KiB bank
        addr bankIndex = (address >> 13) & 0x3;
        return activePrgRomBanks[bankIndex][localOffset];
    }

    override ubyte readPPU(addr address) {
        ubyte page = (address >> 8) & 0xFF;
        checkScanlineClock(address);
        switch(page) {
            case 0x00: .. case 0x1F:
                // CHR ROM (RAM?)
                addr localOffset = address & 0x3FF; // Local offset within the 1KiB banks
                // Bits 10-12 determine the index of the 1KiB bank within the 8KiB space
                addr bankIndex = (address >> 10) & 0x7;
                return activeChrRomBanks[bankIndex][localOffset];
            default:
                // Nametable + mirrors & palettes
                // Delegate to superclass
                return super.readPPU(address);
        }
        assert(false, "Execution should never reach this line");
    }

    override void writePPU(addr address, const ubyte value) {
        // Just need to possibly clock scanline counter
        checkScanlineClock(address);
        super.writePPU(address, value);
    }
}