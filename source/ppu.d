module ppu;

import std.stdio;
import std.bitmanip;
import std.container;
import bus;
import util;
import palette;
import mapper;

// Useful constants
immutable int NTSC_SCANLINES = 262;
immutable int NTSC_VBLANK_SCANLINES = 20;
immutable int NTSC_VISIBLE_SCANLINES = 240;
immutable int NTSC_PRERENDER_SCANLINE = 261;
immutable int NTSC_PPU_CLOCK_DIVIDER = 4;
immutable int NTSC_SCANLINE_CYCLES = 341; // [0, 340]
immutable int NTSC_SCREEN_W = 256;
immutable int NTSC_SCREEN_H = 240;

/// Approximate number of ticks / cycles per frame. The actual number
/// is variable, since the PPU skips the idle cycle of the first scanline on odd
/// frames.
immutable int PPU_CYCLES_PER_FRAME  = NTSC_SCANLINES * NTSC_SCANLINE_CYCLES;
/// Exact number of tics / cycles per _even_ frame.
immutable int PPU_CYCLES_PER_EVEN_FRAME = NTSC_SCANLINES * NTSC_SCANLINE_CYCLES;
/// Exact number of ticks / cycles per _odd_ frame.
immutable int PPU_CYCLES_PER_ODD_FRAME = (PPU_CYCLES_PER_EVEN_FRAME-1);

// PPU control registers
immutable addr PPUCTRL = 0x2000;
immutable addr PPUMASK = 0x2001;
immutable addr PPUSTATUS = 0x2002;
immutable addr OAMADDR = 0x2003;
immutable addr OAMDATA = 0x2004;
immutable addr PPUSCROLL = 0x2005;
immutable addr PPUADDR = 0x2006;
immutable addr PPUDATA = 0x2007;
immutable addr OAMDMA = 0x4014;

// PPU memory map
immutable addr PPU_PATTERN_TABLES_START = 0x0000;
immutable addr PPU_PATTERN_TABLES_END   = 0x1FFF;
immutable addr[2] PPU_PATTERN_TABLE_OFFSETS = [ 0x0000, 0x1000 ];
immutable addr PPU_PATTERN_TABLES_MASK = 0x1FFF;
immutable addr PPU_PATTERN_TABLE_SIZE = 0x1000;
immutable addr[4] PPU_NAMETABLE_OFFSETS = [ 0x2000, 0x2400, 0x2800, 0x2C00 ];
immutable addr PPU_NAMETABLE_SIZE = 0x0400;
immutable addr PPU_NAMETABLE_MIRRORS_OFFSET = 0x3000;
immutable addr PPU_NAMETABLE_MIRRORS_SIZE = 0x0F00;
immutable addr PPU_ATTR_TABLE_SIZE = 0x40;
immutable addr PPU_ATTR_TABLE_OFFSET = 0x23C0;
immutable addr PPU_PALETTES_START = 0x3F00;
immutable addr PPU_PALETTES_END = 0x3F1F;
immutable addr PPU_PALETTES_SIZE = 0x0020;
immutable addr PPU_PALETTES_MIRRORS_START = 0x3F20;
immutable addr PPU_PALETTES_MIRRORS_SIZE = 0x00E0;
immutable addr PPU_PALETTES_MIRRORS_END = 0x3FFF;

immutable addr PPU_ADDR_MASK = 0x3FFF;  // 14 LSB
immutable addr PPU_ADDR_REGISTER_MASK = 0x7FFF; // 15 bits wide (highest bit(s) not used for addressing)

immutable size_t PRIMARY_OAM_ENTRIES = 64;
immutable size_t SECONDARY_OAM_ENTRIES = 8;

/// Size of the PPU's internal VRAM bank, generally mapped (with configurable mirroring) into
/// $2000-$2FFF, providing up to 2 (real) nametables, and 2 mirrored nametables. May be partly
/// or fully remapped into cartridge RAM by mapper (to provide additional nametables).
immutable size_t PPU_INTERNAL_VRAM_SIZE = 0x0800;
immutable addr PPU_INTERNAL_VRAM_MASK = 0x07FF;

union PPUControl {
    ubyte value;
    struct {
        mixin(bitfields!(
            uint, "nametableSelect", 2,
            uint, "vramAddrInc", 1,
            uint, "smallSpritePtrnTbl", 1,
            uint, "bgPtrnTbl", 1,
            bool, "useLargeSprites", 1,
            uint, "masterSlaveSelect", 1,
            bool, "nmiEnabled", 1
        ));
    }
}
static assert(PPUControl.sizeof == ubyte.sizeof);

union PPUMask {
    ubyte value;
    struct {
        mixin(bitfields!(
            bool, "greyscaleEnabled", 1,
            bool, "leftClipBG", 1,
            bool, "leftClipSprites", 1,
            bool, "bgEnabled", 1,
            bool, "spritesEnabled", 1,
            bool, "empRed", 1,
            bool, "empGreen", 1,
            bool, "empBlue", 1
        ));
    }
}
static assert(PPUMask.sizeof == ubyte.sizeof);

union PPUStatus {
    ubyte value;
    struct {
        mixin(bitfields!(
            uint, "openBus", 5,
            bool, "spriteOverflow", 1,
            bool, "sprite0Hit", 1,
            bool, "vblankActive", 1,
        ));
    }
}
static assert(PPUStatus.sizeof == ubyte.sizeof);
immutable ubyte PPUSTATUS_MASK = 0xE0;

union VPtrAddr {
    addr raw;
    struct {
        mixin(bitfields!(
            uint, "coarseX", 5,
            uint, "coarseY", 5,
            uint, "nametableSelect", 2,
            uint, "fineY", 3,
            uint, "unused", 1,
        ));
    }

    alias raw this;

