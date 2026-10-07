; invaders.asm · space invaders in one 512-byte boot sector
;
;   build:  node os/build.mjs invaders
;   run:    qemu-system-i386 -drive format=raw,file=public/os/invaders.img
;
; how it works:
;   - text mode 80x25: rows 0..22 are the sky, row 23 the cannon, row 24 the status line
;   - the screen is the game state: invaders exist only in video memory. A march step is one
;     REP MOVSW of the whole sky, one column sideways or (at the edge) one row down.
;     The fewer invaders are left, the shorter the wait between steps.
;   - the shot reads the cell it flies into: an invader there dies (the cell is cleared)
;   - bombs fall from the lowest invader near the cannon: keep moving
;   - the PIT runs at ~72.6 Hz: one frame per tick, HLT in between
;   - DS = ES = B800 (video), SS = 0: [bp+x] variables and the BIOS data area go through SS

cpu 8086
bits 16
org 0x7C00

TICKS   equ 0x046C              ; BIOS tick counter (72.6 per second while we run)
KBHEAD  equ 0x041A              ; BIOS keyboard buffer head, tail at +2
; variables: initialised data inside the boot sector, BP = vars. Game over restarts the
; machine with INT 19h, which loads a fresh copy of the sector: no init code needed.
dir     equ 0                   ; +2 marching right, -2 left
shot    equ 2                   ; video offset of the shot, 0 = none
bomb    equ 4                   ; video offset of the bomb, 0 = none
px      equ 6                   ; video offset of the cannon's left cell
count   equ 8                   ; invaders left
mtime   equ 9                   ; frames to the next march step
steps   equ 10                  ; side steps to the next edge
downs   equ 11                  ; rows to go down before they land
seed    equ 12                  ; random numbers

ROW22   equ 22*160
ROW23   equ 23*160
ROW24   equ 24*160
BLANK   equ 0x0720
SHOT    equ 0x0FB3              ; white bar
BOMB    equ 0x0C19              ; red arrow
ALIEN   equ 0x0A8E              ; Ä, the top row's colour

start:
        xor     ax, ax
        mov     ss, ax
        mov     sp, 0x7C00
        mov     bp, vars
        mov     al, 0x03                ; 80x25 colour text, clears the screen
        int     0x10
        mov     ah, 0x01                ; hide the cursor
        mov     ch, 0x20
        int     0x10
        mov     al, 0x36                ; PIT channel 0, mode 3, divisor 4036h
        out     0x43, al
        out     0x40, al
        mov     al, 0x40
        out     0x40, al
        mov     ax, 0xB800
        mov     ds, ax
        mov     es, ax
        cld
        mov     si, status
        mov     di, ROW24 + 2
        mov     ah, 0x0A
        call    print

        ; ---- a new wave: 5 rows of 10, four columns apart, a colour per row ----
        ; (the shot is gone when a wave ends; a falling bomb just keeps falling)
wave:   mov     di, 2*160 + 2*21
        mov     ax, ALIEN               ; Ä, from light green down to yellow
        mov     dl, 5
.row:   mov     cx, 10
.col:   stosw
        add     di, 6
        loop    .col
        add     di, 2*160 - 80
        inc     ah
        dec     dl
        jnz     .row
        mov     byte [bp+count], 50
        mov     word [bp+steps], 22 + 12*256    ; 21 steps to either edge, 12 rows to fall
        inc     cx

; ===================================================================
; one frame per timer tick (CX = 1 here)
; ===================================================================
frame:  call    delay

        mov     di, [bp+shot]           ; take the shot and the bomb off the sky
        mov     al, SHOT & 0xFF
        call    erase
        mov     di, [bp+bomb]
        mov     al, BOMB & 0xFF
        call    erase

        ; ---- march ----
        dec     byte [bp+mtime]
        jnz     .nomarch
        mov     al, [bp+count]          ; wait count/4+1 frames for the next step
        shr     al, 1
        shr     al, 1
        inc     ax
        mov     [bp+mtime], al
        mov     ax, [bp+dir]            ; sideways...
        dec     byte [bp+steps]
        jnz     .move
        mov     byte [bp+steps], 43     ; ...or at the edge: down a row and turn around
        dec     byte [bp+downs]         ; 12 rows down they reach the cannon: landed
        jz      .over
        neg     word [bp+dir]
        mov     ax, 160
.move:  mov     cx, 22*80               ; move the sky: rows 0..21 (left) or 1..22 (right, down)
        xor     di, di
        mov     si, 2
        test    ax, ax
        js      .go                     ; left: copy forwards, cell 1 -> cell 0
        std                             ; right/down: copy backwards from the end
        mov     di, ROW23 - 2
        mov     si, di
        sub     si, ax
.go:    rep     movsw
        cld
