; 7PLAYER · the day job, in 8086
;
; a real-mode streaming video player with a (toy, but real) DRM key ladder and ABR.
;
;   build:  node os/build.mjs player      (assets.mjs makes gen/movie.7mv + gen/keys.inc)
;   run:    qemu-system-i386 -drive format=raw,file=public/os/player.img
;
; disk layout (512-byte sectors, LBA):
;   0          stage 1, the boot sector: loads stage 2 with INT 13h (CHS from AH=08h)
;   1..63      stage 2, this player, loaded at 0000:7E00
;   64..       the 7MV container: header (+license), frame index, encrypted frames
;
; pipeline per frame (12 fps, the PIT reprogrammed to 60 Hz, INT 1Ch counts ticks):
;   "network"  a token bucket of bytes per tick (OK / DOWN / SLOW) pulls frames off the disk
;              with INT 13h into a 16-slot ring buffer; ABR picks the HI (128x128, 16 levels)
;              or LO (64x64, 8 levels) rendition from the measured throughput
;   CDM        frame key = CK xor IV(frame); RC4 KSA + drop256; decrypt the slot in place
;   decoder    RLE (run-1)<<4 | level  -> 128x128 framebuffer (LO is pixel-doubled)
;   renderer   1.5x by 1.25x into mode 13h (aspect correct 192x160), palette 16..31
;
; key ladder (see assets.mjs):
;   DK   = RC4drop256(ROOT ^ MODEL)      ROOT is provisioned in this binary, MODEL is F000:FFFE
;   KEK  = RC4drop256(DK ^ KID|KID)      KID comes with the license in the 7MV header
;   CK   = WRAP ^ KEK, checked against KCV = RC4drop256(CK)[0..3]

cpu 8086
bits 16
org 0x7C00

MOVIE_LBA       equ 64
SBOX            equ 0x0600              ; RC4 state, 256-byte aligned (BH = 06h, BL = index)
HDR             equ 0x0800              ; 7MV header sector
SCR             equ 0x0A00              ; 256 bytes of scratch for keystream drops
FB_SEG          equ 0x1000              ; 128x128 decoded frame
LOFB_SEG        equ 0x1400              ; 64x64 decoded LO frame
IDX_SEG         equ 0x1800              ; frame index, 64 bytes per frame
RING_SEG        equ 0x2000              ; 16 slots of 8 KB
SLOTS           equ 16

VX              equ 4                   ; video window
VY              equ 20
PX              equ 204                 ; right panel text column

PIT_DIV         equ 19886               ; 1193182 / 19886 = 60.0 Hz
TPF             equ 5                   ; ticks per frame: 12 fps
REBUF           equ 8                   ; frames needed to leave buffering
NET_OK          equ 0
NET_DOWN        equ 1
NET_SLOW        equ 2
DOWN_TICKS      equ 120
SLOW_TICKS      equ 420
AUTO_FIRST      equ 540                 ; first automatic network glitch after 9 s of playback
AUTO_TICKS      equ 1500                ; then every 25 s

; colours
C_BG    equ 0
C_PANEL equ 1
C_LINE  equ 2
C_DIM   equ 3
C_TXT   equ 4
C_WHITE equ 5
C_PINK  equ 6
C_CYAN  equ 7
C_GREEN equ 8
C_YEL   equ 9
C_RED   equ 10
C_BUF   equ 11
C_TRACK equ 12
TRANS   equ 0xFF

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
        call    disk_init
        mov     ax, 1
        mov     cx, PROG_SECTORS
        mov     bx, stage2
        call    read_sectors
        jc      .fail
        jmp     0x0000:stage2
.fail:  mov     si, s_diskerr
.p:     lodsb
        test    al, al
        jz      .halt
        mov     ah, 0x0E
        xor     bx, bx
        int     0x10
        jmp     .p
.halt:  hlt
        jmp     .halt

spt     dw 18
heads   dw 2

disk_init:
        mov     ah, 0x08
        mov     dl, [boot_drive]
        push    es
        int     0x13
        pop     es
        jc      .keep
        mov     al, cl
        and     ax, 0x003F
        jz      .keep
        mov     [spt], ax
        mov     al, dh
        xor     ah, ah
        inc     ax
        mov     [heads], ax
.keep:  ret

; AX = LBA, CX = count, ES:BX = buffer. CF set on error. one sector per call, 3 tries
read_sectors:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
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
        mov     si, 3
.try:   mov     ax, 0x0201
        int     0x13
        jnc     .ok
        xor     ax, ax
        int     0x13
        dec     si
        jnz     .try
        pop     cx
        pop     ax
        stc
        jmp     .out
.ok:    pop     cx
        pop     ax
        add     bx, 512
        inc     ax
        loop    .next
        clc
.out:   pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

boot_drive      db 0
s_diskerr       db "7PLAYER: disk read error", 0

        times 510-($-$$) db 0
        dw      0xAA55

; ===================================================================
; stage 2 · at 0000:7E00
; ===================================================================
stage2:
        push    es
        mov     ax, 0x1130              ; 8x16 font ROM -> ES:BP
        mov     bh, 0x06
        int     0x10
        mov     [font_off], bp
        mov     [font_seg], es
        pop     es

        push    ds                      ; the machine's ROM identity: date string + model byte
        mov     ax, 0xF000
        mov     ds, ax
        mov     si, 0xFFF5
        mov     di, bios_date
        mov     cx, 8
        rep     movsb
        mov     al, [0xFFFE]
        pop     ds
        mov     [model], al
        mov     si, bios_date
        mov     cx, 8
.san:   mov     al, [si]
        cmp     al, ' '
        jb      .bad
        cmp     al, 'z'
        jbe     .good
.bad:   mov     byte [si], '?'
.good:  inc     si
        loop    .san

        mov     ax, 0x0013
        int     0x10
        mov     byte [bright], 16
        call    set_ui_palette
        call    hook_timer
        call    intro
        call    license
        call    player_init

main_loop:
        call    wait_tick
        mov     cx, 4                   ; catch up at most 4 ticks per pass
.t:     mov     ax, [last_tick]
        cmp     ax, [ticks]
        je      .done
        inc     word [last_tick]
        push    cx
        call    do_tick
        pop     cx
        loop    .t
        mov     ax, [ticks]
        mov     [last_tick], ax
.done:  call    keys
        call    ui_update
        jmp     main_loop

; -------------------------------------------------------------------
; timer: PIT channel 0 at 60 Hz, INT 1Ch counts
; -------------------------------------------------------------------
hook_timer:
        cli
        mov     ax, [0x1C*4]
        mov     [old_1c], ax
        mov     ax, [0x1C*4+2]
        mov     [old_1c+2], ax
        mov     word [0x1C*4], isr_1c
        mov     word [0x1C*4+2], 0
        mov     al, 0x36
        out     0x43, al
        mov     ax, PIT_DIV
        out     0x40, al
        mov     al, ah
        out     0x40, al
        sti
        mov     ax, [ticks]
        mov     [last_tick], ax
        ret

isr_1c:
        push    ds
        push    ax
        xor     ax, ax
        mov     ds, ax
        inc     word [ticks]
        pop     ax
        pop     ds
        jmp     far [cs:old_1c]

wait_tick:                              ; sleep until INT 1Ch has run
        mov     ax, [last_tick]
.w:     cmp     ax, [ticks]
        jne     .r
        sti
        hlt
        jmp     .w
.r:     ret

; one tick of time for the intro / license screens: AX = ticks since [t0]
next_tick:
        call    wait_tick
        mov     ax, [ticks]
        mov     [last_tick], ax
        sub     ax, [t0]
        ret

start_clock:
        mov     ax, [ticks]
        mov     [t0], ax
        mov     [last_tick], ax
        ret

