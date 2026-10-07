; 7INTRO · a 90s-style demoscene intro for almo7aya.dev, 8086 real mode
;
;   build:  node os/build.mjs intro   (assets.mjs writes the tables, palettes and music into gen/)
;   run:    qemu-system-i386 -drive format=raw,file=public/os/intro.img
;
; disk layout (512-byte sectors, LBA):
;   0        stage 1: geometry from INT 13h/08h, loads stage 2 to 0000:7E00
;   1..      stage 2: code, palettes, stars, text
;   then     tunnel table, girl, panic frames, song: each loaded into its own segment
;
; timing: PIT channel 0 is reprogrammed to ~70 Hz (divisor 17045). Our INT 08h handler counts
; ticks, plays one PC speaker step per tick (PIT channel 2 + port 61h) and chains to the BIOS
; handler whenever 65536 PIT clocks have passed, so the BIOS clock still runs at 18.2 Hz.
; Every effect is a function of the tick count, so music and pictures stay in step at any
; frame rate. Frames are drawn into a back buffer at 1000:0000 and copied to A000:0000 in
; vertical retrace together with the faded palette.
;
; the show (bars of 112 ticks, 1.6 s):
;   1  0-5    starfield, "ALMO7AYA PRESENTS"
;   2  6-13   fire, a burning "7" from the BIOS font ROM
;   3  14-21  the mascot over copper bars, sine wobble; she panics at the end
;   4  22-29  textured tunnel (precomputed angle/depth table, depth shading)
;   5  30-61  plasma, logo, sine scroller with the bio and projects
;   6  62-69  rotating starfield, greetings
;   Esc restarts from the top, the show also loops on its own.

cpu 8086
bits 16
org 0x7C00

BB_SEG          equ 0x1000              ; back buffer, 320x200
TUN_SEG         equ 0x2000              ; tunnel table, 320x100 words
TEX_SEG         equ 0x3000              ; tunnel texture, 256x256
GIRL_SEG        equ 0x4000              ; 128x128
PANIC_SEG       equ 0x5000              ; 16 x 64x64
PLASMA_SEG      equ 0x6000              ; 320x200
FIRE_SEG        equ 0x7000              ; 160x104
SONG_SEG        equ 0x8000              ; one word per tick

FONT            equ 0x0600              ; copy of the 8x16 font ROM (4096 bytes)
PALW            equ 0x1600              ; the palette being built for this frame (768)
ROWC            equ 0x1900              ; copper: one colour per scanline (200)
YTAB            equ 0x1A00              ; y * 320 (200 words)

PIT_DIV         equ 17045               ; 1193182 / 17045 = 70.0 Hz
BAR             equ 112
P1_END          equ 6 * BAR
P2_END          equ 14 * BAR
P3_END          equ 22 * BAR
P4_END          equ 30 * BAR
P5_END          equ 62 * BAR
SHOW_END        equ 70 * BAR
FADE_T          equ 32
FIRE_DECAY      equ 1
HEAT_MAX        equ 200

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
        mov     ah, 0x08                ; geometry
        int     0x13
        jc      .geo
        mov     al, cl
        and     ax, 0x003F
        jz      .geo
        mov     [spt], ax
        mov     al, dh
        xor     ah, ah
        inc     ax
        mov     [heads], ax
.geo:   xor     ax, ax
        mov     ds, ax
        mov     ax, 0x07E0
        mov     es, ax
        mov     ax, 1
        mov     cx, STAGE2_SECTORS
        call    read_sectors
        jc      disk_fail
        jmp     0x0000:stage2

disk_fail:
        mov     ax, 0x0003
        int     0x10
        mov     si, s_diskerr
.p:     lodsb
        test    al, al
        jz      .h
        mov     ah, 0x0E
        xor     bx, bx
        int     0x10
        jmp     .p
.h:     hlt
        jmp     .h

; AX = LBA, CX = count, ES = segment (offset 0, advances 512 bytes per sector). CF on error
read_sectors:
.next:  push    ax
        push    cx
        xor     dx, dx
        div     word [spt]
        mov     cl, dl
        inc     cl
        xor     dx, dx
        div     word [heads]
        mov     ch, al
        ror     ah, 1
        ror     ah, 1
        and     ah, 0xC0
        or      cl, ah
        mov     dh, dl
        mov     dl, [boot_drive]
        xor     bx, bx
        mov     ax, 0x0201
        int     0x13
        pop     cx
        pop     ax
        jc      .out
        mov     bx, es
        add     bx, 0x20
        mov     es, bx
        inc     ax
        loop    .next
        clc
.out:   ret

boot_drive      db 0x80
spt             dw 63
heads           dw 16
s_diskerr       db "7INTRO: disk read error", 0

        times 510-($-$$) db 0
        dw      0xAA55