    void syncHorizontal(in VPtrAddr other) {
        // Copy coarseX
        coarseX = other.coarseX;
        // Set X bit of nametable select to `other`, maintain existing Y bit
        nametableSelect = (nametableSelect & 0x02) | (other.nametableSelect & 0x01);
    }

    void syncVertical(in VPtrAddr other) {
        // Copy coarseY, fineY
        coarseY = other.coarseY;
        fineY = other.fineY;
        // Copy the Y bit of nametableSelect, maintain existing X bit
        nametableSelect = (other.nametableSelect & 0x02) | (nametableSelect & 0x01);
    }

    void incrementY() {
        if(fineY < 7) {
            // increment operators don't work on bitfields since
            // they're implemented as property accessor functions
            fineY = fineY+1;
        } else {
            // fineY wraps to coarseY
            fineY = 0;
            if(coarseY == 29) {
                // coarseY wraps to vertical nametableSelect bit
                coarseY = 0;
                // Flip vertical nametableSelect bit
                nametableSelect = nametableSelect ^ 0x02;
            } else if(coarseY == 31) {
                // Quirk -- the Y scroll can intentionally be set to an out of range
                // value ([0, 29]), and cause attribute data to be read as tile data.
                // Supposedly some games utilize this
                // A real NES handles this by wrapping the Y scroll, but does NOT
                // carry / flip the vertical nametable
                coarseY = 0;
            } else {
                coarseY = coarseY+1;
            }
        }
    }

    void incrementCoarseX() {
        if(coarseX == 31) {
            // coarseX wraps to X bit of nametableSelect
            coarseX = 0;
            // Flip the horizontal bit of nametableSelect
            nametableSelect = nametableSelect ^ 0x01;
        } else {
            coarseX = coarseX+1;
        }
    }
}
static assert(VPtrAddr.sizeof == addr.sizeof);

union OAMAttr {
    ubyte attributes;
    struct {
        mixin(bitfields!(
            uint, "palette", 2,
            uint, "reserved", 3,
            uint, "priority", 1,
            bool, "flipHorizontal", 1,
            bool, "flipVertical", 1,
        ));
    }
}
static assert(OAMAttr.sizeof == ubyte.sizeof);

union OAMEntry {
    ubyte[4] values;
    struct {
        ubyte y;
        union {
            ubyte tileSelector;
            struct {
                mixin(bitfields!(
                    uint, "bankIndex", 1,
                    uint, "tileIndex", 7,
                ));
            }
        }
        OAMAttr attrib;
        ubyte x;
    }
}
static assert(OAMEntry.sizeof == 4*ubyte.sizeof);

union PaletteEntry {
    ubyte packed;
    struct {
        mixin(bitfields!(
            uint, "hue", 4,
            uint, "value", 2,
            uint, "unused", 2,
        ));
    }
    alias packed this;
}
static assert(PaletteEntry.sizeof == ubyte.sizeof);

alias Palette = PaletteEntry[4];
// Simulated 256x240 screen image, where each byte is the value of a PaletteEntry
// (to be converted into a renderable RGB surface)
// In D -- rectangular static array dimensions are read right-to-left,
// while indices are read left-to-right
alias NtscNesScreen = ubyte[NTSC_SCREEN_W][NTSC_SCREEN_H];

/// Delegate / handler for triggering vblank NMI that is only
/// called if PPUCTRL.nmiEnabled is set
alias VBlankInterruptListener = void delegate(PPU ppu);
/// Delegate / handler intended for rendering the screen after each
/// frame, that is called regardless of nmiEnabled status
/// that is called regardless of NMI status.
alias FrameListener = void delegate(const PPU ppu, const NtscNesScreen screen);

class PPU {
    // TODO: Refactor attribute / method visibility to expose only what's necessary
public:

    this(Mapper mapper=null, VBlankInterruptListener listener=null) {
        this.mapper = mapper;
        vblankInterruptListener = listener;
        frameListeners = make!(typeof(frameListeners))();
    }

    Mapper mapper;
    PPUControl ctrl;
    PPUMask mask;
    PPUStatus status;
    OAMEntry[PRIMARY_OAM_ENTRIES] primaryOAM;
    OAMEntry[SECONDARY_OAM_ENTRIES] secondaryOAM;
    bool sprite0Loaded;
    bool sprite0Active;
    Palette[4] bgPalettes;
    Palette[4] spritePalettes;
    int scanline;
    int cycle;
    uint frameCounter;
    uint tickCounter;
    addr        addrLine;
    ubyte       addrLatch;
    VPtrAddr    vPtr;
    VPtrAddr    vTmpPtr;
    uint        fineX;
    bool        writeToggle;
    ubyte[PPU_INTERNAL_VRAM_SIZE]   internalVRAM;
    SList!FrameListener frameListeners;
    VBlankInterruptListener vblankInterruptListener;

    // Pair of 16-bit shift registers for background pattern table data
    ushort[2] ptrnShiftRegisters;
    // Pair of 8-bit shift registers for background attribute data
    ubyte[2] atbShiftRegisters;
    // Pair of 8-bit latches for filling bg pattern shift registers
    ubyte[2] ptrnLatches;
    // pair of 1-bit latches for filling bg attribute shift registers
    ubyte[2] atbLatches;
    // latch / buffer for holding the next tile read from nametable
    ubyte nametableBufferLatch;
    // latch / buffer for holding the next tile attribute bits
    ubyte attbBufferLatch;

    // Define a type for a _pair_ of 8-bit shift registers
    alias SpritePatternScanlineBuffer = ubyte[2];
    // 8 _pairs_ of 8-bit shift registers for sprite pattern data
    SpritePatternScanlineBuffer[SECONDARY_OAM_ENTRIES] spritePtrnBuffers;
    // 8 latches for sprite attribute data
    OAMAttr[SECONDARY_OAM_ENTRIES] spriteAtbLatches;
    // 8 counters for sprite x positions
    ubyte[SECONDARY_OAM_ENTRIES] spriteXCounters;
    /// Framebuffer representation of NTSC video output
    NtscNesScreen screen;

