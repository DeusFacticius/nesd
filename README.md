# NESD

A hobby-project emulator for the Nintendo Entertainment System (NES) written in D / Dlang.

### Purpose

This project is both intended as an exercise to better learn and hone my grasp of D language, as well as provide a technical challenge to accurately and efficiently emulate a tricky platform that is the NES.

### Forewarnings

* There simply aren't any decent modern IDEs for Dlang on OSX. The Dlang plugin for IntelliJ has numerous issues (at least on OSX), even though it (attempts and fails) to leverage mature tools like DScanner, DCD, DFix, and DFmt. The impact is that much of this code has been written with almost no coding assistance beyond syntax highlighting (and even that doesn't work properly most of the time).
  * In addition, integrated (IDE) debugging doesn't work. Although it's possible to debug directly with GDB from a terminal, this can be incredibly tedious given the nature of the project, and that debugging with conditional compilation of extra print statements is often faster, albeit messy.
* This is a _hobby_ project. Although professionally, I consider myself to have a fairly low tolerance for 'slop', I've allowed myself more here than usual, but only because:
  * I anticipate I will be the only one to ever work on this code
  * I can only work on it in spare time / time investment is limited.
  * Despite the great references available, there are still many details regarding the inner workings of the NES that are either vague, undocumented, conflicting, or even wrong. This necessitates doing a lot of trial-and-error tweak/test exploration than ideal.
  
  As such, there's less than ideal documentation / comments, and more hard-coding, pidgeonholed designs / concepts, and even 'magic constants' (which I almost never tolerate).

### References

* The invaluable NES reference guide wiki: https://www.nesdev.org/wiki/NES_reference_guide
* Christopher Pow's NES test roms: https://github.com/christopherpow/nes-test-roms

### High Level overview / status

* 6502 CPU emulation
  * Experimental use of fibers (coroutines) to simulate granular per-cycle operation
    * Status -- Functional (with a few cheats here and there), but  may ultimately be dropped for performance reasons. Most emulators don't seem to support this level of granularity,
    and while fibers seem like a good fit for reducing the complexity that would otherwise be necessary, the overhead they introduce may not justify the potential accuracy.
* PPU emulation
  * Functional, albeit with some cheese:
    * Bus address / data line multiplexing via ALE (Address Line Enable) triggered octal latch (and resulting two-cycles-per-bus-operation) isn't emulated (yet); thus resulting quirks like open-bus / open-collector effects aren't simulated properly.
  * Still some sprite / OAM quirks yet to be tested / simulated (e.g. sprite overflow
  bugs that exist in real hardware, and some games expect).
  * Sub-frame behavior of some mechanisms to be refined / investigated
* APU
  * Currently only stubbed out, not implemented at all yet.
* Mappers
  * NROM
    * Still some ambiguities surrounding details of PRG RAM size / presence / configuration.
    * Ditto ^, Re: CHR ROM vs. RAM. SMB uses NROM, but attempts to write to pattern tables.
  * No other mappers supported yet.
* ROM file support
  * Currently only iNES 1.0 format implemented
    * iNES 2.0 format is backwards compatible with iNES 1.0 though, so while iNES 2.0 can
    be read / used, implementation doesn't currently utilize the additional features
    provided by newer format.
* SDL2 used for presentation layer
  * Theoretically portable / cross-platform with no code-changes, but so far only
  developed and tested on intel OSX.

### Development Operations

#### Build

```shell
dub build -b debug -v
```

#### Build & run unit tests

Optionally configure dub.json to enable / disable some unit tests guarded by
conditional compilation (e.g. `version` scopes).

```shell
dub test -- -v -t 1
```

OR

```shell
./test.sh
```

#### Run

Dub will automatically perform a build if necessary.

```shell
dub run -b debug -- <path/to/romfile.nes>
```

OR

```shell
./run.sh [path/to/romfile.nes]
```


