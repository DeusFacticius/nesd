module cpu;

import std.bitmanip;
import std.stdio;
import std.format;
import std.algorithm;
import std.range;
import std.traits;
import std.string;
import std.typecons;
import core.thread.fiber;
import util;
import bus;

// NES has 2KiB of internal RAM starting at 0x0000, ending at 0x07FF
// However, that same 2KiB of RAM is mirrored in the address space 3x,
// so ex. the addresses 0x0000, 0x0800, 0x1000, and 0x1800 all actually map to
// the same byte in RAM (0x0000).
immutable addr CPU_STACK_ADDR       = 0x0100;
immutable addr CPU_RAM_SIZE         = 0x0800;
immutable addr CPU_RAM_START        = 0x0000;
immutable addr CPU_RAM_END          = 0x07FF;
immutable addr CPU_RAM_MASK         = 0x07FF;
immutable addr CPU_RAM_MIRRORS_END  = 0x1FFF;
immutable addr CPU_BRK_VECTOR       = 0xFFFE;
immutable addr CPU_IRQ_VECTOR       = CPU_BRK_VECTOR; // IRQ vector is same as BRK vector
immutable addr CPU_NMI_VECTOR       = 0xFFFA;
immutable addr CPU_RESET_VECTOR     = 0xFFFC;
immutable addr CPU_CARTRIDGE_SPACE_START    = 0x4020;
immutable addr CPU_CARTRIDGE_SPACE_END      = 0xFFFF;

immutable addr OAMDMA_ADDRESS       = 0x4014;

union ProcessorStatus {
    ubyte P = Flags.RESERVED;
    mixin(bitfields!(
        bool, "C", 1,   // Carry flag
        bool, "Z", 1,   // Zero flag
        bool, "I", 1,   // Interrupt disable flag
        bool, "D", 1,   // Decimal flag
        bool, "B", 1,   // 'break' flag
        bool, "R", 1,   // reserved / dummy, always 1 (?)
        bool, "V", 1,   // oVerflow flag
        bool, "N", 1,   // Negative flag
    ));
    alias P this;

    string toString() {
        return format("%c%c%c%c%c%c%c%c", N ? 'N' : 'n', V ? 'V' : 'v', B ? 'B' : 'b', R ? 'R' : 'r', D ? 'D' : 'd', I ? 'I' : 'i', Z ? 'Z' : 'z', C ? 'C' : 'c');
    }

    enum Flags : ubyte {
        CARRY = 0x01,
        ZERO = 0x02,
        INTERRUPT_DISABLE = 0x04,
        DECIMAL = 0x08,
        BREAK = 0x10,
        RESERVED = 0x20,
        OVERFLOW = 0x40,
        NEGATIVE = 0x80
    }
    static assert(isBitFlagEnum!Flags);

    void setNZ(ubyte result) {
        Z = (result == 0);
        N = (result & 0x80) > 0;
    }
}
static assert(ProcessorStatus.sizeof == ubyte.sizeof);

unittest {
    ProcessorStatus p = ProcessorStatus(0xAA);
    assert(p.N && p.R && p.D && p.Z);
    assert(!(p.V || p.B || p.I || p.C));
}

enum AddressMode {
    IMPLIED,
    ACCUMULATOR,
    IMMEDIATE,
    RELATIVE,           // used by branch instructions
    ZP_IMMEDIATE,
    ZP_X,
    ZP_Y,
    ABSOLUTE,
    ABSOLUTE_X,
    ABSOLUTE_Y,
    INDEXED_INDIRECT,   // (d,x)
    INDIRECT_INDEXED,   // (d),y
    INDIRECT,           // Only used by JMP (addr)
}

pure ubyte getOpcodeSize(immutable AddressMode mode) {
    final switch(mode) {
        // The following are self contained, no operand necessary
        case AddressMode.IMPLIED:
        case AddressMode.ACCUMULATOR:
            return 1;
        // The following include a single byte operand / offset with the opode
        case AddressMode.IMMEDIATE:
        case AddressMode.RELATIVE:
        case AddressMode.ZP_IMMEDIATE:
        case AddressMode.ZP_X:
        case AddressMode.ZP_Y:
        case AddressMode.INDEXED_INDIRECT:
        case AddressMode.INDIRECT_INDEXED:
            return 2;
        // The following include a full 16-bit address inline with the opcode
        case AddressMode.ABSOLUTE:
        case AddressMode.ABSOLUTE_X:
        case AddressMode.ABSOLUTE_Y:
        case AddressMode.INDIRECT:
            return 3;
    }
}

struct Registers {
    ubyte A, X, Y;
    ProcessorStatus P;
    union {
        addr PC;
        struct {
            ubyte PCL;
            ubyte PCH;
        }
    }
    ubyte S;
}
static assert(Registers.PC.offsetof == Registers.PCL.offsetof);
// ^ The above assumes the host platform is LITTLE ENDIAN (just like the 6502)

alias OpHandler = void function(CPU cpu);

enum OpClass {
    READ,
    RMW,
    WRITE,
    CONTROL,
}

struct OpCodeDef{
    this(string mnemonic, AddressMode mode, OpClass cls, ubyte opcode, ubyte minTicks, ubyte size=0, OpHandler handler=null, bool illegal=false) {
        this.mnemonic = mnemonic;
        this.mode = mode;
        this.opclass = cls;
        this.opcode = opcode;
        this.minTicks = minTicks;
        this.size = (size == 0 ? getOpcodeSize(mode) : size);
        this.handler = handler;
        this.illegal = illegal;
    }

    string mnemonic;
    AddressMode mode;
    OpClass opclass;
    ubyte opcode;
    ubyte size = 1;
    ubyte minTicks;
    OpHandler handler;
    bool illegal = false;
    // TODO: handler?
    // TODO: Struct layout / alignment not optimal
}

void makeVariants(OpCodeDef*[] table, string mnemonic, OpClass cls, const ubyte baseTicks, const AddressMode[int] pairs, OpHandler handler=null, bool illegal=false) {
    foreach(opcode, mode; pairs) {
        ubyte key = ub(opcode);
        assert(table[key] == null, format("Dupliate entry for opcode: %02X", key));
        table[key] = new OpCodeDef(mnemonic, mode, cls, key, baseTicks, getOpcodeSize(mode), handler, illegal);
    }
}

immutable OpCodeDef*[256] OPCODE_DEFS;