.nomarch:

        ; ---- the bomb: one row down every 4th frame ----
        test    byte [ss:TICKS], 3
        jnz     .bx
        mov     di, [bp+bomb]
        test    di, di
        jnz     .fall
        mov     ax, [bp+seed]           ; a new one: seed = seed * 25173 + 1
        mov     dx, 25173
        mul     dx
        inc     ax
        mov     [bp+seed], ax
        and     ax, 0x7E                ; a random column of the cannon's 64-column block
        mov     di, [bp+px]
        xor     di, ax                  ; climb to the lowest invader in it
.up:    sub     di, 160
        jc      .bx                     ; nobody up there
        cmp     byte [di], ' '
        je      .up
.fall:  add     di, 160
        cmp     di, ROW23
        jae     .ground
        cmp     byte [di], ' '          ; behind another invader: don't draw over it
        jne     .bset
        mov     word [di], BOMB
        jmp     .bset

        ; ---- game over: a second to let go of the keys, then any key plays again ----
.over:   mov     si, s_over
        mov     di, 15*160 + 70
        mov     ah, 0x4F
        call    print
        mov     cl, 72                  ; CX = 0 on both ways here
        call    delay
        mov     ax, [ss:KBHEAD]         ; forget the keys pressed meanwhile
        mov     [ss:KBHEAD+2], ax
        xor     ah, ah
        int     0x16
        int     0x19                    ; reboot: a fresh copy of the game

.ground: cmp    byte [di], ' '          ; row 23: the cannon is the only thing there
        je      .miss
        dec     byte [LIVES]            ; lives are on screen too: '3' '2' '1' have odd
        jpe     .over                   ; parity, '0' (30h) is the first even one
        mov     cl, 36                  ; half a second to notice (CX = 0 here)
        call    delay
.miss:  xor     di, di
.bset:  mov     [bp+bomb], di
.bx:

        ; ---- keys: arrows move, space fires ----
        mov     ah, 0x01
        int     0x16
        jz      .nokey
        xor     ah, ah
        int     0x16
        mov     bx, [bp+px]
        cmp     al, ' '
        jne     .arrow
        cmp     [bp+shot], cx           ; CX = 0 here: no shot flying?
        jne     .nokey
        lea     di, [bx+2]              ; from the barrel, moves up right away
        jmp     .fly
.arrow: cmp     ah, 0x4B
        je      .left
        cmp     ah, 0x4D
        jne     .nokey
        add     bx, 8
.left:  sub     bx, 4
        lea     ax, [bx-ROW23]          ; still on the cannon row?
        cmp     ax, 154
        ja      .nokey
        mov     [bp+px], bx
.nokey:

        ; ---- the shot: one row up per frame ----
        mov     di, [bp+shot]
.fly:   sub     di, 160                 ; (no shot: 0 - 160 borrows, still none)
        jc      .gone                   ; flew off the top
        cmp     byte [di], ALIEN & 0xFF ; only invaders stop it (it flies through bombs)
        jne     .sdraw
        mov     word [di], BLANK        ; hit an invader
        mov     bx, SCORE               ; the score lives on screen: add 1 to its tens digit
.carry: inc     byte [bx]
        cmp     byte [bx], '9' + 1
        jne     .scored
        mov     byte [bx], '0'
        dec     bx
        dec     bx
        jmp     .carry
.scored:
        dec     byte [bp+count]
        jz      wave                    ; all gone: next wave (CX = 1 from the delay)
.gone:  xor     di, di
        jmp     .sset
.sdraw: mov     word [di], SHOT
.sset:  mov     [bp+shot], di

        ; ---- the cannon and the numbers ----
        mov     di, ROW23
        mov     cl, 80
        mov     ax, BLANK
        rep     stosw
        mov     di, [bp+px]
        mov     ax, 0x0ADC              ; green  ▄█▄
        stosw
        mov     al, 0xDB
        stosw
        mov     al, 0xDC
        stosw
        inc     cx
        jmp     frame


; erase: blank [DI] if it still holds glyph AL
erase:  cmp     [di], al
        jne     .r
        mov     word [di], BLANK
.r:     ret



; print: 0-terminated string at SS:SI (the code segment is 0) to [DI] in colour AH
print:  ss lodsb
        test    al, al
        jz      .r
        stosw
        jmp     print
.r:     ret

; delay: wait CX timer ticks
delay:  mov     ax, [ss:TICKS]
.w:     hlt
        cmp     ax, [ss:TICKS]
        je      .w
        loop    delay
        ret

vars:   dw      2, 0, 0, ROW23 + 76     ; dir, shot, bomb, px

; the status line. Printed once, then count..seed (vars+8..13) overwrite its start.
; From then on the lives and score digits are counted right there in video memory.
status: db      'INVADERS 512 bytes ', 3
LIVES   equ     ROW24 + 2*(1 + $ - status)
        db      '3 SCORE 000'
SCORE   equ     ROW24 + 2*(1 + $ - status)
        db      '00', 0
s_over: db      'GAME OVER', 0

        times   510 - ($ - $$) db 0
        dw      0xAA55