; ZF=0 and AX = key if one was pressed
get_key:
        mov     ah, 0x01
        int     0x16
        jz      .none
        xor     ah, ah
        int     0x16
        or      ax, ax
        jnz     .r
        inc     ax
.r:     ret
.none:  xor     ax, ax
        ret

; -------------------------------------------------------------------
; palette
; -------------------------------------------------------------------
; AL = first index, SI = RGB triples, CX = count, scaled by [bright]/16
set_dac:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     dx, 0x3C8
        out     dx, al
        inc     dx
        mov     bx, cx
        add     cx, bx
        add     cx, bx
        mov     bl, [bright]
.c:     lodsb
        mul     bl
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        out     dx, al
        loop    .c
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

set_ui_palette:
        mov     byte [bright], 16
        xor     al, al
        mov     si, ui_pal
        mov     cx, 16
        jmp     set_dac

; video palette 16..31 from the container, dimmed while paused / buffering
video_palette:
        mov     al, 16
        cmp     byte [paused], 0
        jne     .dim
        cmp     byte [buffering], 0
        je      .set
.dim:   mov     al, 7
.set:   mov     [bright], al
        mov     al, 16
        mov     si, HDR + 64
        mov     cx, 16
        call    set_dac
        mov     byte [bright], 16
        ret

; -------------------------------------------------------------------
; drawing (ES is saved, VRAM at A000)
; -------------------------------------------------------------------
; BX = x, DX = y, CX = w, SI = h, AL = colour
fill_rect:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        push    ax
        mov     ax, 320
        mul     dx
        add     ax, bx
        mov     di, ax
        pop     ax
        mov     bx, 0xA000
        mov     es, bx
        mov     dx, cx
.r:     mov     cx, dx
        push    di
        rep     stosb
        pop     di
        add     di, 320
        dec     si
        jnz     .r
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; outline: BX = x, DX = y, CX = w, SI = h, AL = colour
frame_rect:
        push    si
        push    dx
        push    si
        mov     si, 1
        call    fill_rect               ; top
        pop     si
        add     dx, si
        dec     dx
        mov     si, 1
        call    fill_rect               ; bottom
        pop     dx
        pop     si
        push    cx
        mov     cx, 1
        call    fill_rect               ; left
        pop     cx
        push    bx
        add     bx, cx
        dec     bx
        push    cx
        mov     cx, 1
        call    fill_rect               ; right
        pop     cx
        pop     bx
        ret

cls:    xor     bx, bx
        xor     dx, dx
        mov     cx, 320
        mov     si, 200
        jmp     fill_rect

; SI = string, BX = x, DX = y, AL = fg, AH = bg (TRANS = none). BX advances
put_str:
        push    ax
        push    cx
        push    dx
        push    si
        push    di
        push    es
        mov     [t_col], ax
        mov     ax, 320
        mul     dx
        add     ax, bx
        mov     di, ax
        mov     ax, 0xA000
        mov     es, ax
.c:     lodsb
        test    al, al
        jz      .e
        call    put_glyph
        add     di, 8
        add     bx, 8
        jmp     .c
.e:     pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

; small-font variant
put_small:
        mov     byte [fsmall], 1
        call    put_str
        mov     byte [fsmall], 0
        ret

; AL = char at ES:DI, colours in [t_col], 8x16 or (fsmall) 8x8 = rows OR'ed in pairs
put_glyph:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        xor     ah, ah
        mov     cl, 4
        shl     ax, cl
        mov     si, [font_off]
        add     si, ax
        mov     bx, [t_col]
        mov     cx, 16
        mov     ds, [font_seg]
        cmp     byte [cs:fsmall], 0
        je      .row
        ; 8x8: rows 2, 3, 4|5, 6, 7, 8|9, 10, 11|12 of the 8x16 glyph (keeps R/A, B/8 apart)
        push    bx
        xor     bx, bx
.sm:    mov     al, [cs:sm_rows + bx]
        cbw
        push    si
        add     si, ax
        mov     al, [si]
        test    byte [cs:sm_or + bx], 1
        jz      .so
        or      al, [si + 1]
.so:    pop     si
        mov     [cs:sglyph + bx], al
        inc     bx
        cmp     bx, 8
        jb      .sm
        pop     bx
        push    cs
        pop     ds
        mov     si, sglyph
        mov     cx, 8
.row:   mov     ah, [si]
        inc     si
        push    cx
        mov     cx, 8
.bit:   shl     ah, 1
        jnc     .off
        mov     [es:di], bl
        jmp     .nx
.off:   cmp     bh, TRANS
        je      .nx
        mov     [es:di], bh
.nx:    inc     di
        loop    .bit
        pop     cx
        add     di, 320-8
        loop    .row
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; 4x scaled transparent text: SI = string, BX = x, DX = y, AL = colour
put_big:
        push    bp
        mov     [big_col], al
.ch:    lodsb
        test    al, al
        jz      .done
        push    si
        push    dx
        xor     ah, ah
        mov     cl, 4
        shl     ax, cl
        mov     bp, ax
        add     bp, [font_off]
        mov     cx, 16
.row:   push    ds
        mov     ds, [font_seg]
        mov     ah, [ds:bp]
        pop     ds
        inc     bp
        push    cx
        push    bx
        mov     cx, 8
.bit:   shl     ah, 1
        jnc     .skip
        push    cx
        push    si
        push    ax
        mov     al, [big_col]
        mov     cx, 4
        mov     si, 4
        call    fill_rect
        pop     ax
        pop     si
        pop     cx
.skip:  add     bx, 4
        loop    .bit
        pop     bx
        pop     cx
        add     dx, 4
        loop    .row
        pop     dx
        pop     si
        add     bx, 32
        jmp     .ch
.done:  pop     bp
        ret

; -------------------------------------------------------------------
; text formatting into DS:DI
; -------------------------------------------------------------------
scpy:   lodsb                           ; SI -> DI, no terminator
        test    al, al
        jz      .r
        mov     [di], al
        inc     di
        jmp     scpy
.r:     ret

hex8:   push    ax                      ; AL -> 2 hex digits at DI
        push    cx
        mov     ah, al
        mov     cl, 4
        shr     al, cl
        call    .n
        mov     al, ah
        and     al, 0x0F
        call    .n
        pop     cx
        pop     ax
        ret
.n:     add     al, '0'
        cmp     al, '9'
        jbe     .s
        add     al, 7
.s:     mov     [di], al
        inc     di
        ret

hexs:   lodsb                           ; CX bytes at SI -> hex at DI
        call    hex8
        loop    hexs
        ret

; AX = value, CX = digits, leading zeros, at DI
dec0:   push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        add     di, cx
        push    di
.l:     xor     dx, dx
        div     bx
        add     dl, '0'
        dec     di
        mov     [di], dl
        loop    .l
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; same with leading spaces
decs:   push    si
        push    cx
        mov     si, di
        call    dec0
        dec     cx
        jz      .r
.z:     cmp     byte [si], '0'
        jne     .r
        mov     byte [si], ' '
        inc     si
        loop    .z
.r:     pop     cx
        pop     si
        ret

; lbuf helpers
lb_start:
        mov     di, lbuf
        ret
lb_end: mov     byte [di], 0
        mov     si, lbuf
        ret

; -------------------------------------------------------------------
; RC4
; -------------------------------------------------------------------
; KSA with the 16-byte key at rc4key, then drop the first 256 bytes
rc4_init:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        xor     ax, ax
        mov     es, ax
        mov     di, SBOX
.id:    stosb
        inc     al
        jnz     .id
        mov     bx, SBOX
        xor     cx, cx                  ; CL = i
        xor     dh, dh                  ; DH = j
