; maze.asm · 7MAZE, a Wolfenstein-style walk through Ali Almohaya's portfolio
;
;   build:  node os/build.mjs maze      (assets.mjs generates gen/: palette, shade tables,
;                                        textures, map, sin + camera tables)
;   run:    qemu-system-i386 -drive format=raw,file=public/os/maze.img
;
; disk layout (512-byte sectors, LBA):
;   0          stage 1: reads the geometry (INT 13h/08h) and loads everything below
;   1..        code + tables            -> 0000:7E00
;   TEX_LBA..  64x64 textures, 4 KB each -> 3000:0000, one 256-paragraph slot per texture
;   BG_LBA..   ceiling/floor picture    -> 2000:0000
;
; memory:
;   0000:7E00  code, tables, map         1000:0000  back buffer (64000 bytes) + darken table at FA00
;   2000:0000  background                3000:0000  textures
;
; rendering, per frame:
;   - rep movsw the background into the back buffer (ceiling + floor gradients)
;   - 320 rays, camera-plane DDA in 8.8 fixed point (1 cell = 256), perpendicular distance
;     straight from the side distances (no fisheye), wall height = 51200 / dist
;   - the texture column (64 texels) is pushed through a 256-byte shade table for distance
;     fog into colbuf, then drawn by jumping into a 200x unrolled "texel -> pixel" run
;   - minimap and info card on top (translucent: darkened through a shade table), then the
;     back buffer is copied to A000:0000 at the start of vertical retrace (3DAh bit 3)
; input: INT 09h hook keeps a make/break table, so held keys move continuously; a tap holds
; the key for at least TAP_TICKS ticks so single presses (QEMU sendkey) still step.
; time: PIT channel 0 reprogrammed to 70 Hz, INT 1Ch counts ticks, movement is per tick.

cpu 8086
bits 16
org 0x7C00

%include "meta.inc"

BACK_SEG        equ 0x1000
BG_SEG          equ 0x2000
TEX_SEG         equ 0x3000
DARK_TAB        equ 64000           ; 256 bytes in BACK_SEG after the picture
DARK_LEVEL      equ 11

TICK_HZ         equ 70
PIT_DIV         equ 17045           ; 1193182 / 70
SPEED           equ 13              ; 8.8 units per tick, ~3.5 cells/s
TURN            equ 9               ; of 2048 per tick, ~110 deg/s
RADIUS          equ 60              ; player half-size, 8.8
TAP_TICKS       equ 6
CARD_DIST       equ 384             ; 1.5 cells

MM_X            equ 5
MM_Y            equ 5
MM_W            equ 27              ; cells drawn on the minimap
MM_H            equ 23

SC_ESC  equ 01h
SC_W    equ 11h
SC_A    equ 1Eh
SC_S    equ 1Fh
SC_D    equ 20h
SC_Q    equ 10h
SC_E    equ 12h
SC_M    equ 32h
SC_F    equ 21h
SC_UP   equ 48h
SC_DOWN equ 50h
SC_LEFT equ 4Bh
SC_RIGHT equ 4Dh

; ===================================================================
; stage 1 · boot sector
; ===================================================================
boot:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 0x7C00
        sti
        cld
        mov     [boot_drive], dl

        mov     ah, 0x08                ; geometry: CL bits 0-5 = sectors per track, DH = last head
        push    es
        int     0x13
        pop     es
        jc      .geo
        mov     al, cl
        and     ax, 0x003F
        jz      .geo
        mov     [spt], ax
        mov     al, dh
        xor     ah, ah
        inc     ax
        mov     [heads], ax
.geo:
        mov     ax, 1
        mov     cx, CODE_SECTORS
        mov     dx, 0x07E0
        call    load
        mov     ax, TEX_LBA
        mov     cx, TEX_SECTORS
        mov     dx, TEX_SEG
        call    load
        mov     ax, BG_LBA
        mov     cx, BG_SECTORS
        mov     dx, BG_SEG
        call    load
        jmp     0x0000:stage2

