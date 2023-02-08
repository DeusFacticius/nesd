module bus;

interface Bus(AT, DT) {
    DT read(const AT addr);
    void write(const AT addr, const DT value);
}

alias addr = ushort;

alias NESBus = Bus!(addr, ubyte);

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