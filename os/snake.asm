; snake.asm · the whole game of snake in one 512-byte boot sector
;
;   build:  node os/build.mjs snake
;   run:    qemu-system-i386 -drive format=raw,file=public/os/snake.img
;
; how it works:
;   - text mode 80x25; every cell of the board is two characters wide (16x16 pixels, square)
;   - the screen IS the board: moving the head reads the cell it lands on
;     (blank = ok, food = grow, anything else = wall or tail = game over)
;   - the body is a ring buffer of video offsets at 0000:8000 (head in BP, tail in SI)
;   - paced by the BIOS tick counter at 0040:006C (18.2 Hz), HLT between ticks
;   - the first key starts, arrows steer, any key restarts after a crash; the high score survives

cpu 8086
bits 16
org 0x7C00

BODY    equ 0x8000              ; ring buffer, 2048 words (DS = SS = 0)
TICKS   equ 0x046C              ; BIOS tick counter
dir     equ 0x7E00              ; vars just past the boot sector
grow    equ 0x7E02
score   equ 0x7E04
hi      equ 0x7E06
seed    equ 0x7E08              ; never initialised: whatever RAM holds is fine

BLANK   equ 0x0720
WALL    equ 0x01DB              ; solid blue, merges with the bar
BAR     equ 0x1F20              ; top status bar: white on blue
SNAKE   equ 0x0ADB              ; bright green block
HEAD    equ 0x0EDB              ; yellow block
FOOD    equ 0x0CDB              ; red block: same glyph as the snake, the colour tells them apart

start:
        xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, 0x7C00
        mov     [hi], ax
        sti
        cld
        mov     ax, 0xB800
        mov     es, ax
        mov     al, 0xB6                ; PIT channel 2 = a 1.2 kHz square wave for the speaker
        out     0x43, al
        mov     al, 1000 & 0xFF
        out     0x42, al
        mov     al, 1000 >> 8
        out     0x42, al

restart:
        mov     ax, 0x0003              ; 80x25 colour text, clears the screen
        int     0x10
        mov     ah, 0x01                ; hide the cursor
        mov     ch, 0x20
        int     0x10

        ; ---- board: blue bar, then wall everywhere, then hollow out the inside ----
        xor     di, di
        mov     ax, BAR
        mov     cx, 80
        rep     stosw
        mov     ax, WALL
        mov     cx, 80*24
        rep     stosw
        mov     di, 2*160 + 4           ; inside: rows 2..23, columns 2..77
        mov     dx, 22
.row:   mov     ax, BLANK
        mov     cx, 76
        rep     stosw
        add     di, 8
        dec     dx
        jnz     .row

        mov     ah, 0x1E                ; yellow on blue
        mov     si, title
        mov     di, 2
        call    print
        mov     di, 106
        call    print                   ; "HI"
        mov     di, 140
        call    print                   ; "SCORE"

        ; ---- a new snake: 1 cell long, 4 more cells to grow, heading right ----
        xor     bp, bp                  ; head index
        xor     si, si                  ; tail index
        mov     word [BODY], 12*160 + 80
        mov     ax, 4
        mov     [dir], ax
        mov     [grow], al
        mov     [score], bp
        call    food
        call    waitkey                 ; the first arrow starts the game

; ===================================================================
; main loop: one move per two ticks (9 moves a second), faster after 20
; ===================================================================
step:
        mov     cx, 2
        cmp     byte [score], 20
        jb      .slow
        dec     cx
.slow:  call    delay
        in      al, 0x61                ; speaker off (a blip lasts one move)
        and     al, 0xFC
        out     0x61, al

        mov     ah, 0x01                ; a key waiting?
        int     0x16
        jz      .move
        xor     ah, ah
        int     0x16                    ; AH = scan code
        mov     bx, -160
        cmp     ah, 0x48                ; up
        je      .turn
        mov     bx, 160
        cmp     ah, 0x50                ; down
        je      .turn
        mov     bx, -4
        cmp     ah, 0x4B                ; left
        je      .turn
        mov     bx, 4
        cmp     ah, 0x4D                ; right
        jne     .move