; AX = LBA, CX = sectors, DX = segment (each sector goes to the next 32 paragraphs)
load:
.next:  push    ax
        push    cx
        push    dx
        mov     es, dx
        xor     dx, dx
        div     word [spt]              ; AX = LBA / spt, DX = LBA % spt
        mov     cl, dl
        inc     cl
        xor     dx, dx
        div     word [heads]            ; AX = cylinder, DX = head
        mov     ch, al
        ror     ah, 1
        ror     ah, 1
        and     ah, 0xC0
        or      cl, ah
        mov     dh, dl
        mov     dl, [boot_drive]
        xor     bx, bx
        mov     di, 3                   ; tries
.try:   mov     ax, 0x0201
        int     0x13
        jnc     .ok
        xor     ax, ax
        int     0x13
        dec     di
        jnz     .try
        mov     si, s_diskerr
.puts:  lodsb
        test    al, al
        jz      .halt
        mov     ah, 0x0E
        xor     bx, bx
        int     0x10
        jmp     .puts
.halt:  hlt
        jmp     .halt
.ok:    pop     dx
        pop     cx
        pop     ax
        add     dx, 0x20
        inc     ax
        loop    .next
        ret

boot_drive      db 0x80
spt             dw 63
heads           dw 16
s_diskerr       db "7MAZE: disk read error", 0

        times 510-($-$$) db 0
        dw      0xAA55

; ===================================================================
; stage 2 · at 0000:7E00
; ===================================================================
%macro FIX14 0                          ; DX:AX (a product of two 1.14 / 8.8 numbers) >> 14 -> DX
        shl     ax, 1
        rcl     dx, 1
        shl     ax, 1
        rcl     dx, 1
%endmacro

stage2:
        mov     ax, 0x0013
        int     0x10
        push    es
        mov     ax, 0x1130              ; where is the 8x16 font? ES:BP
        mov     bh, 0x06
        int     0x10
        mov     [font_off], bp
        mov     [font_seg], es
        pop     es

        mov     dx, 0x3C8               ; the 16 ramps x 16 levels palette
        xor     al, al
        out     dx, al
        inc     dx
        mov     si, palette
        mov     cx, 768
.pal:   lodsb
        out     dx, al
        loop    .pal

        mov     ax, BACK_SEG            ; darken table for translucent panels
        mov     es, ax
        mov     di, DARK_TAB
        mov     si, shade_tab + DARK_LEVEL * 256
        mov     cx, 128
        rep     movsw
        xor     ax, ax
        mov     es, ax

        cli
        mov     word [9 * 4], kbd_isr
        mov     word [9 * 4 + 2], 0
        mov     word [0x1C * 4], tick_isr
        mov     word [0x1C * 4 + 2], 0
        mov     al, 0x36                ; PIT channel 0, mode 3, 70 Hz
        out     0x43, al
        mov     ax, PIT_DIV
        out     0x40, al
        mov     al, ah
        out     0x40, al
        sti
        mov     ax, [ticks]
        mov     [last_tick], ax

; -------------------------------------------------------------------
; main loop: input per tick, render, show at vertical retrace
; -------------------------------------------------------------------
main:
        cli
        mov     ax, [ticks]
        sti
        mov     cx, ax
        sub     cx, [last_tick]
        mov     [last_tick], ax
        add     [fps_ticks], cx
        cmp     cx, 8
        jbe     .few
        mov     cx, 8
.few:   jcxz    .notick
.tick:  push    cx
        call    update_tick
        pop     cx
        loop    .tick
.notick:
        cmp     word [fps_ticks], TICK_HZ
        jb      .nofps
        sub     word [fps_ticks], TICK_HZ
        mov     ax, [frames]
        mov     [fps], ax
        mov     word [frames], 0
.nofps:
        call    toggles
        call    render
        call    pick_card
        cmp     byte [show_map], 0
        je      .nomap
        call    minimap
.nomap: call    draw_card
        cmp     byte [show_fps], 0
        je      .nof
        call    draw_fps
.nof:   inc     word [frames]
        call    present
        jmp     main

present:
%ifndef BENCH                           ; BENCH: no retrace wait, to measure the frame cost
        mov     dx, 0x3DA
.w1:    in      al, dx                  ; wait until we are outside retrace...
        test    al, 8
        jnz     .w1
.w2:    in      al, dx                  ; ...then for its start
        test    al, 8
        jz      .w2