shared static this() {
    alias AM = AddressMode;
    OpCodeDef*[256] tmp;
    tmp.makeVariants("ADC", OpClass.READ, 2, [0x69: AM.IMMEDIATE], (CPU c){ c.adcI(); });
    tmp.makeVariants("ADC", OpClass.READ, 2, [
        0x65: AM.ZP_IMMEDIATE,
        0x75: AM.ZP_X,
        0x6D: AM.ABSOLUTE,
        0x7D: AM.ABSOLUTE_X,
        0x79: AM.ABSOLUTE_Y,
        0x61: AM.INDEXED_INDIRECT,
        0x71: AM.INDIRECT_INDEXED,
    ], (CPU c){ c.adcM(); });
    tmp.makeVariants("AND", OpClass.READ, 2, [0x29: AM.IMMEDIATE], (CPU c){ c. andI(); });
    tmp.makeVariants("AND", OpClass.READ, 2, [
        0x25: AM.ZP_IMMEDIATE,
        0x35: AM.ZP_X,
        0x2D: AM.ABSOLUTE,
        0x3D: AM.ABSOLUTE_X,
        0x39: AM.ABSOLUTE_Y,
        0x21: AM.INDEXED_INDIRECT,
        0x31: AM.INDIRECT_INDEXED,
    ], (CPU c){ c.andM(); });
    tmp.makeVariants("ASL", OpClass.RMW, 2, [0x0A: AM.ACCUMULATOR], (CPU c){ c.aslA(); });
    tmp.makeVariants("ASL", OpClass.RMW, 2, [
        0x06: AM.ZP_IMMEDIATE,
        0x16: AM.ZP_X,
        0x0E: AM.ABSOLUTE,
        0x1E: AM.ABSOLUTE_X,
    ], (CPU c){ c.aslM(); });
    tmp.makeVariants("BCC", OpClass.CONTROL, 2, [0x90: AM.RELATIVE], (CPU c){ c.bcc(); });
    tmp.makeVariants("BCS", OpClass.CONTROL, 2, [0xB0: AM.RELATIVE], (CPU c){ c.bcs(); });
    tmp.makeVariants("BEQ", OpClass.CONTROL, 2, [0xF0: AM.RELATIVE], (CPU c){ c.beq(); });
    tmp.makeVariants("BIT", OpClass.CONTROL, 2, [
        0x24: AM.ZP_IMMEDIATE,
        0x2C: AM.ABSOLUTE,
    ], (CPU c){ c.bit(); });
    tmp.makeVariants("BMI", OpClass.CONTROL, 2, [0x30: AM.RELATIVE], (CPU c){ c.bmi(); });
    tmp.makeVariants("BNE", OpClass.CONTROL, 2, [0xD0: AM.RELATIVE], (CPU c){ c.bne(); });
    tmp.makeVariants("BPL", OpClass.CONTROL, 2, [0x10: AM.RELATIVE], (CPU c){ c.bpl(); });
    tmp.makeVariants("BRK", OpClass.CONTROL, 1, [0x00: AM.IMPLIED], (CPU c){ c.brk(); });
    tmp.makeVariants("BVC", OpClass.CONTROL, 2, [0x50: AM.RELATIVE], (CPU c){ c.bvc(); });
    tmp.makeVariants("BVS", OpClass.CONTROL, 2, [0x70: AM.RELATIVE], (CPU c){ c.bvs(); });
    tmp.makeVariants("CLC", OpClass.CONTROL, 1, [0x18: AM.IMPLIED], (CPU c){ c.clc(); });
    tmp.makeVariants("CLD", OpClass.CONTROL, 1, [0xD8: AM.IMPLIED], (CPU c){ c.cld(); });
    tmp.makeVariants("CLI", OpClass.CONTROL, 1, [0x58: AM.IMPLIED], (CPU c){ c.cli(); });
    tmp.makeVariants("CLV", OpClass.CONTROL, 1, [0xB8: AM.IMPLIED], (CPU c){ c.clv(); });
    tmp.makeVariants("CMP", OpClass.READ, 2, [0xC9: AM.IMMEDIATE], (CPU c){ c.cmpI(); });
    tmp.makeVariants("CMP", OpClass.READ, 2, [
        0xC5: AM.ZP_IMMEDIATE,
        0xD5: AM.ZP_X,
        0xCD: AM.ABSOLUTE,
        0xDD: AM.ABSOLUTE_X,
        0xD9: AM.ABSOLUTE_Y,
        0xC1: AM.INDEXED_INDIRECT,
        0xD1: AM.INDIRECT_INDEXED,
    ], (CPU c){ c.cmpM(); });
    tmp.makeVariants("CPX", OpClass.READ, 2, [0xE0: AM.IMMEDIATE], (CPU c){ c.cpxI(); });
    tmp.makeVariants("CPX", OpClass.READ, 2, [
        0xE4: AM.ZP_IMMEDIATE,
        0xEC: AM.ABSOLUTE,
    ], (CPU c){ c.cpxM(); });
    tmp.makeVariants("CPY", OpClass.READ, 2, [0xC0: AM.IMMEDIATE], (CPU c){ c.cpyI(); });
    tmp.makeVariants("CPY", OpClass.READ, 2, [
        0xC4: AM.ZP_IMMEDIATE,
        0xCC: AM.ABSOLUTE,
    ], (CPU c){ c.cpyM(); });
    tmp.makeVariants("DEC", OpClass.RMW, 5, [
        0xC6: AM.ZP_IMMEDIATE,
        0xD6: AM.ZP_X,
        0xCE: AM.ABSOLUTE,
        0xDE: AM.ABSOLUTE_X,
    ], (CPU c){ c.dec(); });
    tmp.makeVariants("DEX", OpClass.CONTROL, 2, [0xCA: AM.IMPLIED], (CPU c){ c.dex(); });
    tmp.makeVariants("DEY", OpClass.CONTROL, 2, [0x88: AM.IMPLIED], (CPU c){ c.dey(); });
    tmp.makeVariants("EOR", OpClass.READ, 2, [0x49: AM.IMMEDIATE], (CPU c){ c.eorI(); });
    tmp.makeVariants("EOR", OpClass.READ, 2, [
        0x45: AM.ZP_IMMEDIATE,
        0x55: AM.ZP_X,
        0x4D: AM.ABSOLUTE,
        0x5D: AM.ABSOLUTE_X,
        0x59: AM.ABSOLUTE_Y,
        0x41: AM.INDEXED_INDIRECT,
        0x51: AM.INDIRECT_INDEXED,
    ], (CPU c){ c.eorM(); });
    tmp.makeVariants("INC", OpClass.RMW, 5, [
        0xE6: AM.ZP_IMMEDIATE,
        0xF6: AM.ZP_X,
        0xEE: AM.ABSOLUTE,
        0xFE: AM.ABSOLUTE_X,
    ], (CPU c){ c.inc(); });
    tmp.makeVariants("INX", OpClass.CONTROL, 2, [0xE8: AM.IMPLIED], (CPU c){ c.inx(); });
    tmp.makeVariants("INY", OpClass.CONTROL, 2, [0xC8: AM.IMPLIED], (CPU c){ c.iny(); });
    tmp.makeVariants("JMP", OpClass.CONTROL, 3, [
        0x4C: AM.ABSOLUTE,
        0x6C: AM.INDIRECT,
    ], (CPU c){ c.jmp(); });
    tmp.makeVariants("JSR", OpClass.CONTROL, 6, [0x20: AM.ABSOLUTE], (CPU c){ c.jsr(); });
    tmp.makeVariants("LDA", OpClass.READ, 2, [0xA9: AM.IMMEDIATE], (CPU c){ c.ldaI(); });
    tmp.makeVariants("LDA", OpClass.READ, 2, [
        0xA5: AM.ZP_IMMEDIATE,
        0xB5: AM.ZP_X,
        0xAD: AM.ABSOLUTE,
        0xBD: AM.ABSOLUTE_X,
        0xB9: AM.ABSOLUTE_Y,
        0xA1: AM.INDEXED_INDIRECT,
        0xB1: AM.INDIRECT_INDEXED,
    ], (CPU c){ c.ldaM(); });
    tmp.makeVariants("LDX", OpClass.READ, 2, [0xA2: AM.IMMEDIATE], (CPU c){ c.ldxI(); });
    tmp.makeVariants("LDX", OpClass.READ, 2, [
        0xA6: AM.ZP_IMMEDIATE,
        0xB6: AM.ZP_Y,
        0xAE: AM.ABSOLUTE,
        0xBE: AM.ABSOLUTE_Y,
    ], (CPU c){ c.ldxM(); });
    tmp.makeVariants("LDY", OpClass.READ, 2, [0xA0: AM.IMMEDIATE], (CPU c){ c.ldyI(); });
    tmp.makeVariants("LDY", OpClass.READ, 2, [
        0xA4: AM.ZP_IMMEDIATE,
        0xB4: AM.ZP_X,
        0xAC: AM.ABSOLUTE,
        0xBC: AM.ABSOLUTE_X,
    ], (CPU c){ c.ldyM(); });
    tmp.makeVariants("LSR", OpClass.RMW, 2, [0x4A: AM.ACCUMULATOR], (CPU c){ c.lsrA(); });
    tmp.makeVariants("LSR", OpClass.RMW, 2, [
        0x46: AM.ZP_IMMEDIATE,
        0x56: AM.ZP_X,
        0x4E: AM.ABSOLUTE,
        0x5E: AM.ABSOLUTE_X,
    ], (CPU c){ c.lsrM(); });
    tmp.makeVariants("NOP", OpClass.CONTROL, 2, [0xEA: AM.IMPLIED], (CPU c){ c.nop!true(); });
    tmp.makeVariants("ORA", OpClass.READ, 2, [0x09: AM.IMMEDIATE], (CPU c){ c.oraI(); });
    tmp.makeVariants("ORA", OpClass.READ, 2, [
        0x05: AM.ZP_IMMEDIATE,
        0x15: AM.ZP_X,
        0x0D: AM.ABSOLUTE,
        0x1D: AM.ABSOLUTE_X,
        0x19: AM.ABSOLUTE_Y,
        0x01: AM.INDEXED_INDIRECT,
        0x11: AM.INDIRECT_INDEXED,
    ], (CPU c){ c.oraM(); });
    tmp.makeVariants("PHA", OpClass.CONTROL, 3, [0x48: AM.IMPLIED], (CPU c){ c.pha(); });
    tmp.makeVariants("PHP", OpClass.CONTROL, 3, [0x08: AM.IMPLIED], (CPU c){ c.php(); });
    tmp.makeVariants("PLA", OpClass.CONTROL, 4, [0x68: AM.IMPLIED], (CPU c){ c.pla(); });
    tmp.makeVariants("PLP", OpClass.CONTROL, 4, [0x28: AM.IMPLIED], (CPU c){ c.plp(); });
    tmp.makeVariants("ROL", OpClass.RMW, 2, [0x2A: AM.ACCUMULATOR], (CPU c){ c.rolA(); });
    tmp.makeVariants("ROL", OpClass.RMW, 2, [
        0x26: AM.ZP_IMMEDIATE,
        0x36: AM.ZP_X,
        0x2E: AM.ABSOLUTE,
        0x3E: AM.ABSOLUTE_X,
    ], (CPU c){ c.rolM(); });
    tmp.makeVariants("ROR", OpClass.RMW, 2, [0x6A: AM.ACCUMULATOR], (CPU c){ c.rorA(); });
    tmp.makeVariants("ROR", OpClass.RMW, 2, [
        0x66: AM.ZP_IMMEDIATE,
        0x76: AM.ZP_X,
        0x6E: AM.ABSOLUTE,
        0x7E: AM.ABSOLUTE_X,
    ], (CPU c){ c.rorM(); });
    tmp.makeVariants("RTI", OpClass.CONTROL, 6, [0x40: AM.IMPLIED], (CPU c){ c.rti(); });
    tmp.makeVariants("RTS", OpClass.CONTROL, 6, [0x60: AM.IMPLIED], (CPU c){ c.rts(); });
    tmp.makeVariants("SBC", OpClass.READ, 2, [0xE9: AM.IMMEDIATE], (CPU c){ c.sbcI(); });
    tmp.makeVariants("SBC", OpClass.READ, 2, [
        0xE5: AM.ZP_IMMEDIATE,
        0xF5: AM.ZP_X,
        0xED: AM.ABSOLUTE,
        0xFD: AM.ABSOLUTE_X,
        0xF9: AM.ABSOLUTE_Y,
        0xE1: AM.INDEXED_INDIRECT,
        0xF1: AM.INDIRECT_INDEXED,
    ], (CPU c){ c.sbcM(); });
    tmp.makeVariants("SEC", OpClass.CONTROL, 2, [0x38: AM.IMPLIED], (CPU c){ c.sec(); });
    tmp.makeVariants("SED", OpClass.CONTROL, 2, [0xF8: AM.IMPLIED], (CPU c){ c.sed(); });
    tmp.makeVariants("SEI", OpClass.CONTROL, 2, [0x78: AM.IMPLIED], (CPU c){ c.sei(); });
    tmp.makeVariants("STA", OpClass.WRITE, 3, [
        0x85: AM.ZP_IMMEDIATE,
        0x95: AM.ZP_X,
        0x8D: AM.ABSOLUTE,
        0x9D: AM.ABSOLUTE_X,
        0x99: AM.ABSOLUTE_Y,
        0x81: AM.INDEXED_INDIRECT,
        0x91: AM.INDIRECT_INDEXED,
    ], (CPU c){ c.sta(); });
    tmp.makeVariants("STX", OpClass.WRITE, 3, [
        0x86: AM.ZP_IMMEDIATE,
        0x96: AM.ZP_Y,
        0x8E: AM.ABSOLUTE,
    ], (CPU c){ c.stx(); });
    tmp.makeVariants("STY", OpClass.WRITE, 3, [
        0x84: AM.ZP_IMMEDIATE,
        0x94: AM.ZP_X,
        0x8C: AM.ABSOLUTE,
    ], (CPU c){ c.sty(); });
    tmp.makeVariants("TAX", OpClass.CONTROL, 2, [0xAA: AM.IMPLIED], (CPU c){ c.tax(); });
    tmp.makeVariants("TAY", OpClass.CONTROL, 2, [0xA8: AM.IMPLIED], (CPU c){ c.tay(); });
    tmp.makeVariants("TSX", OpClass.CONTROL, 2, [0xBA: AM.IMPLIED], (CPU c){ c.tsx(); });
    tmp.makeVariants("TXA", OpClass.CONTROL, 2, [0x8A: AM.IMPLIED], (CPU c){ c.txa(); });
    tmp.makeVariants("TXS", OpClass.CONTROL, 2, [0x9A: AM.IMPLIED], (CPU c){ c.txs(); });
    tmp.makeVariants("TYA", OpClass.CONTROL, 2, [0x98: AM.IMPLIED], (CPU c){ c.tya(); });

    // 'illegal' opcodes
    // Illegal variants of NOP that require the extra tick
    tmp.makeVariants("NOP", OpClass.CONTROL, 2, [
        0x04: AM.ZP_IMMEDIATE,
        0x14: AM.ZP_X,
        0x34: AM.ZP_X,
        0x44: AM.ZP_IMMEDIATE,
        0x54: AM.ZP_X,
        0x64: AM.ZP_IMMEDIATE,
        0x74: AM.ZP_X,
        0xD4: AM.ZP_X,
        0xF4: AM.ZP_X,
        0x89: AM.IMMEDIATE,
        0x1A: AM.IMPLIED,
        0x3A: AM.IMPLIED,
        0x5A: AM.IMPLIED,
        0x7A: AM.IMPLIED,
        0xDA: AM.IMPLIED,
        0xFA: AM.IMPLIED,
        0xC2: AM.IMMEDIATE,
        0xE2: AM.IMMEDIATE,
    ], (CPU c){ c.nop!true(); }, true);
    // Illegal variants of NOP that require an extra tick AND overridden opclass
    tmp.makeVariants("NOP", OpClass.READ, 1, [
        0x0C: AM.ABSOLUTE,
        0x1C: AM.ABSOLUTE_X,
        0x3C: AM.ABSOLUTE_X,
        0x5C: AM.ABSOLUTE_X,
        0x7C: AM.ABSOLUTE_X,
        0xDC: AM.ABSOLUTE_X,
        0xFC: AM.ABSOLUTE_X,
    ], (CPU c){ c.nop!true(); }, true);
    // Illegal variants of NOP that don't require an extra tick
    tmp.makeVariants("NOP", OpClass.READ, 2, [
        0x80: AM.IMMEDIATE,
        0x82: AM.IMMEDIATE,
    ], (CPU c){ c.nop(); }, true);
    // TODO: Verify correct cycle counts for illegal
    // variants of NOP
    // opcodes that will 'KIL(l)' / jam the CPU
    tmp.makeVariants("KIL", OpClass.CONTROL, 0, [
        0x02: AM.IMPLIED,
        0x12: AM.IMPLIED,
        0x22: AM.IMPLIED,
        0x32: AM.IMPLIED,
        0x42: AM.IMPLIED,
        0x52: AM.IMPLIED,
        0x62: AM.IMPLIED,
        0x72: AM.IMPLIED,
        0x92: AM.IMPLIED,
        0xB2: AM.IMPLIED,
        0xD2: AM.IMPLIED,
        0xF2: AM.IMPLIED,
    ], null, true);
    // SLO = ASL + ORA
    tmp.makeVariants("SLO", OpClass.RMW, 3, [
        0x07: AM.ZP_IMMEDIATE,
        0x17: AM.ZP_X,
        0x03: AM.INDEXED_INDIRECT,
        0x13: AM.INDIRECT_INDEXED,
        0x0F: AM.ABSOLUTE,
        0x1F: AM.ABSOLUTE_X,
        0x1B: AM.ABSOLUTE_Y,
    ], (CPU c){ c.slo(); }, true);
    // RLA = ROL + AND
    tmp.makeVariants("RLA", OpClass.RMW, 2, [
        0x27: AM.ZP_IMMEDIATE,
        0x37: AM.ZP_X,
        0x23: AM.INDEXED_INDIRECT,
        0x33: AM.INDIRECT_INDEXED,
        0x2F: AM.ABSOLUTE,
        0x3F: AM.ABSOLUTE_X,
        0x3B: AM.ABSOLUTE_Y,
    ], (CPU c){ c.rla(); }, true);
    // SRE = LSR + EOR
    tmp.makeVariants("SRE", OpClass.RMW, 2, [
        0x47: AM.ZP_IMMEDIATE,
        0x57: AM.ZP_X,
        0x43: AM.INDEXED_INDIRECT,
        0x53: AM.INDIRECT_INDEXED,
        0x4F: AM.ABSOLUTE,
        0x5F: AM.ABSOLUTE_X,
        0x5B: AM.ABSOLUTE_Y,
    ], (CPU c){ c.sre(); }, true);
    // RRA = ROR + ADC
    tmp.makeVariants("RRA", OpClass.RMW, 2, [
        0x67: AM.ZP_IMMEDIATE,
        0x77: AM.ZP_X,
        0x63: AM.INDEXED_INDIRECT,
        0x73: AM.INDIRECT_INDEXED,
        0x6F: AM.ABSOLUTE,
        0x7F: AM.ABSOLUTE_X,
        0x7B: AM.ABSOLUTE_Y,
    ], (CPU c){ c.rra(); }, true);
    // SAX = 'Store A&X into {adr}'
    tmp.makeVariants("SAX", OpClass.WRITE, 3, [
        0x87: AM.ZP_IMMEDIATE,
        0x97: AM.ZP_Y,
        0x83: AM.INDEXED_INDIRECT,
        0x8F: AM.ABSOLUTE,
    ], (CPU c){ c.sax(); }, true);
    // LAX = LDA + LDX
    tmp.makeVariants("LAX", OpClass.READ, 3, [
        0xA7: AM.ZP_IMMEDIATE,
        0xB7: AM.ZP_Y,
        0xA3: AM.INDEXED_INDIRECT,
        0xB3: AM.INDIRECT_INDEXED,
        0xAF: AM.ABSOLUTE,
        0xBF: AM.ABSOLUTE_Y,
    ], (CPU c){ c.lax(); }, true);
    // DCP = DEC + CMP
    tmp.makeVariants("DCP", OpClass.RMW, 3, [
        0xC7: AM.ZP_IMMEDIATE,
        0xD7: AM.ZP_X,
        0xC3: AM.INDEXED_INDIRECT,
        0xD3: AM.INDIRECT_INDEXED,
        0xCF: AM.ABSOLUTE,
        0xDF: AM.ABSOLUTE_X,
        0xDB: AM.ABSOLUTE_Y,
    ], (CPU c){ c.dcp(); }, true);
    // ISC = INC + SBC
    tmp.makeVariants("ISC", OpClass.RMW, 3, [
        0xE7: AM.ZP_IMMEDIATE,
        0xF7: AM.ZP_X,
        0xE3: AM.INDEXED_INDIRECT,
        0xF3: AM.INDIRECT_INDEXED,
        0xEF: AM.ABSOLUTE,
        0xFF: AM.ABSOLUTE_X,
        0xFB: AM.ABSOLUTE_Y,
    ], (CPU c){ c.isc(); }, true);
    // ANC = AND (#imm) + ASL
    tmp.makeVariants("ANC", OpClass.READ, 3, [
        0x0B: AM.IMMEDIATE,
        0x2B: AM.IMMEDIATE,
    ], null, true);
    // ALR = AND + LSR
    tmp.makeVariants("ALR", OpClass.READ, 3, [0x4B: AM.IMMEDIATE], null, true);
    // ARR = AND + ROR
    tmp.makeVariants("ARR", OpClass.READ, 3, [0x6B: AM.IMMEDIATE], null, true);
    // XAA = TXA + AND(#imm) -- highly unstable
    tmp.makeVariants("XAA", OpClass.READ, 3, [0x8B: AM.IMMEDIATE], null, true);
    // LAX = LDA(#imm) + TAX -- highly unstable
    tmp.makeVariants("LAX", OpClass.READ, 3, [0xAB: AM.IMMEDIATE], null, true);
    // AXS = A&X minus #imm into X
    tmp.makeVariants("AXS", OpClass.READ, 3, [0xCB: AM.IMMEDIATE], null, true);
    // SBC -- illegal variant of legal opcode (?)
    tmp.makeVariants("SBC", OpClass.READ, 3, [0xEB: AM.IMMEDIATE], (CPU c){ c.sbcI(); }, true);
    // AHX = Store A&X&H into {adr} -- conditionally unstable
    tmp.makeVariants("AHX", OpClass.WRITE, 3, [
        0x93: AM.INDIRECT_INDEXED,
        0x9F: AM.ABSOLUTE_Y,
    ], null, true);
    // SHY = stores Y&H into {adr} -- conditionally unstable
    tmp.makeVariants("SHY", OpClass.WRITE, 3, [0x9C: AM.ABSOLUTE_X], null, true);
    // SHX = stores X&H into {adr} -- conditionally unstable
    tmp.makeVariants("SHX", OpClass.WRITE, 3, [0x9E: AM.ABSOLUTE_Y], null, true);
    // TAS = stores A&X into S and A&X&H into {adr} -- conditionally unstable
    tmp.makeVariants("TAS", OpClass.WRITE, 3, [0x9B: AM.ABSOLUTE_Y], null, true);
    // LAS = stores {adr}&S into A, X, and S
    tmp.makeVariants("LAS", OpClass.WRITE, 3, [0xBB: AM.ABSOLUTE_Y], null, true);

    // Make some assertions about the opcode table
    foreach(i, opdef; tmp) {
        // Assert that for all possible opcodes (0-0xFF), the OpCodeDef has been created
        assert(opdef !is null, format("Missing opcode: %02X", i));
        // Assert that the index in the table matches the opcode defined in the structure
        assert(opdef.opcode == i, format("OpCodeDef 0x%02X has incorrect index", i));

        // TEMPORARY
        // Assert that all 'legal' opdefs have valid handlers defined
        assert(opdef.illegal || opdef.handler !is null, format("OpCodeDef 0x%02X is legal but missing handler", i));
    }

    // Transfer ownership from temporary buffer to static immutable reference
    import std.exception : assumeUnique;
    OPCODE_DEFS = assumeUnique(tmp);
}