; ===================================================================
; stage 2
; ===================================================================
stage2:
        push    ds                      ; the font ROM -> FONT
        mov     ax, 0x1130
        mov     bh, 0x06
        int     0x10
        push    es
        pop     ds
        mov     si, bp
        xor     ax, ax
        mov     es, ax
        mov     di, FONT
        mov     cx, 2048
        rep     movsw
        pop     ds

        mov     si, asset_list          ; the big tables, one segment each
.ld:    lodsw
        test    ax, ax
        jz      .ldone
        mov     es, ax
        lodsw
        mov     bx, ax
        lodsw
        mov     cx, ax
        mov     ax, bx
        push    si
        call    read_sectors
        pop     si
        jc      disk_fail
        jmp     .ld
.ldone:
        mov     ax, 0x0013
        int     0x10
        mov     byte [fade], 0
        call    show_palette            ; black until the show starts

        xor     ax, ax                  ; YTAB
        mov     es, ax
        mov     di, YTAB
        mov     cx, 200
.yt:    stosw
        add     ax, 320
        loop    .yt

        call    gen_texture
        call    gen_plasma
        call    hook_timer

restart:
        cli
        mov     word [ticks], 0
        sti

; -------------------------------------------------------------------
; main loop: pick the part for this tick, draw it, show it in retrace
; -------------------------------------------------------------------
frame:  mov     ax, [ticks]
        cmp     ax, SHOW_END
        jae     restart
        mov     si, parts
.find:  cmp     ax, [si+2]
        jb      .got
        add     si, 8
        jmp     .find
.got:   sub     ax, [si]
        mov     [lt], ax
        mov     bx, [si+2]
        sub     bx, [si]
        mov     [plen], bx
        mov     cx, FADE_T              ; fade in and out at the part edges
        call    tri_level
        mov     [fade], al

        push    si
        mov     si, [si+6]              ; base palette -> PALW
        xor     ax, ax
        mov     es, ax
        mov     di, PALW
        mov     cx, 384
        rep     movsw
        pop     si
        call    [si+4]

        call    vsync
        call    show
        mov     ah, 0x01
        int     0x16
        jz      frame
        xor     ah, ah
        int     0x16
        cmp     ah, 0x01                ; Esc: from the top
        je      restart
        jmp     frame

parts:  dw      0,      P1_END,   part_stars,  pal_stars
        dw      P1_END, P2_END,   part_fire,   pal_fire
        dw      P2_END, P3_END,   part_girl,   pal_girl
        dw      P3_END, P4_END,   part_tunnel, pal_tunnel
        dw      P4_END, P5_END,   part_scroll, pal_scroll
        dw      P5_END, SHOW_END, part_greet,  pal_stars

asset_list:
        dw      TUN_SEG,   (a_tun - $$) / 512,   (a_girl - a_tun) / 512
        dw      GIRL_SEG,  (a_girl - $$) / 512,  (a_panic - a_girl) / 512
        dw      PANIC_SEG, (a_panic - $$) / 512, (a_song - a_panic) / 512
        dw      SONG_SEG,  (a_song - $$) / 512,  (a_end - a_song) / 512
        dw      0

; -------------------------------------------------------------------
; timer: INT 08h at 70 Hz, music, BIOS clock kept at 18.2 Hz
; -------------------------------------------------------------------
old8    dd 0
ticks   dw 0
tick_acc dw 0
cur_div dw 0

hook_timer:
        cli
        mov     ax, [0x08*4]
        mov     [old8], ax
        mov     ax, [0x08*4+2]
        mov     [old8+2], ax
        mov     word [0x08*4], isr8
        mov     word [0x08*4+2], 0
        mov     al, 0x36                ; channel 0, lo/hi, mode 3
        out     0x43, al
        mov     ax, PIT_DIV
        out     0x40, al
        mov     al, ah
        out     0x40, al
        sti
        ret

isr8:   push    ax
        push    bx
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     bx, [ticks]
        inc     word [ticks]
        xor     ax, ax
        cmp     bx, SONG_LEN
        jae     .play
        shl     bx, 1
        mov     ax, SONG_SEG
        mov     ds, ax
        mov     ax, [bx]
        xor     bx, bx
        mov     ds, bx
.play:  cmp     ax, [cur_div]
        je      .chain
        mov     [cur_div], ax
        test    ax, ax
        jz      .off
        mov     bx, ax
        mov     al, 0xB6                ; channel 2, lo/hi, square wave
        out     0x43, al
        mov     al, bl
        out     0x42, al
        mov     al, bh
        out     0x42, al
        in      al, 0x61
        or      al, 3
        out     0x61, al
        jmp     .chain