    // Index counter for sprite evaluation ('N')
    int sprEvalIndexCounter;
    // Offset counter for sprite evaluation ('M')
    int sprEvalOffsetCounter;
    // Destination (secondary OAM) write target
    int sprEvalDestIndex;

    auto addFrameListener(FrameListener listener) {
        return frameListeners.insert(listener);
    }

    auto removeFrameListener(FrameListener listener) {
        return frameListeners.linearRemoveElement(listener);
    }

    /// Read internal VRAM. `offset` is relative / local to the VRAM buffer, and
    /// out-of-bounds addresses will be wrapped automatically.
    ubyte readVRAM(const addr offset) {
        return internalVRAM[offset & PPU_INTERNAL_VRAM_MASK];
    }

    void writeVRAM(const addr offset, const ubyte value) {
        internalVRAM[offset & PPU_INTERNAL_VRAM_MASK] = value;
    }

    /// Read or write from palette entries. `address` is expected to be in the valid
    /// palette or mirrors range ($3F00-$3FFF)
    ubyte readWritePalettes(bool write)(addr address, const ubyte value=0) {
        // Assert the address is in expected range
        assert(address >= PPU_PALETTES_START && address < PPU_PALETTES_MIRRORS_END);
        // only the low 5 bits matter
        address &= 0x1F;
        // low 2 bits indicates index within the palette
        auto entryIdx = address & 0x03;
        // the first entry in every palette (except the first) are actually all mirrors
        // of the first entry in the first palette, which is the universal backdrop color
        //if(entryIdx == 0) {
        //    static if(write) {
        //        debug(verbose) writefln("Writing universal bg color: %02X", (value & 0x0F));
        //        bgPalettes[0][0].packed = (value & 0x3F);
        //        return value;
        //    } else {
        //        return (bgPalettes[0][0].packed & 0x3F);
        //    }
        //}
        // bits 2-3 determine which palette
        auto paletteIdx = (address >> 2) & 0x03;
        // bit 4 determines whether its background or sprite palette, unless
        // the entry index is zero, in which case it is always BG, because sprite palette
        // entry #0 is a mirror of corresponding BG palette entry #0
        auto pal = ((entryIdx == 0 || !(address&0x10)) ? bgPalettes[paletteIdx].ptr : spritePalettes[paletteIdx].ptr);
        static if(write) {
            pal[entryIdx].packed = (value & 0x3F);
            debug(palette) writefln("Writing (%s) palette #%d entry #%d: %02X", (address&0x10) ? "sprite" : "BG", paletteIdx, entryIdx, (value & 0x3F));
            // vestigal return value
            return value;
        } else {
            return (pal[entryIdx].packed & 0x3F);
        }
    }

    @property bool isInVBlank() const {
        return (scanline == 241 && cycle >= 1) ||
            (scanline > 251 && scanline < NTSC_PRERENDER_SCANLINE) ||
            (scanline == NTSC_PRERENDER_SCANLINE && cycle < 1);
    }

    void writePPUCTRL(ubyte value) {
        // Set the nametable select bits in t
        vTmpPtr.nametableSelect = value & 0x03;
        // Rest of the bits go to PPUCTRL (masking out nametable select bits)
        // TODO: Should the nametableSelect bits be masked out? maybe doesn't matter
        //      since PPUCTRL is supposed to be write-only
        auto oldValue = ctrl;
        ctrl.value = value & ~0x03;
        // Setting nmiEnabled during VBlank can trigger an out-of-sync NMI, and
        // or even multiple NMI's during VBlank if the flag is toggled rapidly without
        // reading PPUSTATUS (which resets vblankActive)
        if(!oldValue.nmiEnabled && ctrl.nmiEnabled && status.vblankActive) {
            assert(isInVBlank);
            triggerVBlankNMI();
        }
    }

    ubyte readPPUSTATUS() {
        // Only masked bits from PPUSTATUS are read, the rest are 'open bus', meaning
        // they will be whatever was 'left' in the PPU address bus latch
        ubyte result = status.value & PPUSTATUS_MASK;
        // Set the lower bits to leftover addrLatch -- this may not be necessary,
        // since games _should_ consider these bits garbage anyways, due to decay
        result |= addrLatch & ~PPUSTATUS_MASK;
        // the write toggle latch is reset upon reading PPUSTATUS
        writeToggle = false;
        // The vblank status flag is cleared upon reading
        status.vblankActive = false;
        return result;
    }

    void writePPUMASK(ubyte value) {
        mask.value = value;
    }

    void writePPUSCROLL(ubyte value) {
        if(!writeToggle) {
            // Writing X scroll -- lowest 3 bits goto fineX, highest 5 bits go to coarseX in vTmpPtr (t)
            fineX = (value & 0x07);
            vTmpPtr.coarseX = value >> 3; // the upper 5 bits put into coarseX of vTmpPtr (t)
        } else {
            // Writing Y scroll -- lowest 3 bits goto fineY in vTmpPtr (t), highest 5 bits to coarseY
            vTmpPtr.fineY = (value & 0x07);
            vTmpPtr.coarseY = value >> 3; // upper 5 bits shifted down
        }
        // Flip the write toggle latch
        writeToggle = !writeToggle;
    }