%endif
        push    ds
        mov     ax, BACK_SEG
        mov     ds, ax
        mov     ax, 0xA000
        mov     es, ax
        xor     si, si
        xor     di, di
        mov     cx, 32000
        rep     movsw
        pop     ds
        ret

; -------------------------------------------------------------------
; interrupts
; -------------------------------------------------------------------
tick_isr:
        inc     word [cs:ticks]
        iret

kbd_isr:
        push    ax
        push    bx
        in      al, 0x60
        cmp     al, 0xE0                ; extended prefix: the next code is enough
        je      .eoi
        mov     bl, al
        and     bx, 0x7F
        test    al, 0x80
        jnz     .up
        cmp     byte [cs:keys + bx], 0
        jne     .held
        mov     byte [cs:hits + bx], 1  ; a new press (for toggles)
.held:  mov     byte [cs:keys + bx], 1
        mov     byte [cs:keymin + bx], TAP_TICKS
        jmp     .eoi
.up:    mov     byte [cs:keys + bx], 0
.eoi:   mov     al, 0x20
        out     0x20, al
        pop     bx
        pop     ax
        iret

; -------------------------------------------------------------------
; input + movement, once per 70 Hz tick
; -------------------------------------------------------------------
; AL, AH = two scan codes -> ZF clear if either is held (or tapped recently)
key2:
        push    bx
        xor     bx, bx
        mov     bl, al
        mov     cl, [keys + bx]
        or      cl, [keymin + bx]
        mov     bl, ah
        or      cl, [keys + bx]
        or      cl, [keymin + bx]
        pop     bx
        test    cl, cl
        ret

update_tick:
        mov     ax, SC_LEFT + SC_A * 256
        call    key2
        jz      .nl
        sub     word [ang], TURN
.nl:    mov     ax, SC_RIGHT + SC_D * 256
        call    key2
        jz      .nr
        add     word [ang], TURN
.nr:    and     word [ang], 2047
        mov     ax, SC_UP + SC_W * 256
        call    key2
        jz      .nf
        mov     ax, [ang]
        call    move_dir
.nf:    mov     ax, SC_DOWN + SC_S * 256
        call    key2
        jz      .nb
        mov     ax, [ang]
        add     ax, 1024
        call    move_dir
.nb:    mov     ax, SC_Q + SC_Q * 256
        call    key2
        jz      .nq
        mov     ax, [ang]
        sub     ax, 512
        call    move_dir
.nq:    mov     ax, SC_E + SC_E * 256
        call    key2
        jz      .ne
        mov     ax, [ang]
        add     ax, 512
        call    move_dir
.ne:    mov     si, keymin              ; taps run out
        mov     cx, 128
.dec:   cmp     byte [si], 0
        je      .z
        dec     byte [si]
.z:     inc     si
        loop    .dec
        ret

toggles:
        cmp     byte [hits + SC_M], 0
        je      .m
        mov     byte [hits + SC_M], 0
        xor     byte [show_map], 1
.m:     cmp     byte [hits + SC_F], 0
        je      .f
        mov     byte [hits + SC_F], 0
        xor     byte [show_fps], 1
.f:     ret

; AX = angle: step SPEED along it, sliding along walls (x and y tried separately)
move_dir:
        and     ax, 2047
        shl     ax, 1
        mov     bx, ax
        mov     cx, SPEED
        mov     ax, [sin_tab + bx + 1024]
        imul    cx
        add     ax, 0x2000              ; round
        adc     dx, 0
        FIX14
        mov     [mdx], dx
        mov     ax, [sin_tab + bx]
        imul    cx
        add     ax, 0x2000
        adc     dx, 0
        FIX14
        mov     [mdy], dx
        mov     ax, [px]
        add     ax, [mdx]
        mov     bx, [py]
        call    box_free
        jc      .nox
        mov     [px], ax
.nox:   mov     ax, [px]
        mov     bx, [py]
        add     bx, [mdy]
        call    box_free
        jc      .noy
        mov     [py], bx
.noy:   ret

; AX = x, BX = y (8.8): CF set if the player box there touches a wall
box_free:
        push    ax
        push    bx
        sub     ax, RADIUS
        sub     bx, RADIUS
        call    solid
        jc      .out
        add     ax, RADIUS * 2
        call    solid
        jc      .out
        add     bx, RADIUS * 2
        call    solid
        jc      .out
        sub     ax, RADIUS * 2
        call    solid
