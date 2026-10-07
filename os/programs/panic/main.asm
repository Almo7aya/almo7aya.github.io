; panic.asm · PANIC!, a dodging game in one 512-byte boot sector
;
;   build:  node os/build.mjs panic
;   run:    qemu-system-i386 -drive format=raw,file=public/os/panic.img
;
; the site's mascot panics when the CPU faults. Here she is the smiley at the bottom and the
; bugs rain down: X # * and the odd SEGFAULT. Dodge them; they fall faster and thicker the
; longer you last. Score = rows survived. A hit turns the screen red: PANIC.
;
; how it works:
;   - text mode 80x25, row 0 is the status line, rows 1..24 the field, she lives on row 24
;   - one BIOS scroll (INT 10h AH=07h) moves all the bugs down a row; new ones appear on row 1
;   - collisions are read straight off the screen: anything under her = PANIC
;   - INT 09h is hooked so holding an arrow keeps her running: we keep the last scan code
;   - the PIT runs at ~72.6 Hz, frames are paced by the BIOS tick counter and HLT
;   - DS = ES = B800 (video), SS = 0: [bp+x] variables and the BIOS data area go through SS

cpu 8086
bits 16
org 0x7C00

TICKS   equ 0x046C
ROW1    equ 160
ROW24   equ 24*160
BLANK   equ 0x0720
HER     equ 0x0E02              ; yellow ☻

; variables, BP = vars
score   equ 0                   ; rows survived
best    equ 2
px      equ 4                   ; her video offset on row 24
seed    equ 6
last    equ 8                   ; last scan code from the keyboard (written by kbd via CS = 0)
ival    equ 9                   ; frames per row
timer   equ 10                  ; frames to the next row

start:
        xor     ax, ax
        mov     ss, ax
        mov     sp, 0x7C00
        mov     bp, vars
        cli
        mov     word [ss:9*4], kbd      ; INT 09h -> kbd, segment 0
        mov     [ss:9*4+2], ax
        sti
        mov     al, 0x36                ; PIT channel 0, mode 3, divisor 4036h: ~72.6 Hz
        out     0x43, al
        out     0x40, al
        mov     al, 0x40
        out     0x40, al
        mov     ax, 0xB800
        mov     ds, ax
        mov     es, ax
        cld

restart:
        mov     ax, 0x0003              ; 80x25 colour text, clears the screen
        int     0x10
        mov     ah, 0x01                ; hide the cursor
        mov     ch, 0x20
        int     0x10
        mov     si, status
        mov     di, 0
        mov     ah, 0x0B
        call    print
        mov     ax, [bp+best]
        mov     di, BEST
        call    num
        xor     ax, ax
        mov     [bp+score], ax
        mov     word [bp+ival], 10 + 1*256      ; 10 frames a row, the first one now
        mov     word [bp+px], ROW24 + 80

; ===================================================================
; one frame per timer tick
; ===================================================================
frame:  call    tick

        ; ---- run: every 2nd frame while an arrow is held ----
        test    al, 1
        jnz     .stay
        mov     bx, [bp+px]
        mov     al, [bp+last]
        cmp     al, 0x4B                ; left
        je      .left
        cmp     al, 0x4D                ; right
        jne     .stay
        inc     bx
        inc     bx
        inc     bx
        inc     bx
.left:  dec     bx
        dec     bx
        lea     ax, [bx-ROW24]          ; still on the row?
        cmp     ax, 158
        ja      .stay
        mov     di, [bp+px]             ; off the old cell, onto the new one
        mov     word [di], BLANK
        cmp     byte [bx], ' '          ; ran into a bug?
        jne     panic
        mov     word [bx], HER
        mov     [bp+px], bx
.stay:

        ; ---- rain: every ival frames all the bugs fall a row ----
        dec     byte [bp+timer]
        jnz     frame
        mov     al, [bp+ival]
        mov     [bp+timer], al
        mov     ax, 0x0701              ; scroll rows 1..24 down one line (row 24, with her,
        mov     bh, 0x07                ; drops off the bottom)
        mov     cx, 0x0100
        mov     dx, 0x184F
        int     0x10
        mov     bx, [bp+px]
        cmp     byte [bx], ' '          ; did a bug land on her?
        jne     panic
        mov     word [bx], HER

        ; ---- new bugs on row 1: 2 + score/256 of them ----
        mov     al, [bp+score+1]
        cbw
        add     ax, 2
        xchg    ax, cx
