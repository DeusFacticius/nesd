import bindbc.sdl;

import std.stdio;
import std.file;
import std.array;
import std.string;
import rom;
import emu;

private string romFilename;

void parseArgs(string[] args) {
	if(args.length > 0) {
		string arg = args[0];
		writefln("Attempting to load file: %s", arg);
		if(exists(arg)) {
			writefln("File exists, loading...");
			//auto rom = new NESFile(arg);
			//writeln("PRG ROM bank 1: ");
			//auto lines = CPU.disassemble(rom.prgRomBanks[1], 0xC000);
			//writeln(lines.join("\n"));
			romFilename = arg;
		}
	}
}

void printUsage(in string appName) {
	writefln("Usage: %s <romfile>", appName);
}

debug(audiodiag) {
	void doAudioDiag() {
		import sdl_wrapper;
		import bindbc.sdl;

		InitSDL(SDL_INIT_TIMER | SDL_INIT_EVENTS | SDL_INIT_AUDIO);

		SDL_AudioSpec desired, obtained;
		desired.freq = 44100;
		desired.format = AUDIO_F32SYS;
		desired.channels = 1;
		sdlEnforce(SDL_OpenAudio(&desired, &obtained));

		writefln("Desired audio: %s", desired);
		writefln("Obtained audio: %s", obtained);
	}
}

version(unittest) {

} else {
	int main(string[] args)
	{
		debug(audiodiag) {
			doAudioDiag();
			//return 0;
		}

		writefln("Args: %s", args);
		if(args && args.length > 1)
			parseArgs(args[1..$]);
		else {
			printUsage(args[0]);
			return -1;
		}

		if(!romFilename) {
			printUsage(args[0]);
			return -1;
		}

		try {
			auto app = new EmulatorApp();
			app.loadROM(romFilename);

			app.run();
			return 0;
		} catch(Exception ex) {
			stderr.writefln("Exception: %s (%s) ", ex, ex.msg);
			stderr.writefln("*****: SDL_GetError(): %s", SDL_GetError().fromStringz());
			return -2;
		}
	}
}

