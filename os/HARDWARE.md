# the almo7aya.dev PC

Every disk in `os/programs/*` must run the same on this emulator (`src/lib/cpu8086.js`) and on
QEMU + SeaBIOS. Only use what is listed here.

## CPU

- **8086 real mode only.** Start every program with `cpu 8086` / `bits 16` / `org 0x7C00`.
  NASM then rejects 186+ instructions (no `pusha`, `shl ax, 4`, `push imm`, `imul r, imm`).
- No FPU. Integer and fixed-point maths only.
- `0F 0B` (`ud2`) raises #UD and stops the emulator (the debugger shows the girl panicking).
- Speed: ~40 MIPS in the browser (TURBO on), ~0.33 MIPS with TURBO off. Pace animation with the
  timer or vertical retrace, never with busy loops.

## boot

- The BIOS loads sector 0 to `0000:7C00` and jumps there with `DL` = boot drive
  (`80h` hard disk, `00h` floppy). Signature `55 AA` at offset 510.
- Load the rest of your program yourself with INT 13h (see `os/programs/7os/main.asm`).
- `program.json`: `"drive": "hdd"` (image = whole sectors) or `"floppy"` (padded to 1.44 MB,
  80 cyl × 2 heads × 18 spt). Use INT 13h AH=08h to get the geometry, don't hardcode it.

## BIOS services (high-level emulated, also in SeaBIOS)

| INT | functions |
| --- | --- |
| 10h | 00h set mode (03h text 80×25, 13h 320×200×256), 02h/03h cursor, 06h/07h scroll, 08h/09h/0Ah char, 0Ch/0Dh pixel, 0Eh teletype, 0Fh get mode, 10h/10h,12h,15h DAC, 11h/30h font pointer (BH=06h → ES:BP = 8×16 font), 13h string, 1Ah display combo |
| 11h, 12h | equipment, memory size (640 KB) |
| 13h | 00h reset, 01h status, 02h read, 03h write, 04h verify, 08h params, 15h type, 41h/42h/43h LBA extensions (hard disk only) |
| 15h | 86h wait CX:DX µs, C2xxh PS/2 mouse (below), 88h → 0 |
| 16h | 00h/10h wait key (AL ascii, AH scan), 01h/11h peek (ZF=1 none), 02h shift flags, 05h stuff key |
| 19h | reboot from disk |
| 1Ah | 00h ticks since midnight, 02h RTC time (BCD), 04h RTC date (BCD) |

Vectors point at the classic IBM entry points (`F000:E3FE` disk, `F000:E82E` keyboard, ...).
A vector you replace in the IVT is honoured exactly like real hardware.

## hardware

- **Timer (8253 PIT, port 40h-43h).** Channel 0 fires IRQ0 at 18.2 Hz by default; reprogram it
  (mode 3, `out 43h, 36h` then the 16-bit divisor to port 40h, low byte first) for other rates.
  IRQ0 → INT 08h, whose ROM handler counts ticks at `0040:006C`, calls **INT 1Ch** (hook this for
  a per-tick callback) and sends EOI. If you hook INT 08h yourself, send `out 20h, 20h` (EOI) or
  chain to the old vector. Reading a counter (latch with `out 43h, 00h`) works.
- **PIC (8259, port 20h/21h).** Mask register on 21h. EOI = `out 20h, 20h`.
- **Keyboard.** By default the BIOS buffers keys (INT 16h). If you hook **INT 09h**, every key
  press and release raises **IRQ1**: read the scan code from port **60h** (bit 7 set = release),
  then EOI (`out 20h, 20h`) or chain to the old INT 09h. Scan codes are XT set 1:
  Esc 01h, 1-0 02h-0Bh, Q 10h, A 1Eh, Z 2Ch, Space 39h, Enter 1Ch, Ctrl 1Dh, LShift 2Ah, Alt 38h,
  F1-F10 3Bh-44h, Up 48h, Left 4Bh, Right 4Dh, Down 50h. Games that need held keys must use this.
- **Mouse: INT 15h AX=C2xxh** (the BIOS PS/2 interface). C201h reset, C205h init (BH=3),
  C207h set handler (ES:BX), C200h enable (BH=1). On every movement the BIOS far-calls your
  handler with, on the stack: `[sp+4]=0, [sp+6]=Y delta, [sp+8]=X delta, [sp+10]=status`
  (status: bit0 left, bit1 right, bit3 always 1, bit4 X negative, bit5 Y negative). Deltas are
  9-bit two's complement using the sign bits; Y grows **upwards**. The handler must preserve all
  registers and return with `retf`. Clamp and track the cursor yourself, and draw it yourself.
- **PC speaker.** PIT channel 2 square wave (`out 43h, 0B6h`, divisor = 1193182 / Hz to port 42h)
  and port **61h** bits 0+1 to enable (`in al, 61h / or al, 3 / out 61h, al`, `and al, 0FCh` to stop).
  The browser plays it through Web Audio.
- **VGA.** Text: `B800:0000`, 80×25, char+attribute words, CP437 font. Mode 13h: `A000:0000`,
  320×200, one byte per pixel. DAC: `out 3C8h, index` then R, G, B (0-63 each) to `3C9h`.
  Vertical retrace: `3DAh` bit 3 (70 Hz). The 8×16 font ROM is at the pointer INT 10h AX=1130h,
  BH=06h returns (256 glyphs × 16 bytes).
- **CMOS RTC** on ports 70h/71h (BCD time and date).
- **Disk writes** (INT 13h AH=03h) change this session's copy of the image only.

## tools

```sh
node os/build.mjs <id>                     # assemble one disk (npm run os builds all)
node os/run.mjs <id> wait:2000 png:a.png   # boot it headlessly, script keys/mouse, take PNG shots
node os/run.mjs <id> "type:hello\n" key:space down:right wait:500 up:right mouse:400,100,1 text regs speaker
```

QEMU check (Windows): `os/qemu-shot.ps1` boots the image headless, types with `sendkey`, moves the
mouse with `mouse_move`, saves PNG screenshots.