class CPU {
    Registers regs;
    addr addrLine;
    ubyte dataLine;

    uint tickCounter;
    ubyte opcode;
    NESBus bus;

    bool pendingNMI, pendingIRQ, inInterrupt;

    ubyte[CPU_RAM_SIZE] internalRAM;

    Fiber currentState;

    this() {
        currentState = new Fiber(&this.step);
    }

    void reset() {
        // Finish executing any in-progress operation
        //while(currentState.state != Fiber.State.TERM)
        //    currentState.call();
        // Reset the fiber state
        currentState.reset();

        // Clear interrupt state
        pendingNMI = pendingIRQ = inInterrupt = false;

        // Read the reset vector from ROM
        ubyte lo, hi;
        lo = readBus!(false,false)(CPU_RESET_VECTOR);
        hi = readBus!(false,false)(CPU_RESET_VECTOR+1);

        // Reset tickCounter
        tickCounter = 0;

        // Jump to reset vector address
        jmp(makeAddr(lo, hi));
    }

    ubyte readRAM(const addr address) {
        return internalRAM[address & CPU_RAM_MASK];
    }

    void writeRAM(const addr address, const ubyte value) {
        internalRAM[address & CPU_RAM_MASK] = value;
    }

    bool doTick() {
        if(currentState.state == Fiber.State.TERM)
            currentState.reset();
        currentState.call();
        // Return true if this tick ended a complete instruction
        return currentState.state == Fiber.State.TERM;
    }