    void writePPUADDR(ubyte value) {
        if(!writeToggle) {
            // Reset the upper 8 (7) bits of vTmpPtr (t),
            vTmpPtr.raw &= 0x00FF;
            // set the lower 6 bits of the high byte to the given value
            // Actual register is only 15 bits wide, and bit 14 is cleared when writing
            // to PPUADDR directly
            vTmpPtr.raw |= (value << 8) & 0x3F00;
        } else {
            // Reset the lower 8 bits of vTmpPtr (t), preserving the upper 7 bits
            vTmpPtr.raw &= 0x7F00;
            vTmpPtr.raw |= value;
            // Upon 'completing' (2x writes) the write to PPUDATA, the contents
            // of t (vTmpPtr) is copied into v (vPtr)
            vPtr.raw = vTmpPtr.raw;
        }
        // Flip the write toggle latch
        writeToggle = !writeToggle;
    }

    void writePPUDATA(ubyte value) {
        addr target = vPtr.raw & PPU_ADDR_MASK;
        debug(ppudata) writefln("[PPU] Writing ($%02X) to PPUDATA @ $%04X", value, target);
        writeBus(target, value);
        incrementPPUADDR();
    }

    ubyte readPPUDATA() {
        ubyte result = readBus(vPtr.raw & PPU_ADDR_MASK);
        incrementPPUADDR();
        return result;
    }

    void incrementPPUADDR() {
        if(ctrl.vramAddrInc == 0) {
            // increment 'horizontally' by adding 1
            vPtr.raw = (vPtr.raw+1) & PPU_ADDR_REGISTER_MASK;
        } else {
            // increment 'vertically' by adding 32
            vPtr.raw = (vPtr.raw+32) & PPU_ADDR_REGISTER_MASK;
        }
    }

    @property bool isRenderingEnabled() const {
        return mask.bgEnabled || mask.spritesEnabled;
    }

    ubyte getFineXScroll() const {
        return fineX & 0x07;
    }

    ubyte calcCurrentBgPixel() {
        const ubyte fineX = getFineXScroll();
        // Result is only 4 bits -- 0000AAPP, where AA = 2-bit palette index,
        //  PP = 2-bit index into the palette.
        // If the pattern bits (PP) are 0, then attribute bits (AA) are ignored,
        // and the color will always be that of the backdrop at $3F00
        return ((getBit(atbShiftRegisters[1], fineX) << 3) +
            (getBit(atbShiftRegisters[0], fineX) << 2) +
            (getBit(ptrnShiftRegisters[1], fineX) << 1) +
            getBit(ptrnShiftRegisters[0], fineX)) & 0x0F;
    }

    ubyte calcCurrentSpritePixel() {
        for(auto i = 0; i < SECONDARY_OAM_ENTRIES; i++) {
            // Only if a sprite's X counter is 0 is it 'active', so skip ahead
            // if current sprite is inactive
            if(spriteXCounters[i] > 0)
                continue;
            // Calculate the pixel color for the sprite
            ubyte pixel =
                ((spriteAtbLatches[i].palette << 2) +
                (getBit(spritePtrnBuffers[i][1], 0) << 1) +
                getBit(spritePtrnBuffers[i][0], 0)) & 0x0F;
            // If the pattern bits are 0, the pixel is transparent, so skip to next
            if((pixel & 0x03) == 0)
                continue;
            // stuff the 'priority' bit into bit 5 of the result, for proper muxing
            // with the background pixel if any. it will be masked out / ignored
            // when looking up palette color.
            pixel |= (spriteAtbLatches[i].priority << 4);

            // If sprite 0 is 'in play' (selected and present in secondary OAM),
            // AND this is iteration 0 (first secondary OAM entry)
            // AND the sprite pixel is opaque, this MAY be a sprite 0 hit. We can
            // use the 6th bit of the result to indicate this, since the final condition
            // (overlap with an opaque pixel of the background) can't be evaluated here
            // (It is expected that the caller will evaluate this though).
            pixel |= (i == 0 && sprite0Active ? 1 : 0) << 5;

            // Short-circuit / early exit evaluating remaining secondary OAM for sprites
            return pixel;
        }
        // No sprites at the current raster position
        return 0;
    }

    void renderPixel() {
        assert(scanline >= 0 && scanline < NTSC_SCREEN_H && cycle >= 1 && cycle <= NTSC_SCREEN_W, "Pixel out of bounds");

        ubyte bgPixel = (mask.bgEnabled ? calcCurrentBgPixel() : 0);
        ubyte spritePixel = (mask.spritesEnabled ? calcCurrentSpritePixel() : 0);
        bool bgPresent = (bgPixel & 0x03) != 0;
        bool spritePresent = (spritePixel & 0x03) != 0;
        uint bgPalette = (bgPixel >> 2) & 0x03;
        uint spritePalette = (spritePixel >> 2) & 0x03;
        // The default output color if neither bg nor sprite is present/enabled is the
        // backdrop color
        PaletteEntry result = bgPalettes[0][0];

        if(bgPresent && !spritePresent) {
            // Only the background pixel is opaque, no conflict
            result = bgPalettes[bgPalette][bgPixel & 0x03];
        } else if(!bgPresent && spritePresent) {
            // Only sprite pixel is opaque, no conflict
            result = spritePalettes[spritePalette][spritePixel & 0x03];
        } else if(bgPresent && spritePresent) {
            // Both bg and sprite pixels are opaque, sprite priority determines
            // which pixel is rendered (0/false = sprite shown, 1/true = background dhown)
            bool spritePriority = (spritePixel & 0x10) > 0;
            result = (spritePriority ? bgPalettes[bgPalette][bgPixel & 0x03] : spritePalettes[spritePalette][spritePixel & 0x03]);

            // regardless of priority, if this is sprite 0 AND cycle >= 3,
            // this triggers the sprite0 hit flag
            if(sprite0Active && (spritePixel & 0x20) > 0 && cycle >= 3)
                status.sprite0Hit = true;
        }

        debug(render_diagnostic) {
            debug writefln("PPU Status:\tFrame: %d\tCycle: %d\tScanline: %d\tTick: %d\tBGColor: %02X\tPalettes: %s\tvPtr: %04X", frameCounter, cycle, scanline, tickCounter, bgPalettes[0][0].packed, bgPalettes, vPtr.raw);
            debug writefln("Setting pixel (%d,%d) to %02X (bgPixel: %02X, sprPixel: %02X)", cycle-1, scanline, result.packed, bgPixel, spritePixel);
        }

        // Render the pixel to screen
        screen[scanline][cycle-1] = (result.packed & 0x3F);
    }