.k:     mov     bl, cl
        mov     al, [bx]
        add     dh, al
        mov     si, cx
        and     si, 15
        add     dh, [rc4key + si]
        mov     bl, dh
        mov     ah, [bx]
        mov     [bx], al
        mov     bl, cl
        mov     [bx], ah
        inc     cl
        jnz     .k
        mov     word [rc4_i], 0         ; i = j = 0
        mov     di, SCR                 ; drop256: run the generator over scratch
        mov     cx, 256
        call    rc4_crypt
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ES:DI ^= keystream, CX bytes
rc4_crypt:
        push    ax
        push    bx
        push    cx
        push    dx
        push    di
        mov     dl, [rc4_i]
        mov     dh, [rc4_j]
        mov     bx, SBOX
        jcxz    .done
.p:     inc     dl
        mov     bl, dl
        mov     al, [bx]
        add     dh, al
        mov     bl, dh
        mov     ah, [bx]
        mov     [bx], al
        mov     bl, dl
        mov     [bx], ah
        add     al, ah
        mov     bl, al
        mov     al, [bx]
        xor     [es:di], al
        inc     di
        loop    .p
.done:  mov     [rc4_i], dl
        mov     [rc4_j], dh
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; DI = 16-byte output in segment 0: = first 16 keystream bytes for the key at rc4key
rc4_derive16:
        push    es
        push    cx
        push    di
        xor     ax, ax
        mov     es, ax
        mov     cx, 8
        rep     stosw
        pop     di
        call    rc4_init
        mov     cx, 16
        call    rc4_crypt
        pop     cx
        pop     es
        ret

; -------------------------------------------------------------------
; intro card
; -------------------------------------------------------------------
intro:
        mov     al, C_BG
        call    cls
        mov     byte [bright], 0
        mov     al, 13
        mov     si, intro_pal
        mov     cx, 3
        call    set_dac
        mov     si, s_presents
        mov     bx, 92
        mov     dx, 52
        mov     ax, (TRANS << 8) | 13
        call    put_str
        mov     si, s_title
        mov     bx, 48
        mov     dx, 76
        mov     al, 14
        call    put_big
        mov     si, s_tagline
        mov     bx, 80
        mov     dx, 156
        mov     ax, (TRANS << 8) | 15
        call    put_str
        mov     si, s_about
        mov     bx, 8
        mov     dx, 180
        mov     ax, (TRANS << 8) | 13
        call    put_small
        call    start_clock
.loop:  call    next_tick
        mov     [it], ax
        cmp     ax, 160
        jae     .out
        ; three colours fade in one after another, everything fades out at the end
        mov     bx, 0
        call    .level
        mov     al, 13
        mov     si, intro_pal
        call    .one
        mov     bx, 24
        call    .level
        mov     al, 14
        mov     si, intro_pal + 3
        call    .one
        mov     bx, 52
        call    .level
        mov     al, 15
        mov     si, intro_pal + 6
        call    .one
        ; an accent line that grows from the centre under the title
        mov     ax, [it]
        sub     ax, 24
        jb      .key
        shl     ax, 1
        shl     ax, 1
        cmp     ax, 112
        jbe     .w
        mov     ax, 112
.w:     mov     bx, 160
        sub     bx, ax
        mov     cx, ax
        shl     cx, 1
        jz      .key
        mov     dx, 146
        mov     si, 2
        mov     al, 14
        call    fill_rect
.key:   call    get_key
        jz      .loop
.out:   mov     byte [bright], 16
        mov     al, C_BG
        jmp     cls

; BX = start tick -> [bright] = 0..16 for this element
.level: mov     ax, [it]
        sub     ax, bx
        jae     .pos
        xor     ax, ax
.pos:   mov     cl, 1                   ; 16 steps over 16 ticks... a bit slower: /1.5
        shl     ax, cl
        mov     cl, 3
        xor     dx, dx
        mov     bx, 3
        div     bx                      ; ax*2/3
        cmp     ax, 16
        jbe     .c1
        mov     ax, 16
.c1:    mov     bx, 160                 ; fade out over the last 20 ticks
        sub     bx, [it]
        cmp     bx, 20
        jae     .c2
        mov     cx, bx                  ; out = bx*16/20 = bx*4/5
        shl     cx, 1
        shl     cx, 1
        push    ax
        mov     ax, cx
        xor     dx, dx
        mov     cx, 5
        div     cx
        mov     cx, ax
        pop     ax
        cmp     ax, cx
        jbe     .c2
        mov     ax, cx
.c2:    mov     [bright], al
        ret
.one:   mov     cx, 1
        call    set_dac
        ret

; -------------------------------------------------------------------
; license request: read the container, run the key ladder, show every step
; -------------------------------------------------------------------
lic_row:                                ; AL = row -> DX = y
        mov     ah, 14
        mul     ah
        add     ax, 30
        mov     dx, ax
        ret

; AL = row, SI = label; lbuf = value
lic_line:
        push    ax
        call    lic_row
        mov     bx, 8
        mov     ax, (TRANS << 8) | C_CYAN
        call    put_small
        mov     bx, 96
        mov     si, lbuf
        mov     ax, (TRANS << 8) | C_WHITE
        call    put_small
        pop     ax
        ret

; AL = row: green OK at the right
lic_ok: call    lic_row
        mov     bx, 296
        mov     si, s_ok
        mov     ax, (TRANS << 8) | C_GREEN
        jmp     put_small

lic_pause:                              ; wait 12 ticks, or nothing once a key was pressed
        cmp     byte [fast], 0
        jne     .r
        call    start_clock
.w:     call    get_key
        jz      .n
        mov     byte [fast], 1
        ret
.n:     call    next_tick
        cmp     ax, 16
        jb      .w
.r:     ret

license:
        mov     al, C_BG
        call    cls
        xor     bx, bx
        xor     dx, dx
        mov     cx, 320
        mov     si, 20
        mov     al, C_PANEL
        call    fill_rect
        mov     dx, 20
        mov     si, 1
        mov     al, C_LINE
        call    fill_rect
        mov     si, s_licreq
        mov     bx, 8
        mov     dx, 2
        mov     ax, (TRANS << 8) | C_WHITE
        call    put_str
        mov     si, s_title
        mov     bx, 256
        mov     dx, 2
        mov     ax, (TRANS << 8) | C_PINK
        call    put_str
        mov     si, s_toy
        mov     bx, 8
        mov     dx, 186
        mov     ax, (TRANS << 8) | C_DIM
        call    put_small

        ; 0: the container header
        call    lic_pause
        xor     ax, ax
        mov     es, ax
        mov     ax, MOVIE_LBA
        mov     cx, 1
        mov     bx, HDR
        call    read_sectors
        jc      .diskerr
        cmp     word [HDR], '7M'
        jne     .diskerr
        mov     ax, IDX_SEG
        mov     es, ax
        mov     ax, MOVIE_LBA + 1
        mov     cx, [HDR + 10]
        xor     bx, bx
        call    read_sectors
        push    ds
        pop     es
        jc      .diskerr
        mov     ax, [HDR + 4]
        mov     [frames], ax
        mov     ax, [HDR + 56]          ; HI threshold: need = avg / 5 bytes per tick, x1.5
        mov     cx, 3
        mul     cx
        mov     cx, 10
        div     cx
        mov     [hi_thr], ax
        call    lb_start
        mov     si, HDR + 12
        call    scpy
        mov     byte [di], ' '
        inc     di
        mov     ax, [frames]
        mov     cx, 2
        call    dec0
        mov     si, s_fr12
        call    scpy
        call    lb_end
        mov     al, 0
        mov     si, s_l_media
        call    lic_line
        mov     al, 0
        call    lic_ok

        ; 1: the ROM identity
        call    lic_pause
        call    lb_start
        mov     si, bios_date
        call    scpy
        mov     si, s_model
        call    scpy
        mov     al, [model]
        call    hex8
        call    lb_end
        mov     al, 1
        mov     si, s_l_rom
        call    lic_line

        ; 2: device key
        call    lic_pause
        mov     si, root_key
        mov     di, rc4key
        mov     cx, 8
        rep     movsw
        mov     al, [model]
        xor     [rc4key + 15], al
        mov     di, dev_key
        call    rc4_derive16
        call    lb_start
        mov     si, s_dkf
        call    scpy
        mov     al, [model]
        call    hex8
        mov     byte [di], ')'
        inc     di
        mov     byte [di], ' '
        inc     di
        mov     si, dev_key
        mov     cx, 4
        call    hexs
        mov     si, s_dots
        call    scpy
        call    lb_end
        mov     al, 2
        mov     si, s_l_dev
        call    lic_line
        mov     al, 2
        call    lic_ok

        ; 3, 4: license request / response
        call    lic_pause
        call    lb_start
        mov     si, s_req
        call    scpy
        mov     si, HDR + 28
        mov     cx, 8
        call    hexs
        call    lb_end
        mov     al, 3
        mov     si, s_l_lic
        call    lic_line
        call    lic_pause
        call    lb_start
        mov     si, s_resp
        call    scpy
        mov     si, HDR + 36
        mov     cx, 6
        call    hexs
        mov     si, s_dots
        call    scpy
        call    lb_end
        mov     al, 4
        mov     si, s_empty
        call    lic_line
        mov     al, 4
        call    lic_ok

        ; 5: unwrap
        call    lic_pause
        xor     bx, bx