    void tick(bool yield=true)() {
        // Optionally yield (if we're running a fiber)
        static if(yield) {
            // Only if we're executing in a fiber (and its ours), do we yield
            if(Fiber.getThis() is currentState && currentState.state == Fiber.State.EXEC)
                Fiber.yield();
        }

        // Increment the tick counter (_after_ yielding, due to *cheat*
        // described in `step()`)
        tickCounter++;
    }

    debug ubyte[] opBuffer = [];
    debug uint startingTicks;

    void step() {
        // The one common cycle / tick operation at the beginning of every instruction
        // is to read opcode and increment PC. From there, behavior depends on the opcode
        // and address mode.
        debug startingTicks = tickCounter;
        debug addr originalPC = regs.PC;
        debug opBuffer.length = 0;

        // Query pending interrupts -- a pending NMI will always trigger,
        // however an IRQ will only trigger if Interrupt Disable is clear
        if(pendingNMI || (pendingIRQ && !regs.P.I)) {
            // Perform the interrupt sequence and short-circuit
            doInterrupt();
            return;
        }

        // We want the number of coroutine calls to equal the number of CPU
        // ticks for the current instruction, but this means that the number of yields
        // has to always be one less than the number of ticks (otherwise a final resume()
        // is necessary to terminate the fiber). Ideally, we would just skip
        // the last `yield` of every instruction, but this rapidly becomes complicated
        // because some instructions are variable length, and there are exceptions
        // like JMP which has its final tick in `prepareAbsolute`, requiring
        // a special case code path.
        // As an experimental alternative -- lets try 'cheating' and simply skip
        // the first yield (after reading the opcode) instead. The advantage is that
        // it will accomplish the # calls = # ticks goal, and can be applied uniformly
        // (since it is the one common code path / yield of _all_ opcodes), but it does
        // mean internal state may actually be one tick ahead in comparison to
        // system model. This may or may not be a problem, but testing will help
        // us decide.
        opcode = readPC!(true,false)();
        auto opdef = lookupOpcode(opcode);

        assert(opdef.handler, format("Missing handler for opcode (%02X) (%s) @ $%04X", opcode, opdef.mnemonic, regs.PC-1));

        final switch(opdef.mode) {
            case AddressMode.IMPLIED:
            case AddressMode.ACCUMULATOR:
                // These are expected to handle themselves, no operands necessary
                opdef.handler(this);
                break;

            case AddressMode.RELATIVE:
            case AddressMode.IMMEDIATE:
                // The operand immediately follows the opcode, calling readPC() (which calls
                // readBus()) will set `dataLine` to the read value, which the handler should utilize
                readPC();
                opdef.handler(this);
                break;

            case AddressMode.ZP_IMMEDIATE:
                prepareZeroPage!false();
                opdef.handler(this);
                break;

            case AddressMode.ZP_X:
                prepareZeroPage!true(regs.X);
                opdef.handler(this);
                break;

            case AddressMode.ZP_Y:
                prepareZeroPage!true(regs.Y);
                opdef.handler(this);
                break;

            case AddressMode.ABSOLUTE:
                prepareAbsolute!false(opdef.opclass);
                opdef.handler(this);
                break;

            case AddressMode.ABSOLUTE_X:
                prepareAbsolute!true(opdef.opclass, regs.X);
                opdef.handler(this);
                break;

            case AddressMode.ABSOLUTE_Y:
                prepareAbsolute!true(opdef.opclass, regs.Y);
                opdef.handler(this);
                break;

            case AddressMode.INDEXED_INDIRECT:
                prepareIndexedIndirect();
                opdef.handler(this);
                break;

            case AddressMode.INDIRECT_INDEXED:
                prepareIndirectIndexed(opdef.opclass);
                opdef.handler(this);
                break;

            case AddressMode.INDIRECT:
                // Only used by JMP
                prepareAbsoluteIndirect();
                opdef.handler(this);
                break;
        }
        //debug(trace) {
        //    auto endingTicks = tickCounter;
        //    auto totalTicks = endingTicks-startingTicks;
        //    auto lines = disassemble(opBuffer, originalPC);
        //    //assert(lines.length == 1, format("Expected lines.length = 1, got %d\nLines: %s", lines.length, lines));
        //    //writefln("%-48s%s", lines[0], getStatusString());
        //}
    }

    string getRegsStatusString() {
        return format("A:%02X X:%02X Y:%02X P:%02X SP:%02X", regs.A, regs.X, regs.Y, regs.P.P, regs.S);
    }

    string getStatusString() {
        return format("%-48s%s", disassemblePC(), getRegsStatusString());
    }

    /// Read a byte from PC, increment PC, and incur a(n optionally yielding) tick
    ubyte readPC(bool advance=true, bool yield=true)() {
        ubyte result = readBus!(true,yield)(regs.PC);
        static if(advance)
            ++regs.PC;
        debug opBuffer ~= result;
        return result;
    }

    /// Helper function to assemble a 16 bit address from discrete low and high bytes
    pure static addr makeAddr(ubyte lo, ubyte hi) {
        return cast(addr)(((hi << 8) + lo) & 0xFFFF);
    }

    /// Prepapre for an Absolute Indirect operation by resolving target address to addrLine
    void prepareAbsoluteIndirect() {
        ubyte lo, hi;
        // Read in the pointer to the effective address from PC
        lo = readPC();
        hi = readPC();
        // Assemble the pointer to effective address
        addrLine = makeAddr(lo, hi);
        // Read the effecitve address low byte, incurring a tick
        lo = readBus(addrLine);
        // Due to a quirk / bug in 6502, if the pointer points to $xxFF,
        // the high byte will actually be fetched from $xx00
        // e.g. the page is locked / will not wrap
        if((addrLine & 0xFF) == 0xFF)
            addrLine &= 0xFF00;
        else
            ++addrLine;
        // Read the effective address high byte, incurring a tick
        hi = readBus(addrLine);
        // Assemble the effective address
        addrLine = makeAddr(lo, hi);
    }

    /// Prepare for an indexed indirect operation by resolving the address on addrLine
    void prepareIndexedIndirect() {
        ubyte lo, hi;
        // Read the address operand
        addrLine = readPC();
        // Add the X register to the operand, incurring a tick during the ALU operation
        // The effective address is always loaded from zero page, so mask result
        addrLine = ub(addrLine + regs.X);
        tick();
        // Read the low byte of the effective address, increment address line to next
        // byte, incur a tick
        lo = readBus(addrLine++);
        // Read the high byte of the effective address, masking result to zero-page boundary
        // (If the low byte is at 0xFF, the high byte would be at 0x00)
        // incur a tick in the process
        hi = readBus(addrLine & 0xFF);
        // Assemble the effective address
        addrLine = makeAddr(lo, hi);
    }

    /// Prepare for an indirect indexed operation by resolving the address on addrLine
    void prepareIndirectIndexed(OpClass cls) {
        ubyte lo, hi;
        // Read the zero-page address of pointer to effective address
        addrLine = readPC();
        // Read the low-byte of the effective address, incurring a tick, and increment address
        lo = readBus(addrLine++);
        // Read the high-byte of the effective address, wrapping to zero page by masking address
        hi = readBus(addrLine & 0xFF);
        // Add Y to the effective address, incur a tick during ALU operation
        addr tmp = cast(addr)((lo + regs.Y) & 0xFFFF);
        //tick();

        bool oops = false;
        // If the sum overflowed, potentially incur an 'oops' cycle to correct the address (for READ instructions)
        if(tmp > 0xFF) {
            hi++;
            oops = true;
        }

        // Only for READ instructions, is the oops cycle conditional -- for RMW / W, it's unconditional
        // (and for control, it is skipped)
        if(cls == OpClass.READ) {
            if(oops)
                tick();
        } else if(cls == OpClass.RMW || cls == OpClass.WRITE) {
            tick();
        }

        // Mask the summed low address byte in case it overflowed (see above)
        lo = ub(tmp);
        addrLine = makeAddr(lo, hi);
    }

    /// Prepare for a zero-page (and optionally indexed) operation by resolving the address on addrLine
    void prepareZeroPage(bool indexed)(ubyte index=0) {
        // zero page, optionally indexed
        addrLine = readPC();
        // optionally, add an index register (value of X or Y passed in `index`)
        static if(indexed) {
            // Indexed zero-page mode wraps around on overflow, rather than have 'oops' cycle
            // to correct for page crossing, so mask the result to [0,0xFF]
            addrLine = ub(addrLine + index);
            // Indexed zero-page incurs an extra tick to perform the addition
            tick();
        }
    }