.out:   pop     bx
        pop     ax
        ret

solid:                                  ; AX = x, BX = y -> CF set if the cell is a wall
        push    si
        push    cx
        mov     si, bx
        and     si, 0xFF00
        mov     cl, 3
        shr     si, cl                  ; (y >> 8) * 32
        mov     cl, ah
        xor     ch, ch
        add     si, cx
        cmp     byte [map + si], 0
        pop     cx
        pop     si
        je      .free
        stc
        ret
.free:  clc
        ret

; -------------------------------------------------------------------
; the raycaster
; -------------------------------------------------------------------
render:
        push    ds
        mov     ax, BG_SEG
        mov     ds, ax
        mov     ax, BACK_SEG
        mov     es, ax
        xor     si, si
        xor     di, di
        mov     cx, 32000
        rep     movsw
        pop     ds

        mov     bx, [ang]
        shl     bx, 1
        mov     ax, [sin_tab + bx]
        mov     [sinA], ax
        mov     ax, [sin_tab + bx + 1024]
        mov     [cosA], ax
        mov     ax, [py]
        and     ax, 0xFF00
        mov     cl, 3
        shr     ax, cl
        mov     bl, [px + 1]
        xor     bh, bh
        add     ax, bx
        add     ax, map
        mov     [pcell], ax
        mov     word [c_seg], 0
        mov     word [col], 0

.col:   mov     bx, [col]
        shl     bx, 1
        mov     cx, [cam_tab + bx]      ; camera x * plane length, 1.14
        mov     ax, [sinA]              ; ray = dir + plane * k, plane = (-sin, cos) * 0.66
        imul    cx
        FIX14
        mov     ax, [cosA]
        sub     ax, dx
        mov     [raydx], ax
        mov     ax, [cosA]
        imul    cx
        FIX14
        add     dx, [sinA]
        mov     [raydy], dx

        ; x: step direction, delta = |1/rdx| (8.8), first side distance
        mov     ax, [raydx]
        mov     cl, [px]
        xor     ch, ch
        test    ax, ax
        js      .xneg
        mov     word [stepx], 1
        neg     cx
        add     cx, 256
        jmp     .xd
.xneg:  mov     word [stepx], -1
        neg     ax
.xd:    mov     si, 0xFFFF
        cmp     ax, 65
        jb      .xs
        mov     bx, ax
        mov     dx, 0x40
        xor     ax, ax
        div     bx
        mov     si, ax
.xs:    mov     ax, si
        mul     cx
        mov     al, ah
        mov     ah, dl
        mov     [sidex], ax
        mov     [deltax], si

        ; y
        mov     ax, [raydy]
        mov     cl, [py]
        xor     ch, ch
        test    ax, ax
        js      .yneg
        mov     word [stepy], MAP_W
        neg     cx
        add     cx, 256
        jmp     .yd
.yneg:  mov     word [stepy], -MAP_W
        neg     ax
.yd:    mov     bp, 0xFFFF
        cmp     ax, 65
        jb      .ys
        mov     bx, ax
        mov     dx, 0x40
        xor     ax, ax
        div     bx
        mov     bp, ax
.ys:    mov     ax, bp
        mul     cx
        mov     al, ah
        mov     ah, dl
        mov     dx, ax                  ; DX = side y

        ; DDA: AX side x, DX side y, SI delta x, BP delta y, CX/DI steps, BX map cell
        mov     ax, [sidex]
        mov     cx, [stepx]
        mov     di, [stepy]
        mov     bx, [pcell]
.dda:   cmp     ax, dx
        jae     .ystep
        add     bx, cx
        cmp     byte [bx], 0
        jne     .hitx
        add     ax, si
        jnc     .dda
        mov     ax, 0xFFFF
        jmp     .dda
.ystep: add     bx, di
        cmp     byte [bx], 0
        jne     .hity
        add     dx, bp
        jnc     .dda
        mov     dx, 0xFFFF
        jmp     .dda

.hitx:  mov     [perp], ax
        mov     byte [side], 0
        jmp     .hit
.hity:  mov     [perp], dx
        mov     byte [side], 1