.kek:   mov     al, [dev_key + bx]
        mov     si, bx
        and     si, 7
        xor     al, [HDR + 28 + si]
        mov     [rc4key + bx], al
        inc     bx
        cmp     bx, 16
        jb      .kek
        mov     di, kek
        call    rc4_derive16
        xor     bx, bx
.ck:    mov     al, [kek + bx]
        xor     al, [HDR + 36 + bx]
        mov     [ck + bx], al
        inc     bx
        cmp     bx, 16
        jb      .ck
        call    lb_start
        mov     si, s_unwrap
        call    scpy
        call    lb_end
        mov     al, 5
        mov     si, s_l_unwrap
        call    lic_line

        ; 6: key check value
        call    lic_pause
        mov     si, ck
        mov     di, rc4key
        mov     cx, 8
        rep     movsw
        mov     di, kcv
        call    rc4_derive16
        call    lb_start
        mov     si, s_kcv
        call    scpy
        mov     si, kcv
        mov     cx, 4
        call    hexs
        call    lb_end
        mov     al, 6
        mov     si, s_l_check
        call    lic_line
        mov     ax, [kcv]
        cmp     ax, [HDR + 52]
        jne     .denied
        mov     ax, [kcv + 2]
        cmp     ax, [HDR + 54]
        jne     .denied
        mov     al, 6
        call    lic_ok

        ; 7, 8
        call    lic_pause
        call    lb_start
        mov     si, s_loaded
        call    scpy
        call    lb_end
        mov     al, 7
        mov     si, s_l_key
        call    lic_line
        mov     al, 7
        call    lic_ok
        call    lic_pause
        call    lb_start
        mov     si, s_opening
        call    scpy
        call    lb_end
        mov     al, 8
        mov     si, s_l_stream
        call    lic_line
        call    lic_pause
        call    lic_pause
        call    lic_pause
        call    lic_pause
        ret

.diskerr:
        mov     si, s_diskerr
        jmp     .fatal
.denied:
        mov     al, 6
        call    lic_row
        mov     bx, 280
        mov     si, s_fail
        mov     ax, (TRANS << 8) | C_RED
        call    put_small
        mov     si, s_denied
.fatal: mov     bx, 8
        mov     dx, 160
        mov     ax, (TRANS << 8) | C_RED
        call    put_str
.stop:  sti
        hlt
        jmp     .stop

; -------------------------------------------------------------------
; the player
; -------------------------------------------------------------------
player_init:
        mov     al, C_BG
        call    cls
        ; header
        xor     bx, bx
        xor     dx, dx
        mov     cx, 320
        mov     si, 18
        mov     al, C_PANEL
        call    fill_rect
        mov     si, s_seven
        mov     bx, 6
        mov     dx, 1
        mov     ax, (TRANS << 8) | C_PINK
        call    put_str
        mov     si, s_player
        mov     ax, (TRANS << 8) | C_WHITE
        call    put_str
        mov     si, s_hdr
        mov     bx, 72
        mov     dx, 6
        mov     ax, (TRANS << 8) | C_DIM
        call    put_small
        ; video frame
        mov     bx, VX - 1
        mov     dx, VY - 1
        mov     cx, 194
        mov     si, 162
        mov     al, C_LINE
        call    frame_rect
        ; right panel
        mov     bx, 200
        mov     dx, 19
        mov     cx, 120
        mov     si, 163
        mov     al, C_PANEL
        call    fill_rect
        ; bottom bar
        xor     bx, bx
        mov     dx, 182
        mov     cx, 320
        mov     si, 18
        call    fill_rect
        ; panel labels
        mov     di, labels
.lab:   mov     dx, [di]
        test    dx, dx
        jz      .labd
        mov     si, [di + 2]
        mov     bx, PX
        mov     ax, (C_PANEL << 8) | C_CYAN
        call    put_small
        add     di, 4
        jmp     .lab
.labd:  mov     si, s_stream
        mov     bx, PX
        mov     dx, 32
        mov     ax, (C_PANEL << 8) | C_WHITE
        call    put_small
        mov     si, s_stream2
        mov     bx, PX
        mov     dx, 42
        mov     ax, (C_PANEL << 8) | C_TXT
        call    put_small
        mov     si, s_drm
        mov     bx, PX + 32
        mov     dx, 132
        mov     ax, (C_PANEL << 8) | C_WHITE
        call    put_small
        mov     si, s_licok
        mov     bx, PX
        mov     dx, 142
        mov     ax, (C_PANEL << 8) | C_GREEN
        call    put_small
        call    lb_start
        mov     si, s_kid
        call    scpy
        mov     si, HDR + 28
        mov     cx, 5
        call    hexs
        call    lb_end
        mov     bx, PX
        mov     dx, 152
        mov     ax, (C_PANEL << 8) | C_TXT
        call    put_small
        mov     si, s_hints
        mov     bx, 180
        mov     dx, 190
        mov     ax, (C_PANEL << 8) | C_DIM
        call    put_small
        ; graph box
        mov     bx, PX - 1
        mov     dx, 75
        mov     cx, 114
        mov     si, 24
        mov     al, C_LINE
        call    frame_rect

        ; state
        mov     word [est], 1600        ; optimistic first estimate
        mov     byte [buffering], 1
        mov     word [auto_t], AUTO_TICKS - AUTO_FIRST
        push    es                      ; framebuffer starts as ink
        mov     ax, FB_SEG
        mov     es, ax
        xor     di, di
        mov     cx, 8192
        mov     ax, 0x1010
        rep     stosw
        pop     es
        call    video_palette
        call    refresh_video
        mov     byte [dirty], 0xFF
        ret

; -------------------------------------------------------------------
; one 60 Hz tick: sound, network, playback clock
; -------------------------------------------------------------------
do_tick:
        cmp     byte [snd_t], 0
        je      .s
        dec     byte [snd_t]
        jnz     .s
        call    spk_off
.s:     cmp     word [net_t], 0         ; network weather
        je      .nst
        dec     word [net_t]
        jnz     .nst
        cmp     byte [net], NET_DOWN
        jne     .toOK
        mov     byte [net], NET_SLOW
        mov     word [net_t], SLOW_TICKS
        jmp     .nst
.toOK:  mov     byte [net], NET_OK
.nst:   cmp     byte [paused], 0
        jne     .ag
        inc     word [auto_t]
        cmp     word [auto_t], AUTO_TICKS
        jb      .ag
        call    glitch