.off:   in      al, 0x61                ; rest: gate off, speaker off
        and     al, 0xFC
        out     0x61, al
.chain: add     word [tick_acc], PIT_DIV
        jc      .bios
        mov     al, 0x20
        out     0x20, al
        pop     ds
        pop     bx
        pop     ax
        iret
.bios:  pop     ds
        pop     bx
        pop     ax
        jmp     far [cs:old8]           ; the BIOS counts its tick, calls INT 1Ch, sends EOI

; -------------------------------------------------------------------
; frame helpers
; -------------------------------------------------------------------
lt      dw 0                            ; ticks since the part started
plen    dw 0
fade    db 0                            ; 0..64

vsync:  mov     dx, 0x3DA
.a:     in      al, dx
        test    al, 8
        jnz     .a
.b:     in      al, dx
        test    al, 8
        jz      .b
        ret

show:   push    ds                      ; back buffer -> VGA
        mov     ax, BB_SEG
        mov     ds, ax
        mov     ax, 0xA000
        mov     es, ax
        xor     si, si
        xor     di, di
        mov     cx, 32000
        rep     movsw
        pop     ds
show_palette:                           ; PALW * fade / 64 -> DAC
        mov     dx, 0x3C8
        xor     al, al
        out     dx, al
        inc     dx
        mov     si, PALW
        mov     bl, [fade]
        mov     cl, 6
        mov     di, 768
.p:     lodsb
        mul     bl
        shr     ax, cl
        out     dx, al
        dec     di
        jnz     .p
        ret

; AX = phase, BX = length, CX = ramp ticks -> AL = 0..64 (ramps up, holds, ramps down)
tri_level:
        sub     bx, ax
        cmp     bx, ax
        jae     .k
        mov     ax, bx
.k:     cmp     ax, cx
        jb      .m
        mov     ax, cx
.m:     mov     dx, 64
        mul     dx
        div     cx
        ret

; SI = first PALW byte, DI = byte count, BL = level 0..64
scale_pal:
        mov     cl, 6
.s:     mov     al, [si]
        mul     bl
        shr     ax, cl
        mov     [si], al
        inc     si
        dec     di
        jnz     .s
        ret

clear_bb:
        mov     ax, BB_SEG
        mov     es, ax
        xor     di, di
        xor     ax, ax
        mov     cx, 32000
        rep     stosw
        ret

seed    dw 0x7A11
rand:   push    dx                      ; AX = next LCG value (use the high byte)
        mov     ax, [seed]
        mov     dx, 25173
        mul     dx
        add     ax, 13849
        mov     [seed], ax
        pop     dx
        ret

; -------------------------------------------------------------------
; text from the font ROM copy, scaled, one colour per glyph row
; -------------------------------------------------------------------
tsx     dw 1                            ; pixel size
tsy     dw 1
tcol    db 0                            ; colour of glyph row 0
tgrad   db 1                            ; added per glyph row
tsh_on  db 0                            ; drop shadow?
tsh_col db 0
tcur    db 0

; SI = string, DX = y: centred horizontally. ES = BB_SEG
text_center:
        push    si
        xor     cx, cx
.l:     lodsb
        test    al, al
        jz      .e
        inc     cx
        jmp     .l
.e:     pop     si
        push    dx
        mov     ax, [tsx]
        shl     ax, 1
        shl     ax, 1
        mul     cx
        pop     dx
        mov     bx, 160
        sub     bx, ax
; SI = string, BX = x, DX = y. ES = BB_SEG
draw_text:
        cmp     byte [tsh_on], 0
        je      draw_plain
        push    si
        push    bx
        push    dx
        mov     al, [tcol]
        mov     ah, [tgrad]
        push    ax
        mov     al, [tsh_col]
        mov     [tcol], al
        mov     byte [tgrad], 0
        add     bx, [tsx]
        add     dx, [tsy]
        call    draw_plain
        pop     ax
        mov     [tcol], al
        mov     [tgrad], ah
        pop     dx
        pop     bx
        pop     si
draw_plain:
.ch:    lodsb
        test    al, al
        jz      .done
        push    si
        push    bx
        push    dx
        xor     ah, ah
        mov     cl, 4
        shl     ax, cl
        add     ax, FONT
        mov     si, ax
        mov     al, [tcol]
        mov     [tcur], al
        mov     bp, 16
.row:   mov     ah, [si]
        inc     si
        push    bx
        mov     cx, 8
.bit:   shl     ah, 1
        jnc     .nb
        call    tblock