.bug:   mov     ax, [bp+seed]           ; seed = seed * 25173 + ticks
        mov     dx, 25173
        mul     dx
        add     ax, [ss:TICKS]
        mov     [bp+seed], ax
        mov     dl, 80                  ; column = AH * 80 / 256
        xchg    ax, dx
        mul     dh
        mov     bl, ah
        mov     bh, 0
        shl     bx, 1
        mov     al, dl                  ; # $ % & from mixed bits, in red
        xor     al, dh
        and     al, 3
        add     al, '#'
        mov     ah, 0x0C
        mov     [bx+ROW1], ax
        test    dl, 0x7C                ; one bug in 32 is a SEGFAULT
        jnz     .nope
        cmp     bl, 2*72                ; that needs 8 columns
        ja      .nope
        mov     si, s_seg
        lea     di, [bx+ROW1]
        mov     ah, 0x0D
        call    print
.nope:  loop    .bug

        ; ---- the score; faster every 64 rows ----
        inc     word [bp+score]
        mov     ax, [bp+score]
        mov     di, ROWS
        call    num
        mov     al, [bp+score]
        test    al, 63
        jnz     frame
        cmp     byte [bp+ival], 3
        jbe     frame
        dec     byte [bp+ival]
        jmp     frame


; ---- PANIC: everything red, the message, a beep, then space plays again ----
panic:  mov     word [bx], 0x4F13       ; ‼ where she was hit
        mov     al, 0x4F                ; every cell white on red, the bugs stay visible
        xor     di, di
        mov     cx, 80*25
.red:   inc     di
        stosb
        loop    .red
        mov     si, s_panic
        mov     di, 12*160 + 2*31
        mov     ah, 0x1F
        call    print
        mov     al, 0xB6                ; speaker: 220 Hz
        out     0x43, al
        mov     ax, 1193182 / 220
        out     0x42, al
        mov     al, ah
        out     0x42, al
        in      al, 0x61
        or      al, 3
        out     0x61, al
        mov     ax, [bp+score]          ; new best?
        cmp     ax, [bp+best]
        jb      .old
        mov     [bp+best], ax
.old:   mov     cx, 40
.wait:  call    tick
        loop    .wait
        in      al, 0x61                ; quiet
        and     al, 0xFC
        out     0x61, al
        mov     byte [bp+last], 0
.key:   hlt
        cmp     byte [bp+last], 0x39    ; space
        jne     .key
        jmp     restart

; tick: sleep until the timer ticks
tick:   mov     ax, [ss:TICKS]
.w:     hlt
        cmp     ax, [ss:TICKS]
        je      .w
        ret

; num: AX as 4 decimal digits ending at [DI], right to left
num:    mov     bx, 10
        mov     cx, 4
        std
.d:     xor     dx, dx
        div     bx
        xchg    ax, dx
        add     ax, 0x0F30
        stosw
        xchg    ax, dx
        loop    .d
        cld
        ret

; print: 0-terminated string at SS:SI (code segment 0) to [DI] in colour AH
print:  ss lodsb
        test    al, al
        jz      .r
        stosw
        jmp     print
.r:     ret

; keyboard IRQ: remember the scan code (bit 7 = released)
kbd:    push    ax
        in      al, 0x60
        mov     [cs:vars+last], al
        mov     al, 0x20
        out     0x20, al
        pop     ax
        iret

vars:   dw      0, 0, 0, 0
        db      0, 0, 0
status: db      ' PANIC! 512 bytes   ROWS 000'
ROWS    equ     2*($ - status)          ; last digit of the rows counter
        db      '0  BEST 000'
BEST    equ     2*($ - status)
        db      '0', 0
s_seg:  db      'SEGFAULT', 0
s_panic: db     ' PANIC (>_<) ', 0

        times   510 - ($ - $$) db 0
        dw      0xAA55