    /// Prepare for an absolute operation by resolving the address on addrLine
    void prepareAbsolute(bool indexed)(OpClass cls, ubyte index=0) {
        ubyte lo, hi;
        lo = readPC();
        hi = readPC();
        static if(indexed) {
            addr tmp = cast(addr)((lo + index) & 0xFFFF);

            bool oops = false;
            if(tmp > 0xFF) {
                // 'oops' - page boundary crossed, fix the high byte and incur an extra tick
                // due to ALU operation
                ++hi;
                oops = true;
            }

            // Only for READ instructions, is the oops cycle conditional -- for RMW / W, it's unconditional
            // (and for control, it is skipped)
            if(cls == OpClass.READ) {
                if(oops)
                    tick();
            } else if(cls == OpClass.RMW || cls == OpClass.WRITE) {
                tick();
            }

            // mask the sum of lo + index in case it overflowed
            lo = ub(tmp);
        }
        addrLine = makeAddr(lo, hi);
    }

    /// Read a value from the system bus, optionally incurring
    /// a(n optionally yielding) tick in the process.
    ubyte readBus(bool doTick=true, bool yield=true)(in addr address) {
        dataLine = bus.read(address);
        static if(doTick)
            tick!yield();
        return dataLine;
    }

    /// Write a value to an address on the system bus, optionally
    /// incurring a(n optionally yielding) tick in the process
    void writeBus(bool doTick=true, bool yield=true)(in addr address, in ubyte value) {
        // TODO: assign `dataLine` (?)
        dataLine = value;
        bus.write(address, value);
        static if(doTick)
            tick!yield();
    }

    void dmaTransfer(ubyte page) {
        foreach(i; 0..256) {
            ubyte value = readBus(makeAddr(ub(i), page));
            writeBus(0x2004, value);
        }
    }

    void enqueueNMIInterrupt() {
        if(!inInterrupt)
            pendingNMI = true;
    }

    void enqueueIRQInterrupt() {
        if(!inInterrupt)
            pendingIRQ = true;
    }

    void doInterrupt() {
        /* For reference, from: https://www.nesdev.org/wiki/CPU_interrupts#IRQ_and_NMI_tick-by-tick_execution
             #  address R/W description
            --- ------- --- -----------------------------------------------
             1    PC     R  fetch opcode (and discard it - $00 (BRK) is forced into the opcode register instead)
             2    PC     R  read next instruction byte (actually the same as above, since PC increment is suppressed. Also discarded.)
             3  $0100,S  W  push PCH on stack, decrement S
             4  $0100,S  W  push PCL on stack, decrement S
            *** At this point, the signal status determines which interrupt vector is used ***
             5  $0100,S  W  push P on stack (with B flag *clear*), decrement S
             6   A       R  fetch PCL (A = FFFE for IRQ, A = FFFA for NMI), set I flag
             7   A       R  fetch PCH (A = FFFF for IRQ, A = FFFB for NMI)
         */
        // Start with two 'dummy' reads of PC, but don't advance, and force opcode to BRK
        //readPC!false();
        //readPC!false();
        // Use tick() to avoid side effects of readPC() (tainting opBuffer)
        tick();
        tick();
        opcode = 0;
        pushStack(regs.PCH);
        pushStack(regs.PCL);
        // At least one of the pending interrupt flags should be set
        assert(pendingNMI || pendingIRQ, "interrupt() called without a pending interrupt");
        addr target = (pendingNMI ? CPU_NMI_VECTOR : CPU_IRQ_VECTOR);
        pushStack(regs.P.P & (~ProcessorStatus.Flags.BREAK));
        regs.P.I = true;
        regs.PCL = readBus(target);
        regs.PCH = readBus(cast(addr)((target+1)&0xFFFF));
        // Both interrupt flags are cleared, regardless of which was actually
        // invoked
        pendingNMI = pendingIRQ = false;
        inInterrupt = true;
    }

    /// ADC - ADd with Carry Accumulator (implementation)
    /// NOT used directly by interpreter (see adcI / adcM)
    void adc(ubyte operand) {
        ushort result = regs.A + operand + (regs.P.C ? 1 : 0);
        // set the carry bit
        regs.P.C = (result & 0x0100) > 0;
        // if the sign bit is identical between operands (either 1/1 or 0/0), and the result's
        // sign bit does _not_ match, there was an overflow.
        regs.P.V = ((regs.A & operand & 0x80) && !(result & 0x80)) ||
            ((~regs.A & ~operand & 0x80) && (result & 0x80));
        regs.A = ub(result);
        regs.P.setNZ(regs.A);
    }

    /// ADC -- ADd with Carry Accumulator with an immediate value from opcode
    void adcI() {
        adc(dataLine);
    }

    /// ADC -- ADd with Carry Accumulator with contents of memory address
    void adcM() {
        adc(readBus(addrLine));
    }

    @("ADC")
    unittest {
        auto cpu = new CPU();
        cpu.regs.A = 32;
        cpu.adc(224); // 224 = 2's complement of -32
        writeln("Tested adc, result: ", cpu.regs.A, " Status: ", cpu.regs.P);
        // Result should be 0, flags N, V should be clear, flags Z, C should be set
        assert(cpu.regs.A == 0 && !cpu.regs.P.N && !cpu.regs.P.V && cpu.regs.P.Z && cpu.regs.P.C);

        // clear the carry flag
        cpu.regs.P.C = false;
        cpu.regs.A = 0x7F; // maximum signed value (127)
        cpu.adc(1); // add 127 + 1 = 128, overflow without carry
        writeln("Result: ", cpu.regs.A, " Status: ", cpu.regs.P);
        assert(cpu.regs.A == 0x80 && cpu.regs.P.N && cpu.regs.P.V && !cpu.regs.P.Z && !cpu.regs.P.C);
    }

    /// AND - bitwise AND  Accumulator (implementation)
    /// NOT used directly by interpreter (see andI / andM)
    void and(ubyte operand) {
        regs.A = (regs.A & operand);
        regs.P.setNZ(regs.A);
        // ALU operation incurs a tick
        //tick();
    }

    /// AND -- bitwise AND Accumulator with immediate value
    void andI() {
        and(dataLine);
    }

    /// AND -- bitwise AND Accumulator with contents of memory address
    void andM() {
        and(readBus(addrLine));
    }

    @("AND")
    unittest {
        auto cpu = new CPU();
        cpu.regs.A = 0xAA; // 10101010
        cpu.and(0x55); // 01010101 == 0
        assert(cpu.regs.A == 0 && cpu.regs.P.Z && !cpu.regs.P.N);

        cpu.regs.A = 0b10011001;
        cpu.and(0b10110001);
        assert(cpu.regs.A == 0b10010001 && cpu.regs.P.N && !cpu.regs.P.Z);
    }

    /// ASL - Arithmetic Shift Left (implementation)
    ubyte asl(ubyte value) {
        regs.P.C = (value & 0x80) > 0; // carry flag set to old bit 7
        ubyte result = ub(value << 1);
        regs.P.setNZ(result);
        return result;
    }

    /// ASL -- Arithmetic Shift Left (on accumulator)
    void aslA() {
        regs.A = asl(regs.A);
        // Incurs a tick
        tick();
    }

    /// ASL -- Arithmetic Shift Left (on value in memory)
    void aslM() {
        ubyte value = readBus(addrLine);
        // technically, the (unprocessed) value is written back to the address during
        // the ALU operation -- but we're omitting that here as it's effectively moot
        // just tick manually instead
        tick();
        value = asl(value);
        writeBus(addrLine, value);
    }

    @("ASL")
    unittest {
        auto cpu = new CPU();
        ubyte result = cpu.asl(0b01110111);
        assert(result == 0b11101110 && cpu.regs.P.N && !cpu.regs.P.Z);
    }

    void branch(ProcessorStatus.Flags flag, bool cond)(ubyte operand) {
        if(cast(bool)(regs.P.P & flag) == cond) {
            // a successful branch inccurs an extra tick due to ALU operation
            // to calculate a new PC
            tick();
            // Calculate a new PC, cast offset to a signed value
            ushort oldPC = regs.PC;
            regs.PC += cast(byte)(operand);
            // if crossing a page boundary, an extra tick is incurred due to
            // using ALU (again) to fixup result
            uint oldPage = oldPC >> 8;
            uint newPage = regs.PC >> 8;
            if(newPage != oldPage)
                tick();
        }
        // a failed branch incurs no extra ticks and has no side effects
    }

    /// BCC -- Branch on Carry Clear (implementation)
    void bcc(ubyte operand) {
        branch!(ProcessorStatus.Flags.CARRY, false)(operand);
    }

    /// BCC -- Branch on Carry Clear (immediate mode, operand assumed to be on `dataLine`)
    void bcc() {
        bcc(dataLine);
    }

    @("BCC")
    unittest {
        // A successful branch with positive offset to same page incurs a tick
        auto cpu = new CPU();
        cpu.regs.PC = 0x00F0;
        cpu.regs.P.C = false;
        cpu.bcc(0x04);
        assert(cpu.regs.PC == 0x00F4 && cpu.tickCounter == 1);

        // successful branch, negative offset
        cpu = new CPU();
        cpu.regs.PC = 0x00F0;
        cpu.regs.P.C = false;
        cpu.bcc(cast(ubyte)(-0x0F));
        assert(cpu.regs.PC == 0x00E1 && cpu.tickCounter == 1);

        // A failed branch has no side effects and no extra ticks
        cpu = new CPU();
        cpu.regs.PC = 0x001F;
        cpu.regs.P.C = true;
        cpu.bcc(0x7F);
        assert(cpu.regs.PC == 0x001F && cpu.tickCounter == 0);

        // A branch to a new page incurs two extra ticks
        cpu = new CPU();
        cpu.regs.PC = 0x00FE;
        cpu.regs.P.C = false;
        cpu.bcc(0x04);
        assert(cpu.regs.PC == 0x0102 && cpu.tickCounter == 2);
    }