.nb:    add     bx, [tsx]
        loop    .bit
        pop     bx
        add     dx, [tsy]
        mov     al, [tgrad]
        add     [tcur], al
        dec     bp
        jnz     .row
        pop     dx
        pop     bx
        pop     si
        mov     ax, [tsx]
        mov     cl, 3
        shl     ax, cl
        add     bx, ax
        jmp     .ch
.done:  ret

tblock: push    ax                      ; tsx x tsy pixels of [tcur] at (BX, DX)
        push    cx
        push    dx
        push    di
        mov     ax, 320
        mul     dx
        add     ax, bx
        mov     di, ax
        mov     al, [tcur]
        mov     dx, [tsy]
.y:     mov     cx, [tsx]
        rep     stosb
        sub     di, [tsx]
        add     di, 320
        dec     dx
        jnz     .y
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret

; AL = level for the 16 text colours starting at BX (palette index)
text_level:
        push    bx
        mov     di, bx
        shl     di, 1
        add     di, bx
        lea     si, [PALW + di]
        mov     bl, al
        mov     di, 48
        call    scale_pal
        pop     bx
        ret

; ===================================================================
; part 1 / 6 · starfield
; ===================================================================
star_rot db 0
zoff    db 0
sinv    dw 0
cosv    dw 0

draw_stars:
        mov     ax, BB_SEG
        mov     es, ax
        mov     ax, [lt]
        shl     ax, 1
        mov     [zoff], al
        mov     bx, [lt]                ; rotation angle: lt / 3
        mov     ax, bx
        shr     ax, 1
        shr     bx, 1
        shr     bx, 1
        add     bx, ax
        shr     bx, 1
        and     bx, 0xFF
        mov     al, [sine + bx]
        xor     ah, ah
        sub     ax, 32
        mov     [sinv], ax
        add     bl, 64
        mov     al, [sine + bx]
        xor     ah, ah
        sub     ax, 32
        mov     [cosv], ax

        mov     si, stars
        mov     cx, NSTARS
.s:     push    cx
        mov     al, [si+4]
        sub     al, [zoff]
        cmp     al, 3
        jb      .next
        xor     ah, ah
        mov     bp, ax                  ; z
        mov     ax, [si]
        mov     bx, [si+2]
        cmp     byte [star_rot], 0
        je      .proj
        imul    word [cosv]             ; x' = (x cos - y sin) / 32
        mov     di, ax
        mov     ax, [si+2]
        imul    word [sinv]
        sub     di, ax
        mov     ax, [si]                ; y' = (x sin + y cos) / 32
        imul    word [sinv]
        mov     bx, ax
        mov     ax, [si+2]
        imul    word [cosv]
        add     bx, ax
        mov     cl, 5
        sar     di, cl
        sar     bx, cl
        mov     ax, di
.proj:  mov     cx, 64                  ; sx = 160 + x * 64 / z
        imul    cx
        idiv    bp
        add     ax, 160
        cmp     ax, 318
        ja      .next
        mov     di, ax
        mov     ax, bx                  ; sy = 100 + y * 64 / z
        mov     cx, 64
        imul    cx
        idiv    bp
        add     ax, 100
        cmp     ax, 198
        ja      .next
        mov     bx, ax
        shl     bx, 1
        add     di, [YTAB + bx]
        mov     ax, 255                 ; nearer = brighter: 16 + (255 - z) / 8
        sub     ax, bp
        mov     cl, 3
        shr     ax, cl
        add     al, 16
        mov     [es:di], al
        cmp     bp, 90
        jae     .next
        mov     [es:di+1], al           ; near stars are 2x2
        mov     [es:di+320], al
        mov     [es:di+321], al
.next:  add     si, 5
        pop     cx
        dec     cx
        jz      .end
        jmp     .s
.end:   ret

part_stars:
        call    clear_bb
        mov     byte [star_rot], 0
        call    draw_stars
        mov     ax, [lt]                ; the title fades in after 1.3 s
        sub     ax, 90
        jb      .done
        mov     bx, [plen]
        sub     bx, 90
        mov     cx, 60
        call    tri_level
        mov     bx, 224
        call    text_level
        mov     byte [tsh_on], 0
        mov     byte [tcol], 224
        mov     byte [tgrad], 1
        mov     word [tsx], 4
        mov     word [tsy], 4
        mov     si, s_almo
        mov     dx, 46
        call    text_center
        mov     word [tsx], 2
        mov     word [tsy], 2
        mov     si, s_presents
        mov     dx, 124
        call    text_center
.done:  ret