.hit:   mov     al, [bx]
        mov     [hitv], al
        cmp     word [col], 160
        jne     .nocen
        mov     [cen_v], al
        mov     ax, [perp]
        mov     [cen_perp], ax
.nocen:
        ; where along the wall: u = frac(pos + perp * ray) on the other axis
        cmp     byte [side], 0
        jne     .ty
        mov     ax, [perp]
        imul    word [raydy]
        FIX14
        add     dx, [py]
        mov     al, dl
        cmp     word [raydx], 0
        jge     .tf
        not     al
        jmp     .tf
.ty:    mov     ax, [perp]
        imul    word [raydx]
        FIX14
        add     dx, [px]
        mov     al, dl
        cmp     word [raydy], 0
        jle     .tf
        not     al
.tf:    xor     ah, ah
        shr     al, 1
        shr     al, 1
        mov     cl, 6
        shl     ax, cl
        mov     [texoff], ax

        mov     ax, [perp]
        cmp     ax, 8
        jae     .pok
        mov     ax, 8
        mov     [perp], ax
.pok:   mov     cl, 8                   ; fog level: one per cell, y sides one darker
        shr     ax, cl
        add     al, [side]
        adc     ah, 0
        cmp     ax, 15
        jbe     .lv
        mov     ax, 15
.lv:    mov     ah, al
        xor     al, al
        add     ax, shade_tab
        mov     [shadep], ax

        mov     ah, [hitv]
        dec     ah
        xor     al, al
        add     ax, TEX_SEG
        cmp     ax, [c_seg]             ; same column + fog as the last ray? reuse colbuf
        jne     .shade
        mov     cx, [texoff]
        cmp     cx, [c_off]
        jne     .shade
        mov     cx, [shadep]
        cmp     cx, [c_shade]
        je      .noshade
.shade: mov     [c_seg], ax
        mov     es, ax
        mov     si, [texoff]
        mov     [c_off], si
        mov     bx, [shadep]
        mov     [c_shade], bx
        mov     di, colbuf
        call    shade64
.noshade:

        xor     dx, dx                  ; wall height
        mov     ax, 51200
        div     word [perp]
        test    ax, ax
        jz      .next
        mov     cx, ax
        xor     dx, dx
        mov     ax, 16384               ; texture step, 8.8 texels per pixel
        div     cx
        mov     [tstep], ax
        cmp     cx, 200
        ja      .tall
        mov     word [tpos], 0
        mov     [npix], cx
        mov     ax, 200
        sub     ax, cx
        shr     ax, 1                   ; top row
        jmp     .place
.tall:  mov     ax, cx
        sub     ax, 200
        shr     ax, 1
        mov     dx, 16384
        mul     dx
        div     cx
        mov     [tpos], ax              ; skip the texels above the screen
        mov     word [npix], 200
        xor     ax, ax
.place: add     ax, [npix]
        sub     ax, 200
        mov     dx, 320
        imul    dx
        add     ax, [col]
        mov     di, ax                  ; so that entry (200 - n) lands on the top row
        mov     bx, 200
        sub     bx, [npix]
        shl     bx, 1
        mov     ax, [draw_tab + bx]
        mov     [draw_ptr], ax
        mov     ax, BACK_SEG
        mov     es, ax
        mov     si, colbuf
        mov     dx, [tpos]
        mov     cx, [tstep]
        xor     bx, bx
        call    [draw_ptr]

.next:  inc     word [col]
        cmp     word [col], 320
        jae     .done
        jmp     .col
.done:  xor     ax, ax
        mov     es, ax
        ret

; ES:SI = texture column (64 texels), BX = shade table, DI = colbuf
shade64:
%assign k 0
%rep 64
        es lodsb
        xlatb
        mov     [di + k], al
%assign k k+1
%endrep
        mov     [di + 64], al
        ret

; BL = DH (texel row), AL = colbuf[row], pixel, DX += step; 200 runs, entered at 200 - n
draw_tab:
%assign k 0
%rep 200
        dw      de_%[k]
%assign k k+1
%endrep
%assign k 0
%rep 200
de_%[k]:
        mov     bl, dh
        mov     al, [bx + si]
        mov     [es:di + (k * 320)], al
        add     dx, cx
%assign k k+1
%endrep
        ret

