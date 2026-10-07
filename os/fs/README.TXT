7OS 0.8
=======

You are running a real operating system. It was written in 8086 assembly and
assembled with NASM into almo7aya.img. On almo7aya.dev it is executed one
instruction at a time by an 8086 PC emulated in JavaScript; the same image
boots in QEMU or on an old PC.

  stage 1   the 512-byte boot sector at 0000:7C00. it reads the kernel
            from disk with INT 13h and jumps to it.
  stage 2   the kernel and this shell, at 0000:7E00.
  7FS       the filesystem you are reading from: a directory sector at
            LBA 32 and files after it. this file was loaded with INT 13h.

Things to try: dir, type source.asm, regs, ints, uptime, demo, panic.

The clock in the title bar is drawn by an interrupt handler: 7OS hooks
INT 1Ch, which the BIOS calls on every timer tick (IRQ0, 18.2 Hz).

Boot it outside the browser:
  qemu-system-i386 -drive format=raw,file=almo7aya.img