    void oamTick() {
        // Unless rendering is enabled (even if sprites are disabled), all of this is skipped
        assert(isRenderingEnabled);

        // Sprite evaluation only occurs during visible scanlines
        if(scanline >= 0 && scanline < NTSC_SCREEN_H) {
            if(cycle == 0) {
                // do nothing / idle tick
            } else if (cycle >= 1 && cycle <= 64 && (cycle & 1) == 0) {
                // Clear OAM memory by overwriting with 0xFF (only on EVEN ticks)
                // (Cheating -- read happens on ODD ticks, write happens on EVEN ticks,
                // its actually reading from primary OAM but a flag forces the read value to always
                // be 0xFF)
                ubyte* target = cast(ubyte*)&secondaryOAM[0];
                target[(cycle >> 1)-1] = 0xFF;
            } else if(cycle >= 65 && cycle <= 256) {
                // Reset the counters on the first cycle of this phase
                if(cycle == 65) {
                    sprEvalIndexCounter = sprEvalOffsetCounter = sprEvalDestIndex = 0;
                    // Initialize the sprite0 'active' flag to the 'loaded'/'in-range' flag
                    sprite0Active = sprite0Loaded;
                    // Clear the sprite0 loaded flag
                    sprite0Loaded = false;
                }
                // Continue only while primary OAM index isn't exhausted
                if(sprEvalIndexCounter < primaryOAM.length) {
                    if(sprEvalDestIndex < secondaryOAM.length) {
                        // sprite evaluation
                        spriteEvaluationTick();
                    } else {
                        // sprite overflow evaluation
                        spriteEvaluationOverflowTick();
                    }
                }
            } else if(cycle > 256 && cycle <= 320) {
                // During cycles 257-320, sprite shift registers / latches
                // are populated from secondaryOAM with results of sprite evaluation
                spriteBufferPopulateTick();
            }
        }
    }

    void loadSpritePatternBuffer(uint sprIndex, bool high) {
        assert(sprIndex >= 0 && sprIndex < secondaryOAM.length);
        assert(scanline >= 0 && scanline < NTSC_SCREEN_H);
        assert(cycle > 256 && cycle <= 320);
        assert(isRenderingEnabled);

        OAMEntry* sprite = secondaryOAM.ptr + sprIndex;
        auto spriteHeight = (ctrl.useLargeSprites ? 16 : 8);
        auto localY = scanline - sprite.y;

        if(localY >= 0 && localY < spriteHeight) {
            // If the sprite is flipped vertically, invert the local offset
            if(sprite.attrib.flipVertical)
                localY = spriteHeight - localY;
            ubyte tileNo, bank;
            if(ctrl.useLargeSprites) {
                // If using large sprites, the (global) sprite pattern table
                // configured PPUCTRL is ignored, and instead the low-bit of the
                // second byte is used to select a pattern table. Because large
                // sprites are just 2x 8x8 sprites stacked vertically, and because
                // the second sprite must follow the first in the pattern table,
                // large sprites must always use even tile numbers (the following odd
                // number is the second tile).
                tileNo = ub(localY < 8 ? sprite.tileIndex : sprite.tileIndex+1);
                bank = sprite.bankIndex & 1;
            } else {
                tileNo = sprite.tileSelector;
                bank = ctrl.smallSpritePtrnTbl & 1;
            }

            spritePtrnBuffers[sprIndex][high] = readPatternTileByte(tileNo, bank, ub(localY), false);
            if(sprite.attrib.flipHorizontal)
                spritePtrnBuffers[sprIndex][high] = reverseBits(spritePtrnBuffers[sprIndex][high]);
        } else {
            // TODO: Verify this means what remains of secondaryOAM is all 0xFF
            // (from previous clear, only first byte / Y of first unused secondaryOAM entry
            // will have a Y value in it, but it won't be in range)
            //assert(sprite.values[1..$] == [0xFF, 0xFF, 0xFF]);
            // Clear associated sprite pattern buffers
            spritePtrnBuffers[sprIndex][high] = 0;
        }
    }

    void spriteEvaluationTick() {
        // Assert that this method is only called when secondaryOAM isnt' full yet
        assert(sprEvalDestIndex < secondaryOAM.length);
        const OAMEntry* entry = primaryOAM.ptr+sprEvalIndexCounter;
        // Copy the Y value from primary -> secondary OAM
        ubyte y = entry.y;
        secondaryOAM[sprEvalDestIndex].y = y;
        ubyte spriteEndY = (y + (ctrl.useLargeSprites ? 16 : 8)) & 0xFF;
        // If the Y coordinate is in range for rendering, copy remaining bytes
        if(scanline >= y && scanline < spriteEndY) {
            // Sprite is in range, copy remaining OAM bytes
            secondaryOAM[sprEvalDestIndex].tileSelector = entry.tileSelector;
            secondaryOAM[sprEvalDestIndex].attrib = entry.attrib;
            secondaryOAM[sprEvalDestIndex].x = entry.x;
            // If this was sprite 0, set the sprite0 active flag
            if(sprEvalIndexCounter == 0) {
                sprite0Loaded = true;
                // Verify our assumption that sprite0 will always end up in first slot
                assert(sprEvalDestIndex == 0);
            }
            // Increment the secondary OAM index counter
            ++sprEvalDestIndex;
        }
        // Increment the primaryOAM index counter
        ++sprEvalIndexCounter;
    }

