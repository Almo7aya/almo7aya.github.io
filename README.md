# almo7aya.dev

My personal site. The home page is a text-mode debugger that boots **7OS**, a tiny real-mode
operating system written in assembly, on an **8086 emulator written in JavaScript**. Nothing on the
screen is a recording: the boot sector, the INT 13h disk read, the shell and the `panic` command are
real machine code, assembled with NASM and executed instruction by instruction in your browser.

```
os/almo7aya.asm      7OS: stage 1 boot sector + stage 2 shell (NASM, cpu 8086)
os/build.mjs         assembles it → public/os/almo7aya.img + src/data/listing.json
os/test.mjs          boots the image headlessly in Node and prints the screen
src/lib/cpu8086.js   the 8086 + a small HLE BIOS (INT 10h/13h/15h/16h/19h/1Ah)
src/lib/debugger.js  wires the machine to the windows on the home page
src/pages/           Astro pages: home, posts, reading, about, RSS at /index.xml
src/posts/           blog posts (markdown)
```

## run it

Needs Node 22+ and [NASM](https://nasm.us) (`scoop install nasm`, `brew install nasm`, `apt install nasm`).

```sh
npm install
npm run dev          # assembles 7OS, then starts Astro
npm run test:os      # boot 7OS in Node, type "help work panic", print the screen
npm run build        # static site in dist/
```

## boot 7OS on a real(ish) machine

```sh
npm run os
qemu-system-i386 -drive format=raw,file=public/os/almo7aya.img
```

Or `dd` it to a USB stick and boot an old PC in legacy BIOS mode.

## debugger keys

| key | does |
| --- | --- |
| click the screen | attaches the keyboard: type 7OS commands (`help`, `about`, `work`, `github`, `time`, `7`, `panic`, `reboot`) |
| F5 | go / break |
| F8 | trace one instruction |
| F9 | breakpoint at the current instruction (or click a line's gutter) |
| F2 | reboot |

## credits

The panicking girl is the site mascot. Text-mode glyphs fall back to [VT323](https://fonts.google.com/specimen/VT323);
drop `Web437_IBM_VGA_8x16.woff` from [The Ultimate Oldschool PC Font Pack](https://int10h.org/oldschool-pc-fonts/)
(CC BY-SA 4.0) into `public/fonts/` for the real VGA font.