part_greet:
        call    clear_bb
        mov     byte [star_rot], 1
        call    draw_stars
        mov     ax, [lt]
        sub     ax, 16
        jb      .done
        xor     dx, dx
        mov     bx, 168
        div     bx                      ; AX = card, DX = tick in the card
        cmp     ax, 5
        jae     .done
        push    ax
        mov     ax, dx
        mov     bx, 168
        mov     cx, 30
        call    tri_level
        mov     bx, 224
        call    text_level
        pop     bx
        mov     ax, 6
        mul     bx
        mov     bx, ax
        add     bx, cards
        mov     byte [tsh_on], 0
        mov     byte [tcol], 224
        mov     byte [tgrad], 1
        mov     word [tsx], 1
        mov     word [tsy], 2
        push    bx
        mov     si, [bx]
        mov     dx, 58
        call    text_center
        pop     bx
        mov     word [tsx], 2
        push    bx
        mov     si, [bx+2]
        mov     dx, 96
        call    text_center
        pop     bx
        mov     si, [bx+4]
        test    si, si
        jz      .done
        mov     dx, 134
        call    text_center
.done:  ret

; ===================================================================
; part 2 · fire with a burning 7
; ===================================================================
part_fire:
        mov     ax, FIRE_SEG
        mov     es, ax
        mov     di, 102 * 160           ; hot coals in the two rows under the screen
        mov     cx, 320
.sd:    call    rand
        mov     al, ah
        cmp     al, 170
        mov     al, 0
        jb      .st
        mov     al, 255
.st:    stosb
        loop    .sd

        mov     ax, [lt]                ; the 7 catches fire after 0.7 s
        cmp     ax, 48
        jb      .burn
        sub     ax, 48
        mov     cl, 2
        shl     ax, cl
        cmp     ax, HEAT_MAX
        jb      .h
        mov     ax, HEAT_MAX
.h:     mov     [heat], al
        mov     si, FONT + '7' * 16
        mov     di, 10 * 160 + 60
        mov     dx, 16
.gr:    mov     ah, [si]
        inc     si
        push    di
        mov     bx, 8
.gb:    shl     ah, 1
        jnc     .gn
        push    di
        push    ax
        call    rand                    ; each block flickers: heat * (192..255) / 256
        mov     al, ah
        or      al, 0xC0
        mul     byte [heat]
        mov     al, ah
        mov     cx, 5
.gy:    push    cx
        mov     cx, 5
        rep     stosb
        add     di, 160 - 5
        pop     cx
        loop    .gy
        pop     ax
        pop     di
.gn:    add     di, 5
        dec     bx
        jnz     .gb
        pop     di
        add     di, 5 * 160
        dec     dx
        jnz     .gr

.burn:  push    ds                      ; each pixel = average of the 4 below it, minus 1
        mov     ax, FIRE_SEG
        mov     ds, ax
        xor     si, si
        mov     cx, 102 * 160
        xor     bx, bx
.f:     xor     ax, ax
        mov     al, [si+159]
        mov     bl, [si+160]
        add     ax, bx
        mov     bl, [si+161]
        add     ax, bx
        mov     bl, [si+320]
        add     ax, bx
        shr     ax, 1
        shr     ax, 1
        sub     al, FIRE_DECAY
        jnc     .z
        xor     al, al
.z:     mov     [si], al
        inc     si
        loop    .f

        mov     ax, BB_SEG              ; 160x100 -> 320x200
        mov     es, ax
        xor     si, si
        xor     di, di
        mov     dx, 100
.er:    mov     cx, 160
.ec:    lodsb
        mov     ah, al
        mov     [es:di+320], ax
        stosw
        loop    .ec
        add     di, 320
        dec     dx
        jnz     .er
        pop     ds

        cmp     byte [heat], HEAT_MAX       ; once it is fully alight: a crisp 7 at full resolution
        jb      .ret
        mov     byte [tsh_on], 0
        mov     byte [tcol], 255
        mov     byte [tgrad], -5
        mov     word [tsx], 10
        mov     word [tsy], 10
        mov     si, s_seven
        mov     bx, 120
        mov     dx, 20
        call    draw_text
        mov     word [tsx], 1           ; and the name, quietly, under the flames
        mov     word [tsy], 1
        mov     byte [tcol], 0
        mov     byte [tgrad], 0
        mov     si, s_almo
        mov     dx, 182
        call    text_center
.ret:   ret
heat    db 0
s_seven db "7", 0

; ===================================================================
; part 3 · the mascot over copper bars
; ===================================================================
g_seg   dw 0
g_off   dw 0
g_stride dw 0
g_step  dw 0
g_wob   db 1
g_dx    dw 0

part_girl:
        xor     ax, ax                  ; background: a dark gradient
        mov     es, ax
        mov     di, ROWC
        xor     cx, cx
.bg:    mov     al, cl
        shr     al, 1
        shr     al, 1
        inc     al
        stosb
        inc     cx
        cmp     cx, 200
        jb      .bg

        xor     bp, bp                  ; 7 bars on a sine path