    void spriteEvaluationOverflowTick() {
        // Assert this method is only called when secondary OAM is full
        assert(sprEvalDestIndex >= secondaryOAM.length);
        // Emulate sprite overflow bug that erronously sometimes doesn't use Y values
        ubyte y = primaryOAM[sprEvalIndexCounter].values[sprEvalOffsetCounter];
        ubyte spriteEndY = (y + (ctrl.useLargeSprites ? 16 : 8)) & 0xFF;
        if(scanline >= y && scanline < spriteEndY) {
            // Sprite in range, but secondaryOAM is full so trigger the sprite overflow flag
            status.spriteOverflow = true;
            // Skip actually reading next 3 OAM bytes, but simulate incrementing offset 3 times
            sprEvalOffsetCounter += 3;
            // Offset wraps to index
            sprEvalIndexCounter += 1 + (sprEvalOffsetCounter >> 2);
            sprEvalOffsetCounter &= 0x03;
        } else {
            // Sprite not in range -- erroneously increment both index and offset ('without carry')
            sprEvalIndexCounter++;
            sprEvalOffsetCounter = (sprEvalOffsetCounter+1) & 0x03;
        }
    }

    void spriteBufferPopulateTick() {
        // Assert this is only called during the first part of HBlank, when sprite rendering buffers / latches
        // should be getting initialized / populated for the next scanline
        assert(cycle > 256 && cycle <= 320);

        // During the beginning part of HBlank, the same circuitry
        // that fetches background pattern tiles is used to populate
        // sprite pattern buffers for the upcoming scanline
        // Over the course of 8x8 (=64) cycles, the first 4 cycles
        // are spent doing a garbage nametable/attb fetch, the
        // following 2 fetch sprite pattern tile lsbits, last 2
        // fetch msbits
        // Secondary OAM index to operate on (bits 3-5 of cycle)
        auto sprIndex = (cycle >> 3) & 7;
        // local alias to target secondary OAM entry
        OAMEntry *sprite = secondaryOAM.ptr + sprIndex;
        auto subCycle = cycle & 7;
        if(subCycle == 3) {
            // During the first tick of the second 'garbage nametable fetch'
            // the sprite attribute latch is loaded
            spriteAtbLatches[sprIndex] = sprite.attrib;
        } else if(subCycle == 4) {
            // During the second tick of the second garbage NT fetch,
            // the sprite X counter is loaded
            spriteXCounters[sprIndex] = sprite.x;
        } else if(subCycle == 6) {
            // (Cheating 2-cycle load) on 6th tick, pattern low bits are
            // populated
            loadSpritePatternBuffer(sprIndex, false);
        } else if(subCycle == 0) {
            // (Cheating 2-cycle load) on the 8th tick, pattern high bits are
            // populated
            loadSpritePatternBuffer(sprIndex, true);
        }
    }

    void bgRenderTick() {
        // Unless rendering is enabled (even if background is disabled), all of this is skipped.
        if(!isRenderingEnabled)
            return;

        bool isVisibleScanline = (scanline >= 0 && scanline < NTSC_SCREEN_H);
        bool isPreRenderScanline = (scanline == NTSC_PRERENDER_SCANLINE);

        if(isVisibleScanline || isPreRenderScanline) {
            // On cycles of visible pixels AND during the last ~20 cycles of HBlank
            if((cycle > 0 && cycle <= 256) || (cycle >= 320)) {
                // Mask all but lowest 3 bits
                auto subCycle = cycle & 7;
                if(subCycle == 1) {
                    // On every 8th+1 cycle, shift registers are updated with contents of buffers / latches
                    updateBgShiftRegisters();
                } else if(subCycle == 2) {
                    // On every 8th+2 cycle, nametable is fetched
                    nametableBufferLatch = readBus(getCurrentTileAddr());
                } else if(subCycle == 4) {
                    // On every 8th+4 cycle, attribute is fetched
                    attbBufferLatch = readBus(getCurrentAttrAddr());
                } else if(subCycle == 6) {
                    // On every 8th+6 cycle, the low byte of the pattern is fetched
                    // Not found in documentation anywhere -- but I suspect the bits
                    // are supposed to be flipped; given that the shift registers shift right,
                    // but render left to right
                    ptrnLatches[0] = reverseBits(readPatternTileByte(nametableBufferLatch, ub(ctrl.bgPtrnTbl), ub(vPtr.fineY), false));
                } else if(subCycle == 0) {
                    // On every 8th cycle, bg high bits pattern latch is updated, before advancing vPtr horizontally
                    ptrnLatches[1] = reverseBits(readPatternTileByte(nametableBufferLatch, ub(ctrl.bgPtrnTbl), ub(vPtr.fineY), true));
                    vPtr.incrementCoarseX();
                }
            }

            // On cycle 256, the vertical position is incremented
            if(cycle == 256)
                vPtr.incrementY();
            else if(cycle == 257) {
                // On cycle 257, the horizontal position is reset
                vPtr.syncHorizontal(vTmpPtr);
            }
        }

        // Only on the pre-render scanline, during cycles [280,304],
        // vertical position is reset each tick
        if(isPreRenderScanline && cycle >= 280 && cycle <= 304) {
            // During cycles [280,304], vertical position is reset (every cycle)
            vPtr.syncVertical(vTmpPtr);
        }
    }

    void updateFlagsTick() {
        if(scanline == NTSC_PRERENDER_SCANLINE) {
            // On cycle 1 of the pre-render scanline, PPUSTATUS flags are cleared
            if(cycle == 1) {
                status.vblankActive = false;
                status.spriteOverflow = false;
                status.sprite0Hit = false;
            }
        }
    }

    void checkForVBlank() {
        // On the scanline _after_ the first post-render scanline, on second cycle (cycle 1), vblank begins
        if(scanline == 241) {
            if(cycle == 1) {
                // Set the PPUSTATUS.vblankActive flag
                status.vblankActive = true;
                triggerVBlankNMI();

                // Trigger the general purpose frame listeners
                triggerFrameListeners();
            }
        }
    }