; -------------------------------------------------------------------
; which info card: a poster straight ahead within 1.5 cells, else welcome in the start room
; -------------------------------------------------------------------
pick_card:
        mov     byte [card], 0xFF
        mov     al, [cen_v]
        cmp     al, POSTER_BASE
        jb      .room
        cmp     word [cen_perp], CARD_DIST
        jae     .room
        sub     al, POSTER_BASE
        mov     [card], al
        ret
.room:  mov     al, [px + 1]
        mov     ah, [py + 1]
        cmp     al, ROOM_X0
        jb      .no
        cmp     al, ROOM_X1
        ja      .no
        cmp     ah, ROOM_Y0
        jb      .no
        cmp     ah, ROOM_Y1
        ja      .no
        mov     byte [card], 0
.no:    ret

; -------------------------------------------------------------------
; overlays (all into the back buffer)
; -------------------------------------------------------------------
; AX = x, BX = y, CX = width, DX = height: darken through DARK_TAB
darken:
        push    ds
        push    dx
        push    ax
        mov     ax, 320
        mul     bx
        pop     di
        pop     dx
        add     di, ax
        mov     ax, BACK_SEG
        mov     ds, ax
        mov     es, ax
        mov     bx, DARK_TAB
        mov     bp, cx
.row:   mov     si, di
        mov     cx, bp
.px:    lodsb
        xlatb
        stosb
        loop    .px
        add     di, 320
        sub     di, bp
        dec     dx
        jnz     .row
        pop     ds
        xor     ax, ax
        mov     es, ax
        ret

; AX = x, BX = y, CX = length, DL = colour
hline:
        push    ax
        push    dx
        mov     ax, 320
        mul     bx
        pop     dx
        pop     di
        add     di, ax
        mov     ax, BACK_SEG
        mov     es, ax
        mov     al, dl
        rep     stosb
        ret
vline:
        push    ax
        push    dx
        mov     ax, 320
        mul     bx
        pop     dx
        pop     di
        add     di, ax
        mov     ax, BACK_SEG
        mov     es, ax
.v:     mov     [es:di], dl
        add     di, 320
        loop    .v
        ret

%macro GLYPHBIT 1
        shl     ah, 1
        jnc     %%s
        mov     [es:di + %1], dl
%%s:
%endmacro

; CS:SI = zero-terminated string (SI ends after the 0), AX = x, BX = y, DL = colour
draw_text:
        push    dx
        push    ax
        mov     ax, 320
        mul     bx
        pop     di
        add     di, ax
        pop     dx
        mov     ax, BACK_SEG
        mov     es, ax
.ch:    cs lodsb
        test    al, al
        jz      .end
        push    si
        mov     bl, al
        xor     bh, bh
        mov     cl, 4
        shl     bx, cl
        add     bx, [cs:font_off]
        mov     si, bx
        mov     ds, [cs:font_seg]
        mov     cx, 16
.row:   lodsb
        mov     ah, al
        GLYPHBIT 0
        GLYPHBIT 1
        GLYPHBIT 2
        GLYPHBIT 3
        GLYPHBIT 4
        GLYPHBIT 5
        GLYPHBIT 6
        GLYPHBIT 7
        add     di, 320
        loop    .row
        sub     di, 16 * 320 - 8
        xor     ax, ax
        mov     ds, ax
        pop     si
        jmp     .ch
.end:   xor     ax, ax
        mov     ds, ax
        mov     es, ax
        ret

; AX = x, BX = y, DL = colour
putpix:
        cmp     ax, 320
        jae     .out
        cmp     bx, 200
        jae     .out
        push    ax
        push    dx
        mov     ax, 320
        mul     bx
        pop     dx
        pop     di
        add     di, ax
        mov     ax, BACK_SEG
        mov     es, ax
        mov     [es:di], dl
        xor     ax, ax
        mov     es, ax
.out:   ret

minimap:
        mov     ax, MM_X - 2
        mov     bx, MM_Y - 2
        mov     cx, MM_W * 2 + 4
        mov     dx, MM_H * 2 + 4
        call    darken
        mov     ax, BACK_SEG
        mov     es, ax
        mov     si, mm_map
        mov     di, MM_Y * 320 + MM_X
        mov     dh, MM_H
.row:   mov     cx, MM_W
        push    si
        push    di