    /// BCS -- Branch on Carry Set (implementation)
    void bcs(ubyte operand) {
        branch!(ProcessorStatus.Flags.CARRY, true)(operand);
    }

    /// BCS -- Branch on Carry Set (immediate mode)
    void bcs() {
        bcs(dataLine);
    }

    @("BCS")
    unittest {
        auto cpu = new CPU();
        cpu.regs.PC = 0x00F0;
        cpu.regs.P.C = true;
        cpu.bcs(0x04);
        assert(cpu.regs.PC == 0x00F4 && cpu.tickCounter == 1);
    }

    /// BEQ -- Branch on EQual (implementation)
    void beq(ubyte operand) {
        branch!(ProcessorStatus.Flags.ZERO, true)(operand);
    }

    /// BEQ -- Branch on EQual (immediate mode)
    void beq() {
        beq(dataLine);
    }

    /// BIT -- BIt Test (implementation)
    void bit(ubyte operand) {
        ubyte result = regs.A & operand;
        regs.P.V = (operand & ProcessorStatus.Flags.OVERFLOW) > 0;
        regs.P.N = (operand & ProcessorStatus.Flags.NEGATIVE) > 0;
        regs.P.Z = (result == 0);
    }

    /// BIT -- BIt Test a mask in Accumulator with contents of a memory address
    void bit() {
        bit(readBus(addrLine));
    }

    @("BIT")
    unittest {
        auto cpu = new CPU();
        cpu.regs.A = 0b00111100;
        cpu.bit(0b11000011);
        assert(cpu.regs.P.V);
        assert(cpu.regs.P.N);
        assert(cpu.regs.P.Z);
    }

    /// BMI -- Branch on MInus (negative) (implementation)
    void bmi(ubyte operand) {
        branch!(ProcessorStatus.Flags.NEGATIVE, true)(operand);
    }

    /// BMI -- Branch on MInus (immediate mode)
    void bmi() {
        bmi(dataLine);
    }

    /// BNE -- Branch on Not Equal (implementation)
    void bne(ubyte operand) {
        branch!(ProcessorStatus.Flags.ZERO, false)(operand);
    }

    /// BNE -- Branch on Not Equal (immediate mode)
    void bne() {
        bne(dataLine);
    }

    /// BPL -- Branch on Positive (implementation)
    void bpl(ubyte operand) {
        branch!(ProcessorStatus.Flags.NEGATIVE, false)(operand);
    }

    /// BPL -- Branch on Positive (immediate mode)
    void bpl() {
        bpl(dataLine);
    }

    /// BRK -- BReaK
    void brk() {
        // Perform a dummy read to advance PC (and incur a tick)
        readPC();
        // Push processor status on stack with the Break
        // and Interrupt disable flags set
        pushStack(regs.P.P | ProcessorStatus.Flags.BREAK | ProcessorStatus.Flags.INTERRUPT_DISABLE);
        pushStack(regs.PCL);
        pushStack(regs.PCH);
        // Read the BRK vector from memory, each read incurs a tick
        regs.PCL = readBus(CPU_BRK_VECTOR);
        regs.PCH = readBus(CPU_BRK_VECTOR+1);
    }

    // TODO: Unit test brk()

    /// BVC -- Branch on oVerflow Clear (implementation)
    void bvc(ubyte operand) {
        branch!(ProcessorStatus.Flags.OVERFLOW, false)(operand);
    }

    /// BVC -- Branch on oVerflow Clear (immediate mode)
    void bvc() {
        bvc(dataLine);
    }

    /// BVS -- Branch on oVerflow Set (implementation)
    void bvs(ubyte operand) {
        branch!(ProcessorStatus.Flags.OVERFLOW, true)(operand);
    }

    /// BVS -- Branch on oVerflow Set (immediate mode)
    void bvs() {
        bvs(dataLine);
    }

    // TODO: Unit tests for the CLX / SEX (giggity) instructions
    /// CLC -- CLear Carry flag
    void clc() {
        regs.P.C = false;
        // incur a tick
        tick();
    }

    /// CLD -- CLear Decimal flag
    void cld() {
        regs.P.D = false;
        // incur a tick
        tick();
    }

    /// CLI -- CLear Interrupt disable flag
    void cli() {
        regs.P.I = false;
        // incur a tick, but don't yield
        tick!false();
    }

    /// CLV -- CLear oVerflow flag
    void clv() {
        regs.P.V = false;
        // incur a tick
        tick();
    }

    /// Helper function to consolidate implementation of CMP instruction variants
    void compare(ubyte reg, ubyte operand) {
        ubyte result = cast(ubyte)(reg - operand);
        //regs.P.C = cast(byte)(result) >= 0;
        regs.P.C = (reg >= operand);
        regs.P.setNZ(result);
    }

    /// CMP -- CoMPare (against Accumulator) (implementation)
    void cmp(ubyte operand) {
        compare(regs.A, operand);
    }

    /// CMP -- CoMPare (against Accumulator) (immediate value)
    void cmpI() {
        cmp(dataLine);
    }

    /// CMP -- CoMPare (against Accumulator) a memory-sourced value
    void cmpM() {
        cmp(readBus(addrLine));
    }

    @("CMP")
    unittest {
        auto cpu = new CPU();
        cpu.regs.A = cast(ubyte)(-10);
        cpu.cmp(5);
        assert(cpu.regs.P.C && !cpu.regs.P.Z && cpu.regs.P.N);

        cpu = new CPU();
        cpu.regs.A = 32;
        cpu.cmp(32);
        assert(cpu.regs.P.C && cpu.regs.P.Z && !cpu.regs.P.N);

        cpu = new CPU();
        cpu.regs.A = 32;
        cpu.cmp(10);
        assert(cpu.regs.P.C && !cpu.regs.P.Z && !cpu.regs.P.N);
    }

    /// CPX -- ComPare X (implementation)
    void cpx(ubyte operand) {
        compare(regs.X, operand);
    }

    /// CPX -- ComPare X (immediate mode)
    void cpxI() {
        cpx(dataLine);
    }

    /// CPX -- ComPare X (memory sourced)
    void cpxM() {
        cpx(readBus(addrLine));
    }

    /// CPY -- ComPare Y (implementation)
    void cpy(ubyte operand) {
        compare(regs.Y, operand);
    }

    /// CPY -- ComPare Y (immediate mode)
    void cpyI() {
        cpy(dataLine);
    }

    /// CPY -- ComPare Y (memory-sourced)
    void cpyM() {
        cpy(readBus(addrLine));
    }

    /// DCP* -- DEC + CMP
    void dcp() {
        ubyte value = readBus(addrLine);
        --value;
        compare(regs.A, value);
        // CMP usually requires an extra tick for ALU operation
        tick();
        writeBus(addrLine, value);
    }

    /// DECrement value at address
    void dec() {
        ubyte value = readBus(addrLine);
        regs.P.setNZ(--value);
        // During the operation, the unprocessed value is actually written back out to the
        // address while performing ALU operation, but is omitted here because it is moot
        // Instead just tick manually
        tick();
        writeBus(addrLine, value);
    }

    @("DEC")
    unittest {
        // TODO: Unit test DEC when bus is functional
    }

    /// DEcrement X
    void dex() {
        regs.P.setNZ(--regs.X);
        // A dummy read is performed while ALU operation takes place but this is
        // omitted because it is moot
        // Instead tick manually
        tick();
    }

    /// DEcrement Y
    void dey() {
        regs.P.setNZ(--regs.Y);
        // A dummy read is performed during ALU operation but is omitted here because
        // it is moot
        // Instead tick manually
        tick();
    }

    /// Exclusive OR Accumulater with value (implementation)
    void eor(ubyte operand) {
        regs.A = regs.A ^ operand;
        regs.P.setNZ(regs.A);
    }

    void eorI() {
        eor(dataLine);
    }

    /// Exclusive OR with memory-sourced operand
    void eorM() {
        eor(readBus(addrLine));
    }

    @("EOR")
    unittest {
        auto cpu = new CPU();
        cpu.regs.A = 0b00110011;
        cpu.eor(0b11001111);
        assert(cpu.regs.A == 0b11111100 && cpu.regs.P.N && !cpu.regs.P.Z);
    }

    /// INC -- INCrement memory location
    void inc() {
        ubyte value = readBus(addrLine);
        // the unprocessed value is actually written back out while the ALU operation is
        // being performed, but this is omitted here because it is moot
        // Instead just tick manually
        tick();
        regs.P.setNZ(++value);
        writeBus(addrLine, value);
    }

    // TODO: Unit test INC when bus is operational

    /// INX -- INcrement X
    void inx() {
        regs.P.setNZ(++regs.X);
        // Incurs an extra tick
        tick();
    }

    @("INX")
    unittest {
        auto cpu = new CPU();
        cpu.regs.X = 0x02;
        cpu.inx();
        assert(cpu.regs.X == 0x03 && !cpu.regs.P.Z && !cpu.regs.P.N);

        cpu = new CPU();
        cpu.regs.X = 0x7F;
        cpu.inx();
        assert(cpu.regs.X == 0x80 && !cpu.regs.P.Z && cpu.regs.P.N);

        cpu = new CPU();
        cpu.regs.X = 0xFF;
        cpu.inx();
        assert(cpu.regs.X == 0 && cpu.regs.P.Z && !cpu.regs.P.N);
    }

    /// INY -- INcrement Y
    void iny() {
        regs.P.setNZ(++regs.Y);
        // Incurs an extra tick
        tick();
    }

    /// ISC/ISB* -- INC + SBC
    void isc() {
        ubyte value = readBus(addrLine);
        sbc(++value);
        // ALU operation incurs a tick
        tick();
        writeBus(addrLine, value);
    }

    /// JMP -- JuMP to address from immediate value (not directly used by interpreter)
    void jmp(addr address) {
        regs.PC = address;
    }

    /// JMP -- JuMP to address on address line
    void jmp() {
        // No extra ticks incurred
        jmp(addrLine);
    }

    @("JMP")
    unittest {
        auto cpu = new CPU();
        cpu.jmp(0x1F0F);
        assert(cpu.regs.PC == 0x1F0F);
    }