    void triggerFrameListeners() {
        // General purpose listeners are called regardless
        foreach(listener; frameListeners) {
            listener(this, screen);
        }
    }

    void doTick() {
        // Only if rendering is enabled do background tile fetch and sprite evaluation occur
        if(isRenderingEnabled) {
            bgRenderTick();
            oamTick();
        }
        // Conditionally trigger clearing of status flags (vblank, sprite0Hit, sprite overflow)
        updateFlagsTick();
        // Conditionally trigger vblank flag & NMI
        checkForVBlank();
        // If raster is in a visible position, render a pixel
        if(scanline >= 0 && scanline < NTSC_SCREEN_H && cycle >= 1 && cycle <= NTSC_SCREEN_W) {
            // A pixel is drawn even if rendering is off (in which case it simply
            // draws the universal backdrop color)
            renderPixel();
            // TODO: Should these be done even if rendering is disabled?
            shiftBgPatternRegisters();
            updateSpriteShiftRegisters();
        }
        // Finally, advance the raster position
        advanceRasterPosition();
        // increment tick counter
        ++tickCounter;
    }

    void advanceRasterPosition() {
        // Advance the scanline / cycle / frame counters
        ++cycle;
        // The pre-render scanline is variable length --
        // When rendering is enabled, on odd frames, the last cycle is 'skipped'
        // (replacing the idle cycle by jumping directly from (339,261) to (0,0)).
        // On even frames, the scanline is the normal 341 cycles.
        if(scanline >= NTSC_PRERENDER_SCANLINE &&
            cycle >= NTSC_SCANLINE_CYCLES-1 &&
            (frameCounter & 1) &&
            isRenderingEnabled) {
            // Skip the last cycle (and go directly to (0,0) after subsequent wrapping
            // logic)
            ++cycle;
        }
        if(cycle >= NTSC_SCANLINE_CYCLES) {
            // Wrap cycle to next scanline
            cycle = 0;
            ++scanline;

            // If scanline has reached the end, wrap scanline to next frame
            if(scanline >= NTSC_SCANLINES) {
                scanline = 0;
                ++frameCounter;
            }
        }
    }

    @("advanceRasterPosition")
    unittest {
        // test normal rollover (even frame)
        auto ppu = new PPU(null);
        // Set raster position to 2 cycles before rollover
        ppu.cycle = 339;
        ppu.scanline = 261;
        ppu.advanceRasterPosition();
        // Verify we advanced to last cycle before rollover
        assert(ppu.cycle == 340 && ppu.scanline == 261 && ppu.frameCounter == 0);
        ppu.advanceRasterPosition();
        // Verify we rolled over
        assert(ppu.cycle == 0 && ppu.scanline == 0 && ppu.frameCounter == 1);

        // test odd frame rollover, with rendering disabled
        // Set raster position to 2 cycles prior to (normal) rollover
        ppu.cycle = 338;
        ppu.scanline = 261;
        // Assert rendering is disabled, and we're on an odd frame
        assert(!ppu.isRenderingEnabled);
        assert(ppu.frameCounter & 1);
        ppu.advanceRasterPosition();
        assert(ppu.cycle == 339 && ppu.scanline == 261 && ppu.frameCounter == 1);
        ppu.advanceRasterPosition();
        assert(ppu.cycle == 340 && ppu.scanline == 261 && ppu.frameCounter == 1);
        ppu.advanceRasterPosition();
        assert(ppu.cycle == 0 && ppu.scanline == 0 && ppu.frameCounter == 2);

        // test even frame rollover, with rendering enabled
        ppu = new PPU();
        ppu.mask.spritesEnabled = true;
        ppu.cycle = 338;
        ppu.scanline = 261;
        ppu.frameCounter = 0;
        assert(ppu.isRenderingEnabled);
        ppu.advanceRasterPosition();
        assert(ppu.cycle == 339 && ppu.scanline == 261 && ppu.frameCounter == 0);
        ppu.advanceRasterPosition();
        assert(ppu.cycle == 340 && ppu.scanline == 261 && ppu.frameCounter == 0);
        ppu.advanceRasterPosition();
        assert(ppu.cycle == 0 && ppu.scanline == 0 && ppu.frameCounter == 1);

        // test odd frame rollover, with rendering enabled
        // when rendering is enabled on odd frames, the last cycle
        // of the last scanline (e.g. pre-render scanline) is
        // 'merged' into the first cycle of the first scanline of the
        // new frame
        ppu = new PPU();
        ppu.mask.spritesEnabled = true;
        ppu.cycle = 338;
        ppu.scanline = 261;
        ppu.frameCounter = 1;
        assert(ppu.isRenderingEnabled);
        ppu.advanceRasterPosition();
        // Assert we approach the wrap point, cycle 339 is executed
        assert(ppu.cycle == 339 && ppu.scanline == 261 && ppu.frameCounter == 1);
        // Advance one more
        ppu.advanceRasterPosition();
        // Assert cycle 340 was skipped, and we jumped directly to (0,0) of next frame
        assert(ppu.cycle == 0 && ppu.scanline == 0 && ppu.frameCounter == 2);
    }

    void triggerVBlankNMI() {
        // the vblankInterruptListener is only triggered if _both_ ctrl.nmiEnabled
        // and status.nmiEnabled are set
        if(status.vblankActive && ctrl.nmiEnabled) {
            assert(isInVBlank);
            if(vblankInterruptListener)
                vblankInterruptListener(this);
        }
    }

    void shiftBgPatternRegisters() {
        // Shift the bg pattern / attribute shift registers once
        ptrnShiftRegisters[1] >>= 1;
        ptrnShiftRegisters[0] >>= 1;

        atbShiftRegisters[1] >>= 1;
        atbShiftRegisters[0] >>= 1;
    }