.bar:   mov     ax, bp                  ; top = 4 + sine[lt*2 + bar*22] * 5 / 2
        mov     cl, 22
        mul     cl
        mov     bx, [lt]
        shl     bx, 1
        add     bx, ax
        and     bx, 0xFF
        mov     al, [sine + bx]
        xor     ah, ah
        mov     bx, ax
        shl     bx, 1
        shr     ax, 1
        add     bx, ax                  ; 0..157
        add     bx, 4 + ROWC
        mov     ax, bp
        mov     cl, 4
        shl     al, cl
        add     al, 64                  ; this bar's first colour
        xor     cx, cx
.bk:    mov     dl, cl
        cmp     cl, 8
        jb      .up
        mov     dl, 15
        sub     dl, cl
.up:    shl     dl, 1
        inc     dl
        add     dl, al
        mov     [bx], dl
        inc     bx
        inc     cx
        cmp     cx, 16
        jb      .bk
        inc     bp
        cmp     bp, 7
        jb      .bar

        mov     ax, BB_SEG              ; one colour per scanline
        mov     es, ax
        xor     di, di
        mov     si, ROWC
        mov     dx, 200
.fill:  lodsb
        mov     ah, al
        mov     cx, 160
        rep     stosw
        dec     dx
        jnz     .fill

        mov     ax, [plen]              ; last 2 bars: she panics
        sub     ax, 2 * BAR
        cmp     [lt], ax
        jb      .still
        mov     word [g_seg], PANIC_SEG
        mov     ax, [lt]
        shr     ax, 1
        and     ax, 15
        mov     cl, 12
        shl     ax, cl
        mov     [g_off], ax
        mov     word [g_stride], 64
        mov     word [g_step], 85
        mov     byte [g_wob], 0
        call    rand                    ; and shakes
        mov     al, ah
        and     ax, 7
        sub     ax, 4
        mov     [g_dx], ax
        jmp     .blit
.still: mov     word [g_seg], GIRL_SEG
        mov     word [g_off], 0
        mov     word [g_stride], 128
        mov     word [g_step], 170
        mov     byte [g_wob], 1
.blit:  call    blit_wobble

        mov     byte [tsh_on], 1        ; the caption, one line at a time
        mov     byte [tsh_col], 0
        mov     byte [tcol], 240
        mov     byte [tgrad], 1
        mov     word [tsx], 1
        mov     word [tsy], 1
        mov     si, girl_lines
        mov     dx, 10
        mov     cx, 30
.ln:    lodsw
        cmp     ax, 0xFFFF
        je      .ldone
        cmp     [lt], cx
        jb      .ldone
        test    ax, ax
        jz      .skip
        push    si
        push    cx
        push    dx
        mov     si, ax
        mov     bx, 4
        call    draw_text
        pop     dx
        pop     cx
        pop     si
.skip:  add     dx, 17
        add     cx, 22
        jmp     .ln
.ldone: ret

; 192x192 at x=122, y=4, scaled from [g_seg]:[g_off] by [g_step]/256, rows wobble on a sine
blit_wobble:
        mov     ax, BB_SEG
        mov     es, ax
        xor     bp, bp
.row:   mov     ax, bp
        mul     word [g_step]
        mov     al, ah
        xor     ah, ah
        mul     word [g_stride]
        add     ax, [g_off]
        mov     si, ax
        mov     ax, [lt]                ; wobble = sine[y*4 + lt*3] * 3 / 16 - 6
        mov     bx, ax
        shl     ax, 1
        add     ax, bx
        mov     bx, bp
        shl     bx, 1
        shl     bx, 1
        add     bx, ax
        and     bx, 0xFF
        mov     al, [sine + bx]
        xor     ah, ah
        mov     bx, ax
        shl     ax, 1
        add     ax, bx
        mov     cl, 4
        shr     ax, cl
        sub     ax, 6
        cmp     byte [g_wob], 0
        jne     .wob
        mov     ax, [g_dx]
.wob:   add     ax, 122
        mov     bx, bp
        shl     bx, 1
        mov     di, [YTAB + 8 + bx]     ; row y + 4
        add     di, ax
        push    ds
        mov     ds, [g_seg]
        mov     cx, 192
        xor     dx, dx
        xor     bx, bx
.px:    mov     bl, dh
        mov     al, [si+bx]
        add     dx, [cs:g_step]
        test    al, al
        jz      .sk
        mov     [es:di], al
.sk:    inc     di
        loop    .px
        pop     ds
        inc     bp
        cmp     bp, 192
        jb      .row
        ret

; ===================================================================
; part 4 · tunnel
; ===================================================================
save_sp dw 0
rows    dw 0
tu      db 0
tv      db 0