    /// helper function for operating the CPU stack
    void pushStack(bool doTick=true, bool yield=true)(ubyte value) {
        writeBus!(doTick,yield)(CPU_STACK_ADDR + regs.S--, value);
    }

    /// helper function for operating the CPU stack
    ubyte popStack(bool doTick=true, bool yield=true)() {
        return readBus!(doTick,yield)(CPU_STACK_ADDR + (++regs.S));
    }

    /// JSR -- Jump to Sub-Routine with given address (NOT used directly by interpreter)
    void jsr(addr address) {
        pushStack(regs.PCH);
        pushStack(regs.PCL);
        jmp(address);
    }

    /// JSR -- Jump to Sub-Routine from address on address line
    void jsr() {
        /*
            For reference, from: https://www.nesdev.org/6502_cpu.txt
            JSR

            #  address R/W description
           --- ------- --- -------------------------------------------------
            1    PC     R  fetch opcode, increment PC
            2    PC     R  fetch low address byte, increment PC
            3  $0100,S  R  internal operation (predecrement S?)
            4  $0100,S  W  push PCH on stack, decrement S
            5  $0100,S  W  push PCL on stack, decrement S
            6    PC     R  copy low address byte to PCL, fetch high address
                           byte to PCH
         */

        // There appears to be some kind of dummy operation during JSR that incurs
        // an extra tick (#3)

        tick();
        // JSR (when invoked by interpreter) is unique -- it doesn't actually advance
        // PC when reading the high byte of the target address in absolute mode, but
        // instead it advances _after_ restoring PC from stack during RTS, so the value
        // of PC written to the stack is actually one less than the address of the next
        // instruction.
        // Rather than try to bypass the interpreter pipeline for this special Absolute mode,
        // we can attempt to compromise on accuracy and 'fudge' it by simply decrementing
        // PC here (and incrementing it during RTS)
        --regs.PC;
        pushStack(regs.PCH);
        pushStack(regs.PCL);
        jmp(addrLine);
        //jsr(addrLine);
    }

    // TODO: Unit test JSR

    /// LAX* -- LDA + LDX
    void lax() {
        ubyte value = readBus(addrLine);
        lda(value);
        ldx(value);
    }

    /// LDA -- LoaD Accumulator (implementation)
    void lda(ubyte operand) {
        regs.A = operand;
        regs.P.setNZ(regs.A);
    }

    /// LDA -- LoaD Accumulator (immediate mode)
    void ldaI() {
        lda(dataLine);
    }

    /// LDA -- LoaD Accumulator with contents of memory address
    void ldaM() {
        lda(readBus(addrLine));
    }

    /// LDX -- LoaD X (implementation)
    void ldx(ubyte operand) {
        regs.X = operand;
        regs.P.setNZ(regs.X);
    }

    /// LDX -- LoaD X (immediate mode)
    void ldxI() {
        ldx(dataLine);
    }

    /// LDX -- LoaD X with contents of memory address
    void ldxM() {
        ldx(readBus(addrLine));
    }

    /// LDY -- LoaD Y (implementation)
    void ldy(ubyte operand) {
        regs.Y = operand;
        regs.P.setNZ(regs.Y);
    }

    /// LDY -- LoaD Y (immediate mode)
    void ldyI() {
        ldy(dataLine);
    }

    /// LDY -- LoaD Y with contents of memory address
    void ldyM() {
        ldy(readBus(addrLine));
    }

    /// LSR -- Logical Shift Right (implementation)
    ubyte lsr(ubyte operand) {
        ubyte result = (operand >>> 1) & 0x7F;
        regs.P.C = (operand & 0x01) > 0;
        regs.P.setNZ(result);
        return result;
    }

    /// LSR on Accmulator
    void lsrA() {
        regs.A = lsr(regs.A);
        // ALU operation incurs a tick
        tick();
    }

    /// LSR on memory address
    void lsrM() {
        ubyte value = readBus(addrLine);
        // There's actually a phantom write of the unprocessed value back to the
        // address its read from at the same time as the ALU operation, but is omitted
        // here because it is moot
        // Instead just tick manually
        tick();
        value = lsr(value);
        writeBus(addrLine, value);
    }

    @("LSR")
    unittest {
        auto cpu = new CPU();
        ubyte result = cpu.lsr(0b10101011);
        assert(result == 0b01010101);
        assert(cpu.regs.P.C);
        assert(!cpu.regs.P.N);
        assert(!cpu.regs.P.Z);

        result = cpu.lsr(0b00000001);
        assert(result == 0 && cpu.regs.P.C && cpu.regs.P.Z && !cpu.regs.P.N);

        result = cpu.lsr(0b00010000);
        assert(result == 0b00001000 && !cpu.regs.P.C && !cpu.regs.P.Z && !cpu.regs.P.N);
    }

    /// NOP -- No OPeration
    void nop(bool doTick=false)() {
        // do nothing!
        // but incur a tick (pending template argument) --
        // the 'official' NOP (0xEA) is an implied mode op, so the manual tick here is necessary --
        // but all the 'unofficial' NOPs use other address modes, in which case no extra tick
        // should be performed, since processing the address mode will tick for us.
        static if(doTick)
            tick();
    }

    /// ORA -- logical inclusive OR of Accumulator (implementation)
    void ora(ubyte operand) {
        regs.A = regs.A | operand;
        regs.P.setNZ(regs.A);
    }

    /// ORA -- logical inclusive OR with Accumulator (immediate mode)
    void oraI() {
        ora(dataLine);
    }

    /// ORA -- logical inclusive OR of Accumulator with a memory sourced value
    void oraM() {
        ora(readBus(addrLine));
    }

    /*
        For reference, from: https://www.nesdev.org/6502_cpu.txt
        PHA, PHP

        #  address R/W description
       --- ------- --- -----------------------------------------------
        1    PC     R  fetch opcode, increment PC
        2    PC     R  read next instruction byte (and throw it away)
        3  $0100,S  W  push register on stack, decrement S
     */

    /// PHA -- PusH Accumulator
    void pha() {
        // PHA incurs a dummy tick after decode
        tick();
        pushStack(regs.A);
    }

    /// PHP -- PusH Processor status
    void php() {
        // PHP incurs a dummy tick after decode
        tick();
        // B flag is always set in the value pushed by
        // php
        pushStack(regs.P.P | ProcessorStatus.Flags.BREAK | ProcessorStatus.Flags.RESERVED);
    }

    /*
        For reference, from: https://www.nesdev.org/6502_cpu.txt
        PLA, PLP

        #  address R/W description
       --- ------- --- -----------------------------------------------
        1    PC     R  fetch opcode, increment PC
        2    PC     R  read next instruction byte (and throw it away)
        3  $0100,S  R  increment S
        4  $0100,S  R  pull register from stack
    */

    /// PLA -- PulL Accumulator
    void pla() {
        // PLA incurs a dummy tick between instruction decode and reading stack (#2)
        tick();
        // There's actually a tick for ALU operation of incrementing S prior to reading (#3),
        // but we do both at the same time, so just add another tick here
        tick();
        regs.A = popStack();
        // PLA affects N/Z status flags
        regs.P.setNZ(regs.A);
    }

    /// PLP -- PulL Processor status
    void plp() {
        // PLP incurs a dummy tick between instruction decode and reading stack
        tick();
        // When pulling the processor flags, the Break and Reserved flags
        // are ignored (they don't 'exist') in the actual register, but
        // the Reserved flag is instead always set and the Break flag is always
        // clear
        with(ProcessorStatus.Flags)
            regs.P.P = (popStack() & ~BREAK) | RESERVED;
        // There's actually a tick for ALU operation to increment S prior to reading,
        // but we do both at the same time, so just add another tick here
        tick();
    }

    /// RLA* -- ROL + AND
    void rla() {
        ubyte value = readBus(addrLine);
        ubyte result = rol(value);
        and(result);
        // Operation incurs an extra tick during ALU ops / premature write
        tick();
        writeBus(addrLine, result);
    }

    /// ROL -- ROtate Left (implementation)
    ubyte rol(ubyte operand) {
        ubyte result = cast(ubyte)(((operand << 1) + (regs.P.C ? 1 : 0)) & 0xFF);
        regs.P.C = (operand & 0x80) > 0;
        regs.P.setNZ(result);
        // ALU operation requires a tick
        //tick();
        return result;
    }

    /// ROL -- ROtate Left on Accumulator
    void rolA() {
        regs.A = rol(regs.A);
        // ALU operation incurs a tick
        tick();
    }

    /// ROL -- ROtate Left the contents of a memory address
    void rolM() {
        ubyte value = readBus(addrLine);
        value = rol(value);
        // ALU operation incurs a tick
        tick();
        writeBus(addrLine, value);
    }

    @("ROL")
    unittest {
        auto cpu = new CPU();
        ubyte result = cpu.rol(0b11010011);
        assert(result == 0b10100110);
        assert(cpu.regs.P.C);
        assert(!cpu.regs.P.Z);
        assert(cpu.regs.P.N);

        cpu.regs.P.C = true;
        result = cpu.rol(0b00001000);
        assert(result == 0b00010001);
        assert(!cpu.regs.P.C);
        assert(!cpu.regs.P.Z);
        assert(!cpu.regs.P.N);
    }

    /// ROR -- ROtate Right (consolidated implementation)
    ubyte ror(ubyte operand) {
        ubyte result = cast(ubyte)(((operand >> 1) + (regs.P.C ? 0x80 : 0)) & 0xFF);
        regs.P.C = (operand & 0x01) > 0;
        regs.P.setNZ(result);
        return result;
    }

    /// ROR -- ROtate Right the Accumulator
    void rorA() {
        regs.A = ror(regs.A);
        // ALU operation incurs a tick
        tick();
    }

    /// ROR -- ROtate Right the contents of a memory address
    void rorM() {
        ubyte value = readBus(addrLine);
        value = ror(value);
        // ALU operation incurs a tick
        tick();
        writeBus(addrLine, value);
    }