.cell:  lodsb
        test    al, al
        jz      .skip
        mov     ah, al
        mov     [es:di], ax
        mov     [es:di + 320], ax
.skip:  add     di, 2
        loop    .cell
        pop     di
        pop     si
        add     si, MAP_W
        add     di, 640
        dec     dh
        jnz     .row
        xor     ax, ax
        mov     es, ax

        mov     ax, [cosA]              ; the view direction: dots 0.5 and 1 cell ahead
        mov     cl, 7
        sar     ax, cl
        mov     bx, [sinA]
        sar     bx, cl
        push    ax
        push    bx
        add     ax, [px]
        add     bx, [py]
        call    mm_dot
        pop     bx
        pop     ax
        shl     ax, 1
        shl     bx, 1
        add     ax, [px]
        add     bx, [py]
        call    mm_dot
        mov     ax, [px]                ; the player
        mov     bx, [py]
        mov     cl, 7
        shr     ax, cl
        shr     bx, cl
        add     ax, MM_X
        add     bx, MM_Y
        mov     dl, 0x0F
        push    ax
        push    bx
        call    putpix
        pop     bx
        pop     ax
        inc     ax
        push    ax
        push    bx
        call    putpix
        pop     bx
        pop     ax
        inc     bx
        push    ax
        push    bx
        call    putpix
        pop     bx
        pop     ax
        dec     ax
        call    putpix
        ret
mm_dot:                                 ; AX, BX = map position (8.8)
        mov     cl, 7
        shr     ax, cl
        shr     bx, cl
        add     ax, MM_X
        add     bx, MM_Y
        mov     dl, 0x6F
        jmp     putpix

draw_card:
        mov     bl, [card]
        cmp     bl, 0xFF
        jne     .go
        ret
.go:    xor     bh, bh
        shl     bx, 1
        mov     si, [card_tab + bx]
        lodsb
        mov     cl, 4
        shl     al, cl
        mov     [cramp], al
        lodsb
        mov     [clines], al
        mov     cl, 4                   ; height = lines * 16 + 28
        xor     ah, ah
        shl     ax, cl
        add     ax, 28
        mov     [ch_], ax
        mov     bx, 196
        sub     bx, ax
        mov     [cy], bx
        push    si
        mov     ax, 6
        mov     cx, 308
        mov     dx, [ch_]
        call    darken
        mov     dl, [cramp]             ; frame in the poster's colour
        add     dl, 11
        mov     ax, 6
        mov     bx, [cy]
        mov     cx, 308
        call    hline
        mov     ax, 6
        mov     bx, 195
        mov     cx, 308
        call    hline
        mov     ax, 6
        mov     bx, [cy]
        mov     cx, [ch_]
        call    vline
        mov     ax, 313
        mov     bx, [cy]
        mov     cx, [ch_]
        call    vline
        mov     ax, 7
        mov     bx, [cy]
        add     bx, 21
        mov     cx, 306
        mov     dl, [cramp]
        add     dl, 7
        call    hline
        pop     si
        mov     ax, 14                  ; title
        mov     bx, [cy]
        add     bx, 4
        mov     dl, [cramp]
        add     dl, 14
        call    draw_text
        mov     bx, [cy]
        add     bx, 24
.line:  cmp     byte [clines], 0
        je      .done
        push    bx
        mov     ax, 14
        mov     dl, 0x0E
        call    draw_text
        pop     bx
        add     bx, 16
        dec     byte [clines]
        jmp     .line
.done:  ret

draw_fps:
        mov     ax, 252
        mov     bx, 3
        mov     cx, 64
        mov     dx, 18
        call    darken
        mov     ax, [fps]
        mov     di, s_fps_num + 2
        mov     cx, 3
        mov     bx, 10
.dig:   xor     dx, dx
        div     bx
        add     dl, '0'
        mov     [di], dl
        dec     di
        loop    .dig
        mov     si, s_fps
        mov     ax, 256
        mov     bx, 4
        mov     dl, 0x6E
        call    draw_text
        ret

