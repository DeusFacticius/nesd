module peripheral;

// Although the NES has an expansion port and a few different
// devices that make use of it, sole focus is on standard
// basic NES controllers for now

import std.bitmanip;
import std.typecons;
import std.algorithm.comparison;    // for max()
import util;

union StandardControllerButtons {
    ubyte raw;
    struct {
        mixin(bitfields!(
            bool, "A", 1,
            bool, "B", 1,
            bool, "select", 1,
            bool, "start", 1,
            bool, "up", 1,
            bool, "down", 1,
            bool, "left", 1,
            bool, "right", 1
        ));
    }
}
static assert(StandardControllerButtons.sizeof == ubyte.sizeof);

enum Button: ubyte {
    A = 0x01,
    B = 0x02,
    SELECT = 0x04,
    START = 0x08,
    UP = 0x10,
    DOWN = 0x20,
    LEFT = 0x40,
    RIGHT = 0x80,
}
static assert(isBitFlagEnum!Button);

enum PeripheralPort : ubyte {
    PORT1,
    PORT2,
}

class AbstractPeripheral {
    // TODO: revise member visibility
    PeripheralPort port;
    bool connected;
    bool strobe;
    uint state;
    int reportSizeBits;
    bool defaultOverflowValue;

    this(bool connected, int reportSizeBits, bool defaultOverflowValue, PeripheralPort port=PeripheralPort.PORT1) {
        this.connected = connected;
        this.reportSizeBits = reportSizeBits;
        this.defaultOverflowValue = defaultOverflowValue;
        this.port = port;
    }

    void setStrobe(bool value) {
        if(value && !strobe) {
            // Rising edge
            strobe = value;
            pollInput();
        } else if(strobe && !value) {
            // Falling edge
            pollInput();
            strobe = value;
        }
    }

    bool readAndShift() {
        bool result = (state & 1);
        // Only if strobe is low do we shift the state, otherwise
        // skip because IRL it'd be immediately overwritten
        if(!strobe) {
            // Shift the report state by 1 bit
            state >>= 1;
            // If the default overflow value is high, set the high bit
            // of the report state (otherwise do nothing because arithmetic
            // shift shifts in a 0)
            if(defaultOverflowValue)
                state |= 1 << reportSizeBits;
        }
        return result;
    }

    void pollInput() {
        // If the input is connected, delegate to implementation
        // else, set 0 (as NES expects)
        if(connected)
            updateState();
        else
            state = 0;
    }

    abstract void updateState();
}

class StandardNESController : AbstractPeripheral {
    StandardControllerButtons buttons;

    this(PeripheralPort port=PeripheralPort.PORT1) {
        super(true, 8, true, port);
    }

    override void updateState() {
        readButtons();
        state = buttons.raw;
    }

    abstract void readButtons();
}

class NullPeripheral : AbstractPeripheral {
    this(PeripheralPort port=PeripheralPort.PORT1) {
        super(false, 0, false, port);
    }

    override void updateState() {
        state = 0;
    }
}