    @("ROR")
    unittest {
        auto cpu = new CPU();
        ubyte result = cpu.ror(0b01010101);
        assert(result == 0b00101010);
        assert(cpu.regs.P.C && !cpu.regs.P.Z && !cpu.regs.P.N);

        result = cpu.ror(result);
        assert(result == 0b10010101);
        assert(!cpu.regs.P.C && !cpu.regs.P.Z && cpu.regs.P.N);
    }

    /// RRA* -- ROR + ADC
    void rra() {
        ubyte value = readBus(addrLine);
        ubyte result = ror(value);
        adc(result);
        // ALU operation incurs a tick
        tick();
        writeBus(addrLine, result);
    }

    /// RTI -- ReTurn from Interrupt
    void rti() {
        /*
            For reference, from: https://www.nesdev.org/6502_cpu.txt
            RTI

            #  address R/W description
           --- ------- --- -----------------------------------------------
            1    PC     R  fetch opcode, increment PC
            2    PC     R  read next instruction byte (and throw it away)
            3  $0100,S  R  increment S
            4  $0100,S  R  pull P from stack, increment S
            5  $0100,S  R  pull PCL from stack, increment S
            6  $0100,S  R  pull PCH from stack
         */

        if(!inInterrupt) {
            // TODO: Log odd behavior (?)
        }

        // Dummy tick between decode and operation (#2 above)
        //readPC!false();
        tick();
        // Another tick incurred while incrementing S (#3), but we do it at the same time in
        // popStack, so just add another tick here
        tick();
        // Pop status flags off stack, ensuring that B flag is always clear, and R flag
        // is always set.
        regs.P.P = (popStack() & ~ProcessorStatus.Flags.BREAK) | ProcessorStatus.Flags.RESERVED;
        regs.PCL = popStack();
        regs.PCH = popStack();
        inInterrupt = false;
    }

    // TODO: Unit test RTI once bus is functional

    /// SAX* -- Store A & X into memory
    void sax() {
        ubyte result = regs.X & regs.A;
        writeBus(addrLine, result);
    }

    /// RTS -- ReTurn from Subroutine
    void rts() {
        /*
            For reference, from: https://www.nesdev.org/6502_cpu.txt
            RTS

            #  address R/W description
           --- ------- --- -----------------------------------------------
            1    PC     R  fetch opcode, increment PC
            2    PC     R  read next instruction byte (and throw it away)
            3  $0100,S  R  increment S
            4  $0100,S  R  pull PCL from stack, increment S
            5  $0100,S  R  pull PCH from stack
            6    PC     R  increment PC
         */
        // Dummy read / tick between decode and operation (#2)
        tick();
        // Dummy tick to increment S (#3), which we do during popStack(),
        // so just add another tick here
        tick();
        regs.PCL = popStack();
        regs.PCH = popStack();
        // Manually increment PC -- the address on the stack is actually the address of the last
        // byte of the JSR that lead here, rather than the address of the next instruction
        // this also incurs a tick (#6)
        ++regs.PC;
        tick();
    }

    // TODO: Unit test RTS once bus operational

    /// SBC -- SuBtract with Carry value from Accumulator (implementation)
    void sbc(ubyte operand) {
        // interpretation of carry is inverted relative to ADC
        //short result = cast(short)(regs.A - operand - (regs.P.C ? 0 : 1));
        //if(result > 127 || result < -128) {
        //    // overflow
        //    result.P.C = true
        //}
        //regs.P.setNZ(cast(ubyte)(result & 0xFF));
        // TODO: Finish me
        // RE: Overflow & carry flags
        // ALU operation incurs tick
        //tick();

        // SBC is the same as ADC with ones complement of operand
        adc(ub(~operand));
    }

    /// SBC -- SuBtract with Carry an immediate value
    void sbcI() {
        sbc(dataLine);
    }

    /// SBC -- SuBtract with Carry a memory-sourced value
    void sbcM() {
        sbc(readBus(addrLine));
    }

    // TODO: Unit test SBC

    /// SEC -- SEt Carry flag
    void sec() {
        regs.P.C = true;
        // ALU operation incurs tick
        tick();
    }

    /// SED -- SEt Decimal flag
    void sed() {
        regs.P.D = true;
        // ALU operation incurs tick
        tick();
    }

    /// SEI -- SEt Interrupt disable flag
    void sei() {
        regs.P.I = true;
        // ALU operation incurs tick
        tick();
    }

    /// SLO* -- ASL + ORA
    void slo() {
        ubyte value = readBus(addrLine);
        ubyte result = asl(value);
        ora(result);
        // ALU operation incurs a tick
        tick();
        writeBus(addrLine, result);
    }

    /// SRE* -- LSR + EOR
    void sre() {
        ubyte value = readBus(addrLine);
        ubyte result = lsr(value);
        eor(result);
        // ALU operation incurs a tick
        tick();
        writeBus(addrLine, result);
    }

    /// STA -- STore Accumulator in memory
    void sta() {
        writeBus(addrLine, regs.A);
    }

    /// STX -- STore X in memory
    void stx() {
        writeBus(addrLine, regs.X);
    }

    /// STY -- STore Y in memory
    void sty() {
        writeBus(addrLine, regs.Y);
    }

    /// TAX -- Transfer Accumulator to X
    void tax() {
        regs.X = regs.A;
        regs.P.setNZ(regs.X);
        // Operation incurs tick
        tick();
    }

    /// TAY -- Transfer Accumulator to Y
    void tay() {
        regs.Y = regs.A;
        regs.P.setNZ(regs.Y);
        // Operation incurs tick
        tick();
    }

    /// TSX -- Transfer Stack pointer to X
    void tsx() {
        regs.X = regs.S;
        regs.P.setNZ(regs.X);
        // Operation incurs tick();
        tick();
    }

    /// TXA -- Transfer X to Accumulator
    void txa() {
        regs.A = regs.X;
        regs.P.setNZ(regs.A);
        // Operation incurs tick
        tick();
    }

    /// TXS -- Transfer X to Stack pointer
    void txs() {
        regs.S = regs.X;
        // Operation incurs tick
        tick();
    }

    /// TYA -- Transfer Y to Accumulator
    void tya() {
        regs.A = regs.Y;
        regs.P.setNZ(regs.A);
        // Operation incurs tick
        tick();
    }

    string disassemblePC() {
        ubyte opcode = readBus!(false,false)(regs.PC);
        auto opdef = lookupOpcode(opcode);
        auto opBytes = getOpcodeSize(opdef.mode);
        ubyte[] instr = [opcode];
        if(opBytes > 1)
            instr ~= readBus!(false,false)((regs.PC+1) & 0xFFFF);
        if(opBytes > 2)
            instr ~= readBus!(false,false)((regs.PC+2) & 0xFFFF);
        string[] lines = disassemble(instr, regs.PC);
        assert(lines.length == 1);
        return lines[0];
    }

    static string[] disassemble(in ubyte[] prg, in addr baseAddr = 0) {
        string[] result = [];
        addr offset = baseAddr;
        auto i = prg.ptr, end = prg.ptr+prg.length;
        while(i < end) {
            auto opcode = *i++;
            auto opdef = lookupOpcode(opcode);
            ushort arg;
            auto argBytes = getOpcodeSize(opdef.mode);
            if(argBytes > 1)
                arg = *i++;
            if(argBytes > 2)
                arg += (*i++ << 8) & 0xFF00;
            auto line = disassembleLine(opdef, arg, offset);
            offset += argBytes;
            result ~= line;
        }
        return result;
    }

    static string formatDisassemblyLine(in addr offset, in ubyte[] rawBytes, in string mnemonic, in string operands, bool illegal=false) {
        string bytecode = rawBytes.map!(x => format("%02X",x)).join(" ");
        char indicator = (illegal ? '*' : ' ');
        return format("%04X  %-10s%c%s %-32s", offset, bytecode, indicator, mnemonic, operands).strip();
    }

    static string disassembleLine(in OpCodeDef opdef, in ushort arg, in addr offset) {
        string mnemonic, operands;
        ubyte[] rawBytes = [opdef.opcode];
        auto numBytes = getOpcodeSize(opdef.mode);
        if(numBytes > 1) {
            rawBytes ~= ub(arg);
        }
        if(numBytes > 2) {
            rawBytes ~= ub(arg >> 8);
        }
        final switch(opdef.mode) {
            case AddressMode.IMPLIED:
                operands = "";
                break;
            case AddressMode.ACCUMULATOR:
                operands = "A";
                break;
            case AddressMode.IMMEDIATE:
                operands = format("#$%02X", ub(arg));
                break;
            case AddressMode.RELATIVE:
                operands = format("%+d", cast(byte)(arg & 0xFF));
                break;
            case AddressMode.ZP_IMMEDIATE:
                operands = format("$%02X", ub(arg));
                break;
            case AddressMode.ZP_X:
                operands = format("$%02X,X", ub(arg));
                break;
            case AddressMode.ZP_Y:
                operands = format("$%02X,Y", ub(arg));
                break;
            case AddressMode.ABSOLUTE:
                operands = format("$%04X", arg);
                break;
            case AddressMode.ABSOLUTE_X:
                operands = format("$%04X,X", arg);
                break;
            case AddressMode.ABSOLUTE_Y:
                operands = format("$%04X,Y", arg);
                break;
            case AddressMode.INDEXED_INDIRECT:
                operands = format("($%02X,X)", ub(arg));
                break;
            case AddressMode.INDIRECT_INDEXED:
                operands = format("($%02X),Y", ub(arg));
                break;
            case AddressMode.INDIRECT:
                operands = format("($%04X)", arg);
                break;
        }
        return formatDisassemblyLine(offset, rawBytes, opdef.mnemonic, operands, opdef.illegal);
    }

    @("Disassmble")
    unittest {
        const ubyte[] prg = [0x00];
        //const string expected = "0000\t00        \tBRK";
        const string expected = CPU.formatDisassemblyLine(0, prg, "BRK", "");
        auto result = CPU.disassemble(prg);
        assert(result != null);
        //writefln("Disassembly:\n\t%s", result);
        assert(result.length == 1);
        assert(result[0] == expected);
    }

private:
    static ref immutable(OpCodeDef) lookupOpcode(ubyte opcode) {
        return *OPCODE_DEFS[opcode];
    }
}
