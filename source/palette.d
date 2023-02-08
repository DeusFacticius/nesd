module palette;

struct RGB {
    this(ubyte r, ubyte g, ubyte b) {
        red = r;
        green = g;
        blue = b;
    }
    //union {
    //    ubyte[3] values;
    //    struct {
    ubyte red;
    ubyte green;
    ubyte blue;
    //}
    //}
}
static assert(RGB.sizeof == 3*ubyte.sizeof);
//static assert(RGB.red.offsetof == RGB.values[0].offsetof);

shared immutable RGB[64] RGB_LUT = [
    // Row 0 (0x0X)
    RGB(    84, 84, 84  ),  //  0x00
    RGB(    0,  30, 116 ),  //  0x01
    RGB(    8,  16, 144 ),  //  0x02
    RGB(    48, 0,  136 ),  //  0x03
    RGB(    68, 0,  100 ),  //  0x04
    RGB(    92, 0,  48  ),  //  0x05
    RGB(    84, 4,  0   ),  //  0x06
    RGB(    60, 24, 0   ),  //  0x07
    RGB(    32, 42, 0   ),  //  0x08
    RGB(    8,  58, 0   ),  //  0x09
    RGB(    0,  64, 0   ),  //  0x0A
    RGB(    0,  60, 0   ),  //  0x0B
    RGB(    0,  50, 60  ),  //  0x0C
    RGB(    0,  0,  0   ),  //  0x0D
    // 'Mirrors of 0x1D'
    RGB(    0,  0,  0   ),  //  0x0E
    RGB(    0,  0,  0   ),  //  0x0F

    // Row 1 (0x1X)
    RGB(    152,    150,    152 ),
    RGB(    8,  76, 196 ),
    RGB(    48, 50, 236 ),
    RGB(    92, 30, 228 ),
    RGB(    136,    20, 176 ),
    RGB(    160,    20, 100 ),
    RGB(    152,    34, 32  ),
    RGB(    120,    60, 0   ),
    RGB(    84, 90, 0   ),
    RGB(    40, 114,    0   ),
    RGB(    8,  124,    0   ),
    RGB(    0,  118,    40  ),
    RGB(    0,  102,    120 ),
    RGB(    0,  0,  0   ),
    // 'Mirrors of 0x1D'
    RGB(    0,  0,  0   ),
    RGB(    0,  0,  0   ),

    // Row 2 (0x2X)
    RGB(    236,    238,    236 ),
    RGB(    76, 154,    236 ),
    RGB(    120,    124,    236 ),
    RGB(    176,    98, 236 ),
    RGB(    228,    84, 236 ),
    RGB(    236,    88, 180 ),
    RGB(    236,    106,    100 ),
    RGB(    212,    136,    32  ),
    RGB(    160,    170,    0   ),
    RGB(    116,    196,    0   ),
    RGB(    76, 208,    32  ),
    RGB(    56, 204,    108 ),
    RGB(    56, 180,    204 ),
    RGB(    60, 60, 60  ),
    // 'Mirrors of 0x1D'
    RGB(    0,  0,  0   ),
    RGB(    0,  0,  0   ),

    // Row 3 (0x3X)
    RGB(	236,	238,	236	),
    RGB(	168,	204,	236	),
    RGB(	188,	188,	236	),
    RGB(	212,	178,	236	),
    RGB(	236,	174,	236	),
    RGB(	236,	174,	212	),
    RGB(	236,	180,	176	),
    RGB(	228,	196,	144	),
    RGB(	204,	210,	120	),
    RGB(	180,	222,	120	),
    RGB(	168,	226,	144	),
    RGB(	152,	226,	180	),
    RGB(	160,	214,	228	),
    RGB(	160,	162,	160	),
    // 'Mirrors of 0x1D'
    RGB(    0,  0,  0   ),
    RGB(    0,  0,  0   ),
];
static assert(RGB_LUT.sizeof == 64*3*ubyte.sizeof);
static assert(RGB_LUT[61].red == 160 && RGB_LUT[61].green == 162 && RGB_LUT[61].blue == 160);