.ag:    call    net_tick
        inc     byte [gr_t]             ; throughput graph sample every 15 ticks
        cmp     byte [gr_t], 15
        jb      .pb
        mov     byte [gr_t], 0
        mov     si, graph + 1
        mov     di, graph
        mov     cx, 27
        push    es
        push    ds
        pop     es
        rep     movsb
        pop     es
        mov     ax, [est]
        mov     cl, 80
        div     cl
        cmp     al, 20
        jbe     .gh
        mov     al, 20
.gh:    mov     [graph + 27], al
        or      byte [dirty], D_GRAPH
.pb:    cmp     byte [buffering], 0
        je      .play
        inc     byte [spin_t]
        mov     al, [ring_count]
        cmp     al, REBUF
        jb      .r
        call    end_buffering
.r:     ret
.play:  cmp     byte [paused], 0
        jne     .r
        inc     byte [frame_t]
        cmp     byte [frame_t], TPF
        jb      .r
        mov     byte [frame_t], 0
        cmp     byte [ring_count], 0
        jne     .pr
        inc     word [stalls]
        jmp     start_buffering
.pr:    jmp     present

glitch: mov     byte [net], NET_DOWN
        mov     word [net_t], DOWN_TICKS
        mov     word [auto_t], 0
        or      byte [dirty], D_STATS
        ret

; AL = rendition the ABR wants: 0 HI if the estimate covers 1.5x its bitrate, else 1 LO
abr:    mov     ax, [est]
        cmp     ax, [hi_thr]
        mov     al, 0
        jae     .r
        inc     al
.r:     ret

; AX = size of frame dl_pos in rendition dl_rend
need_len:
        push    si
        push    es
        mov     ax, IDX_SEG
        mov     es, ax
        mov     si, [dl_pos]
        mov     cl, 6
        shl     si, cl
        cmp     byte [dl_rend], 0
        je      .h
        add     si, 4
.h:     mov     ax, [es:si + 2]
        pop     es
        pop     si
        ret

; the network: bytes per tick, frames move when enough bytes have "arrived"
net_tick:
        mov     bl, [net]
        xor     bh, bh
        shl     bx, 1
        mov     ax, [bw_table + bx]
        mov     [bw], ax
        mov     [avail], ax
        mov     al, [in_prog]
        mov     [moved], al
        cmp     byte [in_prog], 0       ; abandon a HI download when we're about to run dry
        je      .loop
        cmp     byte [dl_rend], 0
        jne     .loop
        cmp     byte [ring_count], 4
        jae     .loop
        call    abr
        test    al, al
        jz      .loop
        mov     byte [dl_rend], 1
        call    need_len
        mov     [need], ax
.loop:  cmp     byte [in_prog], 0
        jne     .have
        cmp     byte [ring_count], SLOTS
        jae     .done
        call    abr
        mov     [dl_rend], al
        call    need_len
        mov     [need], ax
        mov     byte [in_prog], 1
        mov     byte [moved], 1
.have:  mov     ax, [avail]
        cmp     ax, [need]
        jb      .part
        sub     ax, [need]
        mov     [avail], ax
        call    fetch_frame
        mov     byte [in_prog], 0
        jmp     .loop
.part:  sub     [need], ax
.done:  cmp     byte [moved], 0         ; bytes moved this tick: a throughput sample
        je      .idle
        mov     ax, [bw]
        sub     ax, [est]
        mov     cl, 3
        sar     ax, cl
        jnz     .add
        cmp     word [bw], 0            ; let the estimate reach 0 too
        jne     .idle
        cmp     word [est], 0
        je      .idle
        dec     ax
.add:   add     [est], ax
.idle:  ret

; read frame dl_pos (rendition dl_rend) from the disk into the ring tail
fetch_frame:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    es
        mov     bl, [ring_head]
        add     bl, [ring_count]
        and     bx, SLOTS - 1
        mov     ax, IDX_SEG
        mov     es, ax
        mov     si, [dl_pos]
        mov     cl, 6
        shl     si, cl
        cmp     byte [dl_rend], 0
        je      .h
        add     si, 4
.h:     mov     ax, [es:si]             ; LBA inside the container
        mov     dx, [es:si + 2]         ; bytes
        mov     cx, [dl_pos]
        mov     si, bx
        shl     si, 1
        mov     [slot_len + si], dx
        mov     [slot_frame + si], cx
        mov     cl, [dl_rend]
        mov     [slot_rend + bx], cl
        add     [rx_bytes], dx
        add     ax, MOVIE_LBA
        mov     cx, dx
        add     cx, 511
        mov     cl, ch
        shr     cl, 1
        xor     ch, ch
        mov     dx, bx                  ; ES = RING_SEG + slot * 200h
        push    cx
        mov     cl, 9
        shl     dx, cl
        pop     cx
        add     dx, RING_SEG
        mov     es, dx
        xor     bx, bx
        call    read_sectors
        jnc     .ok
        inc     word [io_err]
.ok:    inc     byte [ring_count]
        mov     ax, [dl_pos]
        inc     ax
        cmp     ax, [frames]
        jb      .w
        xor     ax, ax
.w:     mov     [dl_pos], ax
        or      byte [dirty], D_STATS
        pop     es
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

start_buffering:
        mov     byte [buffering], 1
        call    video_palette
        call    draw_spinner_box
        or      byte [dirty], D_STATUS | D_STATS
        ret

end_buffering:
        mov     byte [buffering], 0
        mov     byte [seeking], 0
        mov     byte [frame_t], TPF - 1  ; show the next frame straight away
        call    video_palette
        call    refresh_video
        or      byte [dirty], D_STATUS | D_STATS
        ret

; -------------------------------------------------------------------
; present: decrypt (CDM), decode, render the frame at the ring head
; -------------------------------------------------------------------
present:
        mov     bl, [ring_head]
        xor     bh, bh
        mov     si, bx
        shl     si, 1
        mov     ax, [slot_frame + si]
        mov     [shown], ax
        mov     cx, [slot_len + si]
        mov     [cur_len], cx
        mov     al, [slot_rend + bx]
        mov     [cur_rend], al
        ; frame key = CK ^ IV
        push    es
        mov     ax, IDX_SEG
        mov     es, ax
        mov     si, [shown]
        mov     cl, 6
        shl     si, cl
        add     si, 8
        cmp     byte [cur_rend], 0
        je      .hi
        add     si, 16
.hi:    xor     di, di
.fk:    mov     al, [es:si]
        inc     si
        mov     [cur_iv + di], al
        xor     al, [ck + di]
        mov     [rc4key + di], al
        inc     di
        cmp     di, 16
        jb      .fk
        call    rc4_init
        mov     ax, bx                  ; decrypt the slot in place
        mov     cl, 9
        shl     ax, cl
        add     ax, RING_SEG
        mov     es, ax
        xor     di, di
        mov     cx, [cur_len]
        call    rc4_crypt
        pop     es
        ; decode
        push    ds
        push    es
        mov     dx, [cur_len]
        mov     ds, ax
        xor     si, si
        mov     ax, FB_SEG
        mov     bp, 16384
        cmp     byte [cs:cur_rend], 0
        je      .dec
        mov     ax, LOFB_SEG
        mov     bp, 4096
.dec:   mov     es, ax
        xor     di, di
        call    rle_decode
        cmp     byte [cs:cur_rend], 0
        je      .noexp
        call    expand_lo
.noexp: pop     es
        pop     ds
        mov     al, [ring_head]
        inc     al
        and     al, SLOTS - 1
        mov     [ring_head], al
        dec     byte [ring_count]
        call    refresh_video
        or      byte [dirty], D_PROG | D_STATS
        cmp     byte [snd], 0           ; a note per frame, synced to the clip
        je      .r
        mov     bx, [shown]
        and     bx, 15
        shl     bx, 1
        mov     ax, [melody + bx]
        test    ax, ax
        jz      .r
        call    spk_on
        mov     byte [snd_t], 3
.r:     ret

; DS:SI = RLE, DX = its length, ES:DI = out, BP = pixels
rle_decode:
        mov     bx, dx
.l:     cmp     si, bx
        jae     .fill
        cmp     di, bp
        jae     .r
        lodsb
        mov     ah, al
        and     al, 0x0F
        or      al, 0x10
        mov     cl, 4
        shr     ah, cl
        mov     cl, ah
        xor     ch, ch
        inc     cx
        rep     stosb
        jmp     .l
.fill:  mov     cx, bp                  ; short data: clear the rest
        sub     cx, di
        jbe     .r
        mov     al, 0x10
        rep     stosb
.r:     ret

; LOFB 64x64 -> FB 128x128, pixel doubled
expand_lo:
        mov     ax, LOFB_SEG
        mov     ds, ax
        mov     ax, FB_SEG
        mov     es, ax
        xor     si, si
        xor     di, di
        mov     dx, 64
.row:   mov     cx, 64
.px:    lodsb
        mov     ah, al
        stosw
        loop    .px
        push    si
        push    ds
        push    es
        pop     ds
        mov     si, di
        sub     si, 128
        mov     cx, 64
        rep     movsw
        pop     ds
        pop     si
        dec     dx
        jnz     .row
        ret

; framebuffer -> screen, then whatever sits on top of the video
refresh_video:
        call    blit
        cmp     byte [debug], 0
        je      .nd
        call    draw_debug
.nd:    cmp     byte [buffering], 0
        je      .np
        jmp     draw_spinner_box
.np:    cmp     byte [paused], 0
        je      .r
        call    draw_pause
.r:     ret

; 128x128 -> 192x160: columns a a b, every 4th row twice
blit:   push    ds
        push    es
        mov     ax, FB_SEG
        mov     ds, ax
        mov     ax, 0xA000
        mov     es, ax
        xor     si, si
        mov     di, VY*320 + VX
        xor     dx, dx                  ; source row
.row:   push    di
        mov     cx, 64
.x:     lodsw
        stosb
        stosw
        loop    .x
        pop     di
        add     di, 320
        mov     al, dl
        and     al, 3
        cmp     al, 3
        jne     .n
        push    si
        push    ds
        push    es
        pop     ds
        mov     si, di
        sub     si, 320
        push    di
        mov     cx, 96
        rep     movsw
        pop     di
        pop     ds
        pop     si
        add     di, 320
.n:     inc     dx
        cmp     dx, 128
        jb      .row
        pop     es
        pop     ds
        ret

; -------------------------------------------------------------------
; overlays on the video
; -------------------------------------------------------------------
SPX     equ VX + 96
SPY     equ VY + 72

draw_spinner_box:
        mov     bx, SPX - 60
        mov     dx, SPY - 20
        mov     cx, 120
        mov     si, 56
        mov     al, C_BG
        call    fill_rect
        mov     al, C_LINE
        call    frame_rect
draw_spinner:
        push    bp
        mov     bl, [spin_t]
        shr     bl, 1
        shr     bl, 1
        and     bl, 7                   ; head dot
        mov     [spin_head], bl
        xor     bp, bp
.dot:   mov     ax, bp
        sub     al, [spin_head]
        neg     al
        and     al, 7                   ; distance behind the head
        mov     ah, C_WHITE
        jz      .c
        mov     ah, C_TXT
        cmp     al, 1
        je      .c
        mov     ah, C_DIM
        cmp     al, 2
        je      .c
        mov     ah, C_LINE
        cmp     al, 3
        je      .c
        mov     ah, C_PANEL
.c:     mov     al, ah
        mov     si, bp
        shl     si, 1
        mov     bl, [spin_xy + si]
        mov     dl, [spin_xy + si + 1]
        mov     bh, 0
        mov     dh, 0
        test    bl, 0x80
        jz      .xp
        mov     bh, 0xFF
.xp:    test    dl, 0x80
        jz      .yp
        mov     dh, 0xFF
.yp:    add     bx, SPX - 2
        add     dx, SPY - 4
        mov     cx, 5
        mov     si, 4
        call    fill_rect
        inc     bp
        cmp     bp, 8
        jb      .dot
        pop     bp
        ; caption + how full the rebuffer goal is
        call    lb_start
        mov     si, s_buffering
        cmp     byte [seeking], 0
        je      .cap
        mov     si, s_seeking
.cap:   call    scpy
        mov     al, [ring_count]
        cmp     al, REBUF
        jbe     .pc
        mov     al, REBUF
.pc:    mov     ah, 25
        mul     ah
        shr     ax, 1
        mov     cx, 3
        call    decs
        mov     byte [di], '%'
        inc     di
        call    lb_end
        mov     bx, SPX - 56
        mov     dx, SPY + 18
        mov     ax, (C_BG << 8) | C_WHITE
        call    put_small
        ret

draw_pause:
        mov     bx, SPX - 14
        mov     dx, SPY - 16
        mov     cx, 10
        mov     si, 32
        mov     al, C_WHITE
        call    fill_rect
        add     bx, 18
        call    fill_rect
        mov     si, s_paused
        mov     bx, SPX - 24
        mov     dx, SPY + 24
        mov     ax, (C_BG << 8) | C_WHITE
        jmp     put_small

; DRM debug: key ladder, IV, RC4 state and the S-box as a picture
DBX     equ VX
DBY     equ VY + 94
draw_debug:
        mov     bx, DBX
        mov     dx, DBY
        mov     cx, 192
        mov     si, 66
        mov     al, C_BG
        call    fill_rect
        mov     al, C_PINK
        call    frame_rect
        mov     dx, DBY + 3
        mov     si, s_dbg0
        mov     bx, DBX + 4
        mov     ax, (C_BG << 8) | C_PINK
        call    put_small
        ; DK / KID / CK / IV lines: label + 7 bytes
        mov     bp, dbg_rows
.line:  mov     si, [bp]
        test    si, si
        jz      .ij
        add     dx, 9
        call    lb_start
        call    scpy
        mov     si, [bp + 2]
        mov     cx, 7
        call    hexs
        call    lb_end
        mov     bx, DBX + 4
        mov     ax, (C_BG << 8) | C_TXT
        call    put_small
        add     bp, 4
        jmp     .line
.ij:    add     dx, 9
        call    lb_start
        mov     si, s_dbg_i
        call    scpy
        mov     al, [rc4_i]
        call    hex8
        mov     si, s_dbg_j
        call    scpy
        mov     al, [rc4_j]
        call    hex8
        mov     si, s_dbg_s
        call    scpy
        mov     si, SBOX
        mov     cx, 2
        call    hexs
        call    lb_end
        mov     bx, DBX + 4
        mov     ax, (C_BG << 8) | C_WHITE
        call    put_small
        ; the RC4 state after this frame, 16x16 cells of 3x3, shade = S[k] >> 4
        push    es
        mov     ax, 0xA000
        mov     es, ax
        mov     di, (DBY + 9) * 320 + DBX + 140
        mov     si, SBOX
        mov     dx, 16
.sr:    mov     cx, 16
.sc:    lodsb
        push    cx
        mov     cl, 4
        shr     al, cl
        or      al, 0x10
        mov     ah, al
        stosw
        stosb
        mov     [es:di + 317], ax
        mov     [es:di + 319], al
        mov     [es:di + 637], ax
        mov     [es:di + 639], al
        pop     cx
        loop    .sc
        add     di, 3 * 320 - 48
        dec     dx
        jnz     .sr
        pop     es
        ret

; -------------------------------------------------------------------
; keys
; -------------------------------------------------------------------
keys:   call    get_key
        jz      .r
        cmp     al, ' '
        je      .pause
        cmp     ah, 0x4B
        je      .left
        cmp     ah, 0x4D
        je      .right
        or      al, 0x20
        cmp     al, 'd'
        je      .debug
        cmp     al, 'n'
        je      .net
        cmp     al, 'm'
        je      .snd
.r:     ret
.pause: xor     byte [paused], 1
        call    spk_off
        call    video_palette
        call    refresh_video
        or      byte [dirty], D_STATUS | D_PROG
        ret
.debug: xor     byte [debug], 1
        jmp     refresh_video
.net:   call    glitch
        ret
.snd:   xor     byte [snd], 1
        call    spk_off
        or      byte [dirty], D_STATUS
        ret
.left:  mov     ax, [shown]
        sub     ax, 24
        jae     .seek
        add     ax, [frames]
        jmp     .seek
.right: mov     ax, [shown]
        add     ax, 24
        cmp     ax, [frames]
        jb      .seek
        sub     ax, [frames]
.seek:  mov     [dl_pos], ax            ; flush the buffer and stream from there
        mov     [shown], ax
        mov     byte [ring_count], 0
        mov     byte [in_prog], 0
        mov     byte [seeking], 1
        or      byte [dirty], D_PROG
        jmp     start_buffering

; -------------------------------------------------------------------
; PC speaker
; -------------------------------------------------------------------
spk_on: push    ax                      ; AX = PIT divisor
        mov     al, 0xB6
        out     0x43, al
        pop     ax
        out     0x42, al
        mov     al, ah
        out     0x42, al
        in      al, 0x61
        or      al, 3
        out     0x61, al
        ret
spk_off:
        in      al, 0x61
        and     al, 0xFC
        out     0x61, al
        ret

; -------------------------------------------------------------------
; UI refresh
; -------------------------------------------------------------------
D_STATS  equ 1
D_PROG   equ 2
D_STATUS equ 4
D_GRAPH  equ 8

ui_update:
        cmp     byte [buffering], 0
        je      .ns
        mov     al, [spin_t]
        cmp     al, [spin_drawn]
        je      .ns
        mov     [spin_drawn], al
        test    al, 3
        jnz     .ns
        call    draw_spinner
.ns:    inc     byte [ui_t]
        mov     al, [dirty]
        test    al, D_PROG
        jz      .a
        call    draw_progress
.a:     test    byte [dirty], D_STATUS
        jz      .b
        call    draw_status
.b:     test    byte [dirty], D_GRAPH
        jz      .c
        call    draw_graph
.c:     test    byte [dirty], D_STATS
        jz      .d
        call    draw_stats
.d:     mov     byte [dirty], 0
        ret

draw_status:
        mov     si, s_st_play
        mov     al, C_GREEN
        cmp     byte [paused], 0
        je      .b
        mov     si, s_st_pause
        mov     al, C_YEL
.b:     cmp     byte [buffering], 0
        je      .p
        mov     si, s_st_buf
        mov     al, C_PINK
.p:     mov     ah, C_PANEL
        mov     bx, 236
        mov     dx, 6
        call    put_small
        mov     si, s_snd_off
        mov     al, C_DIM
        cmp     byte [snd], 0
        je      .s
        mov     si, s_snd_on
        mov     al, C_CYAN
.s:     mov     bx, 288
        mov     dx, 190
        mov     ah, C_PANEL
        jmp     put_small

; progress: 288 px for the whole stream, 3 per frame; buffered part ahead of the playhead
PBX     equ 16
PBY     equ 184
draw_progress:
        mov     bx, PBX
        mov     dx, PBY
        mov     cx, 288
        mov     si, 4
        mov     al, C_TRACK
        call    fill_rect
        mov     ax, [shown]
        inc     ax
        mov     cx, ax
        shl     cx, 1
        add     cx, ax                  ; played px
        push    cx
        mov     al, [ring_count]        ; buffered, clipped at the end
        xor     ah, ah
        mov     bx, ax
        shl     ax, 1
        add     ax, bx
        add     ax, cx
        cmp     ax, 288
        jbe     .bf
        mov     ax, 288
.bf:    mov     cx, ax
        mov     bx, PBX
        mov     al, C_BUF
        call    fill_rect
        pop     cx
        mov     al, C_PINK
        call    fill_rect
        add     bx, cx                  ; the knob
        sub     bx, 2
        dec     dx
        mov     cx, 4
        mov     si, 6
        mov     al, C_WHITE
        call    fill_rect
        ; tick marks every clip loop (16 frames)
        ; timecode 00:SS:FF / 00:08:00
        call    lb_start
        mov     al, 0x10
        cmp     byte [paused], 0
        je      .ic
        mov     al, 0xBA
.ic:    mov     [di], al
        inc     di
        mov     byte [di], ' '
        inc     di
        mov     ax, [shown]
        call    timecode
        mov     byte [di], '/'
        inc     di
        mov     ax, [frames]
        call    timecode
        call    lb_end
        mov     bx, 4
        mov     dx, 190
        mov     ax, (C_PANEL << 8) | C_WHITE
        jmp     put_small

timecode:                               ; AX = frame -> "00:SS:FF" at DI
        mov     cl, 12
        div     cl                      ; AL = s, AH = frame
        push    ax
        mov     byte [di], '0'
        mov     byte [di + 1], '0'
        mov     byte [di + 2], ':'
        add     di, 3
        xor     ah, ah
        mov     cx, 2
        call    dec0
        mov     byte [di], ':'
        inc     di
        pop     ax
        mov     al, ah
        xor     ah, ah
        call    dec0
        ret

draw_graph:
        mov     bx, PX
        mov     dx, 76
        mov     cx, 112
        mov     si, 22
        mov     al, C_BG
        call    fill_rect
        mov     ax, [hi_thr]            ; the HI rendition line
        mov     cl, 80
        div     cl
        xor     ah, ah
        mov     dx, 97
        sub     dx, ax
        mov     cx, 112
        mov     si, 1
        mov     al, C_LINE
        call    fill_rect
        xor     bp, bp
.b:     mov     al, [graph + bp]
        xor     ah, ah
        test    ax, ax
        jz      .n
        mov     si, ax
        mov     dx, 98
        sub     dx, ax
        mov     bx, bp
        shl     bx, 1
        shl     bx, 1
        add     bx, PX
        mov     cx, 3
        mov     al, C_CYAN
        cmp     si, 15
        jae     .c
        mov     al, C_YEL
        cmp     si, 6
        jae     .c
        mov     al, C_RED
.c:     call    fill_rect
.n:     inc     bp
        cmp     bp, 28
        jb      .b
        ret

draw_stats:
        ; network state + measured kbps
        mov     bl, [net]
        xor     bh, bh
        shl     bx, 1
        mov     si, [net_names + bx]
        mov     al, [net_cols + bx]
        mov     ah, C_PANEL
        mov     bx, PX + 64
        mov     dx, 56
        call    put_small
        call    lb_start
        mov     ax, [est]               ; bytes/tick * 60 * 8 / 1000 = * 12 / 25
        mov     cx, 12
        mul     cx
        mov     cx, 25
        div     cx
        mov     cx, 5
        call    decs
        mov     si, s_kbps
        call    scpy
        call    lb_end
        mov     bx, PX
        mov     dx, 66
        mov     ax, (C_PANEL << 8) | C_WHITE
        call    put_small
        ; ABR choice of the frame on screen + of the next download
        mov     si, s_hi
        mov     al, C_GREEN
        cmp     byte [cur_rend], 0
        je      .q
        mov     si, s_lo
        mov     al, C_YEL
.q:     mov     ah, C_PANEL
        mov     bx, PX + 32
        mov     dx, 102
        call    put_small
        ; buffer count + bar
        call    lb_start
        mov     al, [ring_count]
        xor     ah, ah
        mov     cx, 2
        call    decs
        mov     si, s_of16
        call    scpy
        call    lb_end
        mov     bx, PX + 56
        mov     dx, 112
        mov     ax, (C_PANEL << 8) | C_WHITE
        call    put_small
        mov     bx, PX
        mov     dx, 122
        mov     cx, 112
        mov     si, 5
        mov     al, C_TRACK
        call    fill_rect
        mov     al, [ring_count]
        xor     ah, ah
        mov     cx, ax
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        sub     ax, cx
        mov     cx, ax                  ; 7 px per slot
        jcxz    .nb
        mov     al, C_GREEN
        cmp     cx, 8 * 7
        jae     .bc
        mov     al, C_YEL
        cmp     cx, 3 * 7
        jae     .bc
        mov     al, C_RED
.bc:    call    fill_rect
.nb:    ; stalls + frame
        call    lb_start
        mov     si, s_stalls
        call    scpy
        mov     ax, [stalls]
        mov     cx, 3
        call    decs
        mov     si, s_frame
        call    scpy
        mov     ax, [shown]
        mov     cx, 2
        call    dec0
        call    lb_end
        mov     bx, PX
        mov     dx, 162
        mov     ax, (C_PANEL << 8) | C_TXT
        call    put_small
        ret

; ===================================================================
; data
; ===================================================================
%include "keys.inc"

ui_pal  db  2,  2,  5,    6,  6, 11,   14, 15, 24,   26, 27, 36
        db 46, 47, 52,   63, 63, 63,   63, 18, 42,   18, 46, 63
        db 22, 58, 30,   63, 50, 14,   63, 20, 18,   34, 22, 44
        db 10, 10, 17,   46, 47, 52,   63, 18, 42,   18, 46, 63
sm_rows db 2, 3, 4, 6, 7, 8, 10, 11
sm_or   db 0, 0, 1, 0, 0, 1, 0, 1
sglyph  times 8 db 0
intro_pal db 46, 47, 52,  63, 18, 42,  18, 46, 63

bw_table  dw 1600, 0, 300               ; OK 768 kbps, DOWN, SLOW 144 kbps
net_names dw s_n_ok, s_n_down, s_n_slow
net_cols  dw C_GREEN, C_RED, C_YEL

%define NOTE(f) (1193182 / f)
melody  dw NOTE(880), NOTE(659), NOTE(523), NOTE(659), NOTE(880), NOTE(1047), NOTE(880), 0
        dw NOTE(587), NOTE(698), NOTE(880), NOTE(698), NOTE(587), NOTE(494), NOTE(523), 0

spin_xy db 0,-13,  9,-9,  13,0,  9,9,  0,13,  -9,9,  -13,0,  -9,-9

labels  dw 22, s_l_stream_p, 56, s_l_net, 102, s_l_abr, 112, s_l_buffer, 132, s_l_drm, 0
dbg_rows dw s_dbg_dk, dev_key, s_dbg_kid, HDR + 28, s_dbg_ck, ck, s_dbg_iv, cur_iv, 0

s_presents   db "ALMO7AYA PRESENTS", 0
s_title      db "7PLAYER", 0
s_tagline    db "THE DAY JOB, IN 8086", 0
s_about      db "WEB + TV VIDEO PLAYERS: PLAYBACK & DRM", 0
s_licreq     db "LICENSE REQUEST", 0
s_toy        db "TOY DRM: ROOT KEY LIVES IN THIS BINARY", 0
s_l_media    db "MEDIA", 0
s_l_rom      db "ROM ID", 0
s_l_dev      db "DEVICE KEY", 0
s_l_lic      db "LICENSE", 0
s_l_unwrap   db "UNWRAP", 0
s_l_check    db "KEY CHECK", 0
s_l_key      db "KEY LOADED", 0
s_l_stream   db "STREAM", 0
s_empty      db 0
s_ok         db "OK", 0
s_fail       db "FAIL", 0
s_fr12       db "FR 12FPS", 0
s_model      db " MODEL ", 0
s_dkf        db "RC4(ROOT^", 0
s_dots       db "..", 0
s_req        db "REQ KID ", 0
s_resp       db "RESP WRAP ", 0
s_unwrap     db "KEK=RC4(DK^KID) CK=W^KEK", 0
s_kcv        db "KCV=RC4(CK) ", 0
s_loaded     db "RC4-128 DROP256 IV/FRAME", 0
s_opening    db "OPENING PANIC.7MV...", 0
s_denied     db "LICENSE DENIED: DEVICE NOT ENTITLED", 0
s_seven      db "7", 0
s_player     db "PLAYER", 0
s_hdr        db "ALMO7AYA ", 0xFA, " PANIC.7MV", 0
s_l_stream_p db "STREAM", 0
s_stream     db "PANIC.7MV", 0
s_stream2    db "96FR 12FPS RLE", 0
s_l_net      db "NETWORK", 0
s_l_abr      db "ABR", 0
s_l_buffer   db "BUFFER", 0
s_l_drm      db "DRM", 0
s_drm        db "RC4-128", 0
s_licok      db "LICENSE OK", 0
s_kid        db "KID ", 0
s_hints      db "SPC ", 0x1B, 0x1A, " D N M", 0
s_snd_on     db "SND", 0
s_snd_off    db "SND", 0
s_n_ok       db "OK  ", 0
s_n_down     db "DOWN", 0
s_n_slow     db "SLOW", 0
s_kbps       db " KBPS", 0
s_hi         db "HI 128P", 0
s_lo         db "LO  64P", 0
s_of16       db "/16", 0
s_stalls     db "STALL", 0
s_frame      db "  FR", 0
s_st_play    db 0x10, " PLAYING ", 0
s_st_pause   db 0xBA, " PAUSED  ", 0
s_st_buf     db "BUFFERING", 0
s_buffering  db "BUFFERING", 0
s_seeking    db "SEEKING  ", 0
s_paused     db "PAUSED", 0
s_dbg0       db "DRM DEBUG RC4-D256", 0
s_dbg_dk     db "DK  ", 0
s_dbg_kid    db "KID ", 0
s_dbg_ck     db "CK  ", 0
s_dbg_iv     db "IV  ", 0
s_dbg_i      db "I ", 0
s_dbg_j      db " J ", 0
s_dbg_s      db " S ", 0

; variables
old_1c     dd 0
ticks      dw 0
last_tick  dw 0
t0         dw 0
it         dw 0
font_off   dw 0
font_seg   dw 0
t_col      dw 0
fsmall     db 0
big_col    db 0
bright     db 16
fast       db 0
model      db 0
bios_date  times 9 db 0
frames     dw 96
hi_thr     dw 1220
rc4_i      db 0
rc4_j      db 0
rc4key     times 16 db 0
dev_key    times 16 db 0
kek        times 16 db 0
ck         times 16 db 0
kcv        times 4 db 0
cur_iv     times 16 db 0
lbuf       times 48 db 0

paused     db 0
buffering  db 0
seeking    db 0
debug      db 0
snd        db 0
snd_t      db 0
net        db 0
net_t      dw 0
auto_t     dw 0
bw         dw 0
avail      dw 0
need       dw 0
est        dw 0
in_prog    db 0
moved      db 0
dl_rend    db 0
dl_pos     dw 0
ring_head  db 0
ring_count db 0
slot_frame times SLOTS dw 0
slot_len   times SLOTS dw 0
slot_rend  times SLOTS db 0
shown      dw 0
cur_len    dw 0
cur_rend   db 0
frame_t    db 0
spin_t     db 0
spin_drawn db 0xFF
spin_head  db 0
ui_t       db 0
gr_t       db 0
dirty      db 0
stalls     dw 0
rx_bytes   dw 0
io_err     dw 0
graph      times 28 db 0

prog_end:
PROG_SECTORS equ (prog_end - stage2 + 511) / 512

        times MOVIE_LBA*512 - ($-$$) db 0
        incbin "movie.7mv"