; -------------------------------------------------------------------
; data
; -------------------------------------------------------------------
ticks           dw 0
last_tick       dw 0
fps_ticks       dw 0
frames          dw 0
fps             dw 0
show_map        db 1
show_fps        db 0
px              dw START_X
py              dw START_Y
ang             dw START_ANG
mdx             dw 0
mdy             dw 0
sinA            dw 0
cosA            dw 0
pcell           dw 0
col             dw 0
raydx           dw 0
raydy           dw 0
stepx           dw 0
stepy           dw 0
sidex           dw 0
deltax          dw 0
perp            dw 0
side            db 0
hitv            db 0
cen_v           db 0
card            db 0xFF
cen_perp        dw 0xFFFF
texoff          dw 0
shadep          dw 0
c_seg           dw 0
c_off           dw 0
c_shade         dw 0
tstep           dw 0
tpos            dw 0
npix            dw 0
draw_ptr        dw 0
font_off        dw 0
font_seg        dw 0
cramp           db 0
clines          db 0
ch_             dw 0
cy              dw 0
colbuf          times 66 db 0
keys            times 128 db 0
keymin          times 128 db 0
hits            times 128 db 0

s_fps           db "FPS "
s_fps_num       db "000", 0


; cards: ramp, number of lines, title, lines (38 characters at most)
card_tab        dw c_welcome, c_work, c_kyty, c_lab, c_learn, c_gowan, c_openingh, c_gruvbox
                dw c_7os, c_patches, c_github, c_about
c_welcome       db 14, 3, "ALMO7AYA ", 0xFA, " 7MAZE", 0
                db "arrows/WASD to walk, Q/E to strafe", 0
                db "face a poster up close to read it", 0
                db "Ali's work, in a maze. mind the walls", 0
c_work          db 12, 4, "WORK ", 0xFA, " ANGHAMI & OSN+", 0
                db "Staff Web Engineer at Anghami & OSN+.", 0
                db "Web and smart-TV streaming apps,", 0
                db "with a soft spot for video playback", 0
                db "and DRM.", 0
c_kyty          db 5, 4, "KYTYPS5", 0
                db "open-source PS5 emulator, in C++.", 0
                db "Ali contributes fixes: crash-log", 0
                db "build info, controller/keyboard", 0
                db "input, Windows/Linux build fixes.", 0
c_lab           db 7, 3, "PS5 SHADER LAB", 0
                db "a C++20 tool that runs extracted", 0
                db "shaders through KytyPS5's shader", 0
                db "compiler to catch regressions.", 0
c_learn         db 11, 3, "LEARNING KYTYPS5", 0
                db "an interactive course on how a", 0
                db "PS5 emulator works:", 0
                db "almo7aya.dev/leaning-something", 0
c_gowan         db 8, 2, "GOWAN", 0
                db "a multi-WAN SOCKS5 load balancer", 0
                db "for OpenWrt, written in Go.", 0
c_openingh      db 4, 3, "OPENINGH.NVIM", 0
                db "Lua: open the current file on", 0
                db "GitHub from Neovim.", 0
                db "163 stars", 0
c_gruvbox       db 13, 1, "NEOGRUVBOX.NVIM", 0
                db "a gruvbox theme for Neovim.", 0
c_7os           db 9, 2, "7OS", 0
                db "the tiny OS on this site.", 0
                db "7MAZE boots on the same 8086 PC.", 0
c_patches       db 10, 2, "MERGED PATCHES", 0
                db "in Preact, LunarVim, ani-cli", 0
                db "and Live Server.", 0
c_github        db 3, 2, "GITHUB", 0
                db "github.com/Almo7aya", 0
                db "handle: Almo7aya", 0
c_about         db 6, 4, "ABOUT ALI", 0
                db "Ali Almohaya, from Yemen,", 0
                db "living in Riyadh.", 0
                db "Beyond the web: low-level code,", 0
                db "emulation and C++, all for fun.", 0

palette:        incbin "palette.bin"
shade_tab:      incbin "shade.bin"
map:            incbin "map.bin"
mm_map:         incbin "mm.bin"
%include "tables.inc"

        align   512, db 0
code_end:
CODE_SECTORS    equ (code_end - stage2) / 512
TEX_LBA         equ (code_end - $$) / 512
BG_LBA          equ TEX_LBA + TEX_SECTORS
%if code_end - $$ > 0x10000 - 0x7C00
  %error "stage 2 does not fit in segment 0"
%endif
        incbin  "tex.bin"
        incbin  "bg.bin"
