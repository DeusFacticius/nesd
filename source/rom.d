module rom;

// NES rom file format utilities

import std.bitmanip;
import std.stdio;

immutable char[] MAGIC = "NES\x1A";
immutable uint PRG_ROM_PAGE_SIZE = 16 * 1024;   // 16 KiB
immutable uint CHR_ROM_PAGE_SIZE = 8 * 1024;    // 8 KiB
immutable uint TRAINER_SIZE = 512;

immutable uint MIRROR_MODE_HORIZONTAL = 0;
immutable uint MIRROR_MODE_VERTICAL = 1;

struct NESFileHeader {
    char[4] magic;
    ubyte numPrgRomPages;
    ubyte numChrRomPages;
    union {
        ubyte flags6;
        struct {
            mixin(bitfields!(
                uint, "mirrorMode", 1,
                bool, "isBatteryPresent", 1,
                bool, "isTrainerPresent", 1,
                bool, "isFourScreenMode", 1,
                uint, "lowerMapperNibble", 4
            ));
        }
    }
    union {
        ubyte flags7;
        struct {
            mixin(bitfields!(
                bool, "isVSUnisystem", 1,
                bool, "isPlayChoice10", 1,
                uint, "formatVersion", 2,
                uint, "upperMapperNibble", 4
            ));
        }
    }
    ubyte prgRAMSize;
    union {
        ubyte flags9;
        struct {
            mixin(bitfields!(
                bool, "isPAL", 1,
                uint, "reserved9", 7
            ));
        }
    }
    ubyte flags10;
    ubyte[5] unused;
}
static assert(NESFileHeader.sizeof == 16);

class NESFile {
public:
    this(const string filename) {
        read(filename);
    }

    @property ref const(NESFileHeader) header() const {
        return _header;
    }

    @property ref const(ubyte[]) trainer() {
        return _trainer;
    }

    @property ref const(ubyte[][]) prgRomBanks() {
        return _prgRomBanks;
    }

    @property ref const(ubyte[][]) chrRomBanks() {
        return _chrRomBanks;
    }

    @property uint mapperId() const {
        return ((_header.upperMapperNibble << 4) + _header.lowerMapperNibble) & 0xFF;
    }

private:
    NESFileHeader _header;
    ubyte[][] _prgRomBanks;
    ubyte[][] _chrRomBanks;
    ubyte[] _trainer;

    void read(const string filename) {
        auto f = File(filename, "rb");
        auto headerBytes = f.rawRead(new ubyte[NESFileHeader.sizeof]);
        // copy/blit the byte array into the structure
        _header = *cast(NESFileHeader*)(headerBytes.ptr);

        //this.prgRomBanks = new ubyte[_header.numPrgRomPages][PRG_ROM_PAGE_SIZE];
        //this.chrRomBanks = new ubyte[_header.numChrRomPages][CHR_ROM_PAGE_SIZE];
        //prgRomBanks.length = _header.numPrgRomPages;
        //chrRomBanks.length = _header.numChrRomPages;
        _prgRomBanks = new ubyte[][](_header.numPrgRomPages, PRG_ROM_PAGE_SIZE);
        _chrRomBanks = new ubyte[][](_header.numChrRomPages, CHR_ROM_PAGE_SIZE);

        if(_header.isTrainerPresent) {
            _trainer = new ubyte[TRAINER_SIZE];
            f.rawRead(_trainer);
        }

        for(auto i = 0; i < _prgRomBanks.length; i++) {
            f.rawRead(_prgRomBanks[i]);
        }
        for(auto i = 0; i < _chrRomBanks.length; i++) {
            f.rawRead(_chrRomBanks[i]);
        }
    }

    @("smb.nes")
    unittest {
        debug(verbose) writeln("Reading smb.nes ...");
        auto cart = new NESFile("smb.nes");
        assert(cart.header.magic == MAGIC);
        debug(verbose) writefln("Num prg rom pages: %d\tChr: %d", cart.header.numPrgRomPages, cart.header.numChrRomPages);
        assert(cart.header.numPrgRomPages == 2);
        assert(cart.header.numChrRomPages == 1);
        debug(verbose) writefln("PRG rom banks: %d", cart.prgRomBanks.length);
        assert(cart.prgRomBanks.length == 2);
        assert(cart.prgRomBanks[0].length == PRG_ROM_PAGE_SIZE);
        assert(cart.prgRomBanks[1].length == PRG_ROM_PAGE_SIZE);
        debug(verbose) writefln("Trainer present: %s", cart.header.isTrainerPresent);
        assert(cart.trainer == null);
        immutable PRG1SUM = "9820f4a424413fcf186632e2b62719a2";
        import std.digest.md;
        auto sum = md5Of(cart.prgRomBanks[0]).toHexString!(LetterCase.lower)();
        debug(verbose) writefln("PRG1 digest: %s", sum);
        assert(sum == PRG1SUM);
        immutable PRG2SUM = "0ec64c4a6a59f97d2f7b9d03e19ae857";
        sum = md5Of(cart.prgRomBanks[1]).toHexString!(LetterCase.lower)();
        debug(verbose) writefln("PRG2 digest: %s", sum);
        assert(sum == PRG2SUM);
        immutable CHR1SUM = "7bbce748f81502207b5a3b87e4d3e856";
        sum = md5Of(cart.chrRomBanks[0]).toHexString!(LetterCase.lower)();
        debug(verbose) writefln("CHR1 digest: %s", sum);
        assert(sum == CHR1SUM);
        assert(cart.mapperId == 0);
    }
}