.turn:  mov     ax, bx
        add     ax, [dir]               ; dir + new = 0 means a U-turn into yourself: ignore
        jz      .move
        mov     [dir], bx

.move:  mov     di, [bp+BODY]           ; the old head becomes body
        mov     ax, SNAKE
        stosw
        stosw
        mov     bx, [bp+BODY]
        add     bx, [dir]               ; the new head
        mov     ax, [es:bx]             ; what's there?
        cmp     ax, FOOD
        je      .eat
        cmp     al, ' '
        jne     .dead

.go:    inc     bp                      ; push the head
        inc     bp
        and     bp, 0x0FFE
        mov     [bp+BODY], bx
        mov     di, bx
        mov     ax, HEAD
        stosw
        stosw
        cmp     byte [grow], 0          ; still growing: keep the tail
        je      .tail
        dec     byte [grow]
        jmp     step
.tail:  mov     di, [si+BODY]           ; pop the tail
        mov     ax, BLANK
        stosw
        stosw
        inc     si
        inc     si
        and     si, 0x0FFE
        jmp     step

.eat:   in      al, 0x61                ; blip
        or      al, 3
        out     0x61, al
        add     byte [grow], 3
        inc     word [score]
        call    food
        jmp     .go

        ; ---- crash: flash GAME OVER, wait a second, any key plays again ----
.dead:  mov     si, over
        mov     di, 12*160 + 64
        mov     ah, 0x4F                ; white on red
        call    print
        mov     cx, 18
        call    delay
.flush: mov     ah, 0x01                ; drop the keys pressed while dying
        int     0x16
        jz      .wait
        xor     ah, ah
        int     0x16
        jmp     .flush
.wait:  call    waitkey                 ; the key stays queued: it also starts the next game
        jmp     restart

; waitkey: sleep until a key is waiting, without taking it
waitkey:
        hlt
        mov     ah, 0x01
        int     0x16
        jz      waitkey
        ret

; -------------------------------------------------------------------
; food: put food on a random empty cell and redraw the score
; keeps BX, SI, BP
; -------------------------------------------------------------------
food:
.r:     mov     ax, [seed]              ; seed = seed * 25173 + ticks: the timing of play stirs it
        mov     dx, 25173
        mul     dx
        add     ax, [TICKS]
        mov     [seed], ax
        xor     dx, dx
        mov     cx, 23*160
        div     cx                      ; DX = 0 .. 3679
        add     dx, 2*160               ; rows 2..24
        and     dl, 0xFC                ; start of a 2-character cell
        mov     di, dx
        cmp     byte [es:di], ' '       ; walls and snake are not blank
        jne     .r
        mov     ax, FOOD
        stosw
        stosw

        mov     ax, [score]             ; new high score?
        cmp     ax, [hi]
        jb      .nohi
        mov     [hi], ax
.nohi:  mov     di, 158                 ; SCORE, right-aligned on the bar
        call    num
        mov     ax, [hi]
        mov     di, 118                 ; HI, left of it
        ; fall through

; num: AX as 4 decimal digits ending at ES:DI (drawn right to left)
num:    push    bx
        mov     bx, 10
        mov     cx, 4
        std
.d:     xor     dx, dx
        div     bx
        xchg    ax, dx
        add     ax, 0x1F30              ; '0' + digit, white on blue
        stosw
        xchg    ax, dx
        loop    .d
        cld
        pop     bx
        ret

; print: the 0-terminated string at SI to ES:DI in colour AH (SI ends past the 0)
print:  lodsb
        test    al, al
        jz      .r
        stosw
        jmp     print
.r:     ret

; delay: wait CX timer ticks, sleeping with HLT in between
delay:  mov     ax, [TICKS]
.w:     hlt
        cmp     ax, [TICKS]
        je      .w
        loop    delay
        ret

title:  db      'SNAKE ', 0xFA, ' 512 bytes ', 0xFA, ' arrows', 0
        db      'HI', 0                 ; digits at columns 56-59
        db      'SCORE', 0              ; digits at columns 76-79
over:   db      ' GAME OVER ', 0

        times   510 - ($ - $$) db 0
        dw      0xAA55
