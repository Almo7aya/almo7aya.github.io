# almo7aya.dev

My personal site. The home page is a debugger that boots **7OS**, a small real-mode operating
system written in 8086 assembly, on a **PC emulated in JavaScript**. Nothing on the screen is a
recording: the boot sector, the INT 13h disk reads, the filesystem, the timer interrupt that drives
the clock, and the mode 13h demo are real machine code, assembled with NASM and executed one
instruction at a time in your browser. The same `almo7aya.img` boots in QEMU.

```
os/almo7aya.asm      7OS 0.8: boot sector + kernel/shell (NASM, cpu 8086)
os/fs/               files packed into 7FS, the image's filesystem (plus the OS source itself)
os/font/             unscii-16 (public domain), mapped to code page 437 as the VGA font ROM
os/build.mjs         builds public/os/almo7aya.img, public/os/vgafont.bin, src/data/listing.json
os/test.mjs          boots the image headlessly in Node and prints the screen
src/lib/cpu8086.js   the 8086, the PC around it (PIT/IRQ0, VGA ports, ROM) and an HLE BIOS
src/lib/vga.js       draws VGA memory onto a <canvas>: 720x400 text mode, 320x200 mode 13h
src/lib/debugger.js  wires the machine to the windows on the home page
src/pages/           Astro pages: home, posts, reading, about, RSS at /index.xml
src/posts/           blog posts (markdown)
```

## the machine

| part | what's emulated |
| --- | --- |
| CPU | 8086 real mode: every ALU/shift/string/MUL/DIV/BCD op, ModR/M, segment overrides, REP, real IVT vectoring, #UD on `ud2` |
| timer | the PIT fires IRQ0 at 18.2 Hz into INT 08h, whose handler is real code in ROM at `F000:FEA5`: it counts ticks at `0040:006C`, calls INT 1Ch, EOIs the PIC |
| VGA | text mode at `B800:0000` (9×16 cells, line-graphics 9th column, blink, scanline cursor), mode 13h at `A000:0000`, DAC palette on `3C7h-3C9h`, vertical retrace on `3DAh`, 8×16 font ROM at `C000:1000` (INT 10h AX=1130h) |
| BIOS | HLE services behind the classic IBM entry points (`F000:E3FE` disk, `E82E` keyboard, `FE6E` clock...): INT 10h, 11h, 12h, 13h (CHS + LBA), 15h/86h, 16h, 19h, 1Ah. A vector a program replaces is honoured. `FFFF:0000` is a real reset jump |
| speed | ~40 MIPS. the TURBO button (F7) drops it to ~0.33 MIPS, about a 4.77 MHz IBM PC |

## 7OS commands

`help` · `dir` · `type FILE` (or just `about`, `work`, `projects`, `github`, `patches`, `readme`) ·
`type source.asm` (the OS reads its own source off the disk) · `demo` (mode 13h plasma, palette
rotation, font ROM text) · `regs` · `ints` (the IVT, and which vectors 7OS hooked) · `uptime` ·
`time` · `ver` · `clear` · `7` · `panic` · `reboot`

## run it

Needs Node 22+ and [NASM](https://nasm.us) (`scoop install nasm`, `brew install nasm`, `apt install nasm`).

```sh
npm install
npm run dev          # builds 7OS, then starts Astro
npm run test:os      # boot 7OS in Node, type "help work panic", print the screen
npm run build        # static site in dist/
```

## boot 7OS outside the browser

```sh
npm run os
qemu-system-i386 -drive format=raw,file=public/os/almo7aya.img
```

Or `dd` it to a USB stick and boot an old PC in legacy BIOS mode.

## debugger keys

| key | does |
| --- | --- |
| click the screen | attaches the keyboard: type 7OS commands |
| F5 | go / break |
| F8 | trace one instruction |
| F9 | breakpoint at the current instruction (or click a line's gutter) |
| F7 | turbo on / off |
| F2 | reboot |

From DevTools: `sevenOS.machine` is the PC, `sevenOS.type('dir\r')` types, `sevenOS.run(1e6)` steps.

## credits

The panicking girl is the site mascot. The VGA font ROM is
[unscii-16](http://viznut.fi/unscii/) by viznut, public domain.