    void updateBgShiftRegisters() {
        // Copy the contents of the pattern table buffer latches to the upper 8 bits of the
        // pattern shift registers
        ptrnShiftRegisters[1] = ((ptrnLatches[1] << 8) & 0xFF00) | (ptrnShiftRegisters[1]&0xFF);
        ptrnShiftRegisters[0] = ((ptrnLatches[0] << 8) & 0xFF00) | (ptrnShiftRegisters[0]&0xFF);
        // likewise copy the contents of the attribute buffer latch bits into the 1-bit feeder latches
        atbLatches[1] = (attbBufferLatch >> 1) & 0x01;
        atbLatches[0] = (attbBufferLatch & 0x01);
    }

    void updateSpriteShiftRegisters() {
        for(int i = 0; i < SECONDARY_OAM_ENTRIES; i++) {
            // Active sprites have their pattern shift registers shifted once
            // Do this before decrementing X position, otherwise the first pixel
            // would be shifted out immediately
            if(spriteXCounters[i] == 0) {
                spritePtrnBuffers[i][0] >>= 1;
                spritePtrnBuffers[i][1] >>= 1;
            }

            // Decrement x counters
            if(spriteXCounters[i] > 0)
                --spriteXCounters[i];
        }
    }

    addr getCurrentTileAddr() {
        // upper 4(2)  bits of vPtr address are fixed to 0x2000, vPtr is masked to lower
        // 12 bits (= 14 bit address into CHR nametable)
        return PPU_NAMETABLE_OFFSETS[0] | (vPtr.raw & 0x0FFF);
    }

    addr getCurrentAttrAddr() {
        // upper 3 bits of vPtr address are fixed to 0x2000, add 960 byte offset (=0x23C0)
        // for the attribute table that follows a nametable,
        // nametable select bits at 15-14, and high 3 bits each of coarseX and coarseY
        return PPU_ATTR_TABLE_OFFSET | (vPtr.raw & 0x0C00) | ((vPtr.raw >> 4) & 0x38) | ((vPtr.raw >> 2) & 0x07);
    }

    ubyte readPatternTileByte(ubyte tileNo, ubyte table, ubyte fineY, bool highByte) {
        /* Pattern table addresses:
            DCBA98 76543210
            ---------------
            0HRRRR CCCCPTTT
            |||||| |||||+++- T: Fine Y offset, the row number within a tile
            |||||| ||||+---- P: Bit plane (0: "lower"; 1: "upper")
            |||||| ++++----- C: Tile column
            ||++++---------- R: Tile row
            |+-------------- H: Half of pattern table (0: "left"; 1: "right")
            +--------------- 0: Pattern table is at $0000-$1FFF
         */
        addr target = (fineY & 0x07);
        if(highByte)
            target |= 0x08;
        target |= (tileNo << 4) & 0x0FF0;
        target |= (table << 12) & 0x1000;
        return readBus(target);
    }

    ubyte readBus(in addr address) {
        //return bus.read(address);
        assert(mapper !is null);
        return mapper.readPPU(address);
    }

    void writeBus(in addr address, in ubyte value) {
        //bus.write(address, value);
        assert(mapper !is null);
        mapper.writePPU(address, value);
    }
}

@("PPU tick counter")
unittest {
    import std.stdio;
    import std.range;
    import std.algorithm.comparison;
    auto ppu = new PPU();
    const ubyte C = 0x03;
    ppu.bgPalettes[0][0].packed = C;
    with(ppu) assert(cycle == 0 && scanline == 0 && tickCounter == 0);
    // The first cycle is an idle cycle, so no pixel is rendered, and this
    // loop must be range+1
    foreach(i; 0 .. 101) {
        ppu.doTick();
        assert(ppu.tickCounter == i+1);
    }
    assert(ppu.screen.length == NTSC_SCREEN_H);
    assert(ppu.screen[0].length == NTSC_SCREEN_W);
    //writefln("Pixels: %s", ppu.screen[0]);
    assert(C.repeat(100).equal(ppu.screen[0][0 .. 100]));
}

@("Frame counter & listeners")
unittest {
    auto ppu = new PPU();
    // Set a non-default backdrop color (superfluous)
    const ubyte C = 0x1A;
    ppu.bgPalettes[0][0].packed = C;
    // Ensure we're starting at 0
    assert(ppu.frameCounter == 0);
    assert(ppu.tickCounter == 0);
    // Add a frame listener
    int listenerFrames = 0;
    auto listener = (const PPU ppu, const NtscNesScreen screen) {
        ++listenerFrames;
    };
    ppu.addFrameListener(listener);
    // Run ~N frames worth of ticks
    immutable int N = 3;
    foreach(i; 0..(N*PPU_CYCLES_PER_FRAME)) {
        ppu.doTick();
        assert(ppu.tickCounter == i+1);
    }
    // Assert N frames have elapsed
    assert(ppu.frameCounter == N);
    // Assert the FrameListener got called N times
    assert(listenerFrames == N);
}

@("Palettes")
unittest {
    auto ppu = new PPU();
    ubyte V = 0x1D;
    // assert that after writing to 0x3F00, all its mirrors return the same value
    ppu.readWritePalettes!true(0x3F00, V);
    addr[] mirrors = [0x3F00, 0x3F10, 0x3F20, 0x3FF0];
    foreach(a; mirrors) {
        assert(ppu.readWritePalettes!false(a) == V);
    }

    // Assert that writing to one of the mirrors also changes the value across all of them
    V = 0x2F;
    ppu.readWritePalettes!true(0x3F10, V);
    foreach(a; mirrors) {
        assert(ppu.readWritePalettes!false(a) == V);
    }

    // TODO: Unit test other palette entries
}