part_tunnel:
        mov     ax, BB_SEG              ; letterbox
        mov     es, ax
        mov     ax, 0xE0E0
        xor     di, di
        mov     cx, 1600
        rep     stosw
        mov     di, 190 * 320
        mov     cx, 1600
        rep     stosw

        mov     ax, [lt]                ; fly forward 3 texels a tick, swing around
        mov     bx, ax
        shl     ax, 1
        add     ax, bx
        mov     [tv], al
        mov     bx, [lt]
        shl     bx, 1
        and     bx, 0xFF
        mov     al, [sine + bx]
        shl     al, 1
        add     al, [lt]
        mov     [tu], al
        mov     dl, [tu]
        mov     dh, [tv]

        cli                             ; SS:SP walks the table, so no interrupts here
        mov     [save_sp], sp
        mov     word [rows], 90
        mov     ax, TUN_SEG
        mov     ss, ax
        mov     sp, 5 * 640             ; table row 5 = scanlines 10, 11
        mov     di, 10 * 320
        mov     ax, TEX_SEG
        mov     ds, ax
        mov     bp, ax
.row:   mov     cx, 320
.px:    pop     bx                      ; BL = angle, BH = depth
        mov     ah, bh
        add     bl, dl
        add     bh, dh
        mov     al, [bx]                ; texel 0..31
        and     ah, 0xE0                ; depth shade
        or      al, ah
        stosb
        loop    .px
        mov     ax, es                  ; double the line
        mov     ds, ax
        mov     si, di
        sub     si, 320
        mov     cx, 160
        rep     movsw
        mov     ds, bp
        dec     word [cs:rows]
        jnz     .row
        xor     ax, ax
        mov     ss, ax
        mov     sp, [cs:save_sp]
        mov     ds, ax
        sti

        mov     ax, [lt]                ; captions over the vanishing point
        sub     ax, 48
        jb      .done
        xor     dx, dx
        mov     bx, 160
        div     bx
        cmp     ax, 5
        jae     .done
        push    ax
        mov     ax, dx
        mov     bx, 160
        mov     cx, 24
        call    tri_level
        push    ax
        mov     bx, 240
        call    text_level
        pop     ax
        mov     byte [tsh_on], 0
        cmp     al, 40
        jb      .nosh
        mov     byte [tsh_on], 1
.nosh:  mov     byte [tsh_col], 224
        mov     byte [tcol], 240
        mov     byte [tgrad], 1
        mov     word [tsx], 3
        mov     word [tsy], 3
        pop     bx
        shl     bx, 1
        mov     si, [tunnel_words + bx]
        mov     dx, 76
        call    text_center
.done:  ret

gen_texture:                            ; texel = ((u * 2) xor v) / 8, 0..31
        mov     ax, TEX_SEG
        mov     es, ax
        xor     di, di
        mov     cl, 3
        xor     dx, dx                  ; DL = u, DH = v
.t:     mov     al, dl
        shl     al, 1
        xor     al, dh
        shr     al, cl
        stosb
        inc     dl
        jnz     .t
        inc     dh
        jnz     .t
        ret

; ===================================================================
; part 5 · plasma, logo, sine scroller
; ===================================================================
gen_plasma:                             ; sin[x] + sin[2y] + sin[x+y] + sin[(x-y)/2], halved: 0..126
        mov     ax, PLASMA_SEG
        mov     es, ax
        xor     di, di
        xor     dx, dx
.row:   xor     cx, cx
.px:    mov     bx, cx
        and     bx, 0xFF
        mov     al, [sine + bx]
        mov     bx, dx
        shl     bx, 1
        and     bx, 0xFF
        add     al, [sine + bx]
        mov     bx, cx
        add     bx, dx
        and     bx, 0xFF
        add     al, [sine + bx]
        mov     bx, cx
        sub     bx, dx
        sar     bx, 1
        and     bx, 0xFF
        add     al, [sine + bx]
        shr     al, 1
        stosb
        inc     cx
        cmp     cx, 320
        jb      .px
        inc     dx
        cmp     dx, 200
        jb      .row
        ret

part_scroll:
        push    ds                      ; plasma -> back buffer
        mov     ax, PLASMA_SEG
        mov     ds, ax
        mov     ax, BB_SEG
        mov     es, ax
        xor     si, si
        xor     di, di
        mov     cx, 32000
        rep     movsw
        pop     ds

        xor     ax, ax                  ; plasma colours rotate
        mov     es, ax
        mov     di, PALW
        xor     cx, cx
.pc:    mov     bx, cx
        add     bx, [lt]
        and     bx, 127
        mov     si, bx
        shl     si, 1
        add     si, bx
        add     si, plasma_cyc
        movsb
        movsb
        movsb
        inc     cx
        cmp     cx, 128
        jb      .pc
        mov     di, PALW + 160 * 3      ; logo colours run through a rainbow
        xor     cx, cx
.rc:    mov     bx, cx
        shl     bx, 1
        add     bx, [lt]
        and     bx, 63
        mov     si, bx
        shl     si, 1
        add     si, bx
        add     si, rainbow
        movsb
        movsb
        movsb
        inc     cx
        cmp     cx, 16
        jb      .rc

        mov     ax, BB_SEG
        mov     es, ax
        mov     byte [tsh_on], 1
        mov     byte [tsh_col], 208
        mov     byte [tcol], 160
        mov     byte [tgrad], 1
        mov     word [tsx], 4
        mov     word [tsy], 4
        mov     bx, [lt]
        shl     bx, 1
        and     bx, 0xFF
        mov     dl, [sine + bx]
        xor     dh, dh
        mov     cl, 3
        shr     dx, cl
        add     dx, 8
        mov     si, s_almo
        call    text_center

; the scroller: 16x32 characters, each screen column follows the sine
        mov     ax, BB_SEG
        mov     es, ax
        xor     bp, bp
.col:   mov     ax, [lt]
        mov     bx, ax
        shl     ax, 1
        add     ax, bx
        add     ax, bp
        sub     ax, 320
        jb      .ncol
        mov     bx, ax
        mov     cl, 4
        shr     bx, cl
        cmp     bx, SCROLL_LEN
        jae     .ncol
        mov     bl, [scroll_text + bx]
        xor     bh, bh
        shl     bx, cl
        add     bx, FONT
        mov     cl, al
        shr     cl, 1
        and     cl, 7
        mov     ah, 0x80
        shr     ah, cl                  ; this column's bit in the glyph
        mov     si, [lt]                ; y = 112 + sine[x*2 + lt*4] * 3 / 4
        shl     si, 1
        add     si, bp
        shl     si, 1
        and     si, 0xFF
        mov     dl, [sine + si]
        xor     dh, dh
        mov     si, dx
        shl     dx, 1
        add     dx, si
        shr     dx, 1
        shr     dx, 1
        add     dx, 112
        mov     si, dx
        shl     si, 1
        mov     di, [YTAB + si]
        add     di, bp
        mov     dl, 192
        mov     cx, 16
.r:     test    [bx], ah
        jz      .n
        mov     [es:di], dl
        mov     [es:di+320], dl
        mov     byte [es:di+642], 208
        mov     byte [es:di+962], 208
.n:     inc     bx
        inc     dl
        add     di, 640
        loop    .r
.ncol:  inc     bp
        cmp     bp, 318
        jb      .col
        ret

; ===================================================================
; data
; ===================================================================
s_almo          db "ALMO7AYA", 0
s_presents      db "PRESENTS", 0

girl_lines      dw g1, g2, 0, g3, g4, g5, 0, g6, g7, g8, g9, 0xFFFF
g1      db "ALI ALMOHAYA", 0
g2      db "aka Almo7aya", 0
g3      db "staff web", 0
g4      db "engineer at", 0
g5      db "Anghami & OSN+", 0
g6      db "web + TV apps,", 0
g7      db "mostly the", 0
g8      db "video player:", 0
g9      db "playback & DRM", 0

tunnel_words    dw w1, w2, w3, w4, w5
w1      db "AFTER HOURS", 0
w2      db "EMULATORS", 0
w3      db "C++", 0
w4      db "GPUS", 0
w5      db "NETWORKING", 0

cards   dw c1a, c1b, c1c
        dw c2a, c2b, 0
        dw c2a, c3b, 0
        dw c2a, c4b, c4c
        dw c5a, c5b, 0
c1a     db "greetings to", 0
c1b     db "EVERYONE WRITING", 0
c1c     db "EMULATORS", 0
c2a     db "and to", 0
c2b     db "THE DEMOSCENE", 0
c3b     db "ALL 8086 CODERS", 0
c4b     db "YOU, FOR", 0
c4c     db "WATCHING", 0
c5a     db "see you at", 0
c5b     db "github.com/Almo7aya", 0

sine:
%include "sine.inc"
%include "data.inc"

stage2_end:
STAGE2_SECTORS  equ (stage2_end - stage2 + 511) / 512

; ===================================================================
; the big tables, sector aligned
; ===================================================================
        align   512, db 0
a_tun:  incbin  "tunnel.bin"
        align   512, db 0
a_girl: incbin  "girl.bin"
        align   512, db 0
a_panic: incbin "panic.bin"
        align   512, db 0
a_song: incbin  "song.bin"
        align   512, db 0
a_end:
