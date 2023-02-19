module util;

import std.traits;
import std.range;
import std.algorithm;
import std.math;

pure int getBit(int value, int bit) {
    pragma(inline);
    return (value >> bit) & 1;
}

@("getBit")
unittest {
    immutable ubyte V = 0b10010001;
    assert(getBit(V,0) == 1);
    assert(getBit(V,1) == 0);
    assert(getBit(V,2) == 0);
    assert(getBit(V,3) == 0);
    assert(getBit(V,4) == 1);
    assert(getBit(V,5) == 0);
    assert(getBit(V,6) == 0);
    assert(getBit(V,7) == 1);
}

pure N narrow(N,T)(T value) if(isIntegral!N && isIntegral!T && !isSigned!N) {
    return cast(N)(value & N.max);
}

pure ubyte ub(T)(T value) if(isIntegral!T) {
    return cast(ubyte)(value & 0xFF);
}

private immutable ubyte[16] _NIBBLE_REVERSE = [
    0,      // 0 = 0000 -> 0000 (0)
    0x8,    // 1 = 0001 -> 1000 (8)
    0x4,    // 2 = 0010 -> 0100 (4)
    0xC,    // 3 = 0011 -> 1100 (C)
    0x2,    // 4 = 0100 -> 0010 (2)
    0xA,    // 5 = 0101 -> 1010 (A)
    0x6,    // 6 = 0110 -> 0110 (6)
    0xE,    // 7 = 0111 -> 1110 (E)
    0x1,    // 8 = 1000 -> 0001 (1)
    0x9,    // 9 = 1001 -> 1001 (9)
    0x5,    // A = 1010 -> 0101 (5)
    0xD,    // B = 1011 -> 1101 (D)
    0x3,    // C = 1100 -> 0011 (3)
    0xB,    // D = 1101 -> 1011 (B)
    0x7,    // E = 1110 -> 0111 (7)
    0xF,    // F = 1111 -> 1111 (F)
];

pure ubyte reverseBits(in ubyte v) {
    return ((_NIBBLE_REVERSE[v & 0xF] << 4) | (_NIBBLE_REVERSE[v >> 4])) & 0xFF;
}

@("reverseBits")
unittest {
    assert(reverseBits(0) == 0);
    assert(reverseBits(0b11111111) == 0b11111111);
    assert(reverseBits(0b01111111) == 0b11111110);
    //assert(reverseBits(0xCA) == 0x53)
    assert(reverseBits(0b11001010) == 0b01010011);
    assert(reverseBits(0b11100001) == 0b10000111);
}

@("Bool")
unittest {
    // Misc. assertions about how D lang behaves Re: bools & ints
    int t = true, b = false;
    assert(t == 1);
    assert(b == 0);
    assert(1);  // assert non-zero values are true
    assert(!0); // assert zero values are false
}

struct CircularBuffer(T, size_t size) {
    T[size] buffer;
    size_t pos;

    alias ElementType = T;

    void put(in T value) {
        buffer[pos++ % size] = value;
    }

    @property T front() const {
        assert(pos > 0, "Attempted to fetch front of empty buffer");
        return buffer[(pos-1) % size];
    }

    @property bool empty() const {
        return pos <= 0;
    }

    @property size_t length() const {
        return min(pos, size);
    }

    @property position() const {
        return pos;
    }

    @property localPosition() const {
        return pos % size;
    }

    void clear() {
        pos = 0;
        buffer[] = buffer.init[];
    }

    auto reader() const {
        // chain the front of buffer (write head -> end) to the back of the buffer (start -> write head)
        // unless write head hasn't wrapped yet, in which case it is just start -> write head
        if(pos < size) {
            // we have to use an empty range at the head to keep the return types the same, as chain() otherwise
            // aliases to the type of the first input if only one input given
            return chain(buffer[0..0], buffer[0..pos]);
        } else {
            return chain(buffer[localPosition..$], buffer[0..localPosition]);
        }
    }
}

struct FixedPoint(T, uint bits) if(isIntegral!T && 8*T.sizeof >= bits) {
    T value;

    this(float f) {
        value = cast(T)(round(f * exp2(bits)));
    }

    alias value this;
}

struct FixedSizeBuffer(T, size_t size) {
    alias FlushListener = void delegate(in T[] buf);

    T[size] buffer;
    size_t pos;
    FlushListener listener;

    void put(in T value) {
        assert(pos >= 0 && pos < buffer.length);
        buffer[pos++] = value;
        if(pos >= buffer.length)
            flush();
    }

    void reset(bool clear=false)() {
        pos = 0;
        static if(clear) {
            buffer[] = buffer.init;
        }
    }

    void flush() {
        if(pos > 0 && listener) {
            listener(buffer[0..pos]);
        }
        reset();
    }
}
