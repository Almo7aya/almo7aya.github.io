; gui/main.asm · 7GUI 1.0, a tiny windowed desktop for almo7aya.dev
;
;   build:  node os/build.mjs gui       (assets.mjs makes the palette, icons, cursor and girl)
;   run:    qemu-system-i386 -drive format=raw,file=public/os/gui.img
;
; how it works
;   - the boot sector reads the disk geometry (INT 13h AH=08h) and loads the rest one sector
;     at a time to 0000:7E00
;   - mode 13h, our own 256-colour DAC: 16 UI colours, title bar ramps, a desktop gradient,
;     16 grays for the girl
;   - everything is drawn into a back buffer at 2000:0000, clipped to one dirty rectangle;
;     only that rectangle is copied to A000:0000, during vertical retrace
;   - the mouse cursor lives only in video memory: to move it we copy the old spot back
;     from the back buffer and draw the arrow at the new spot
;   - the PS/2 mouse BIOS (INT 15h AX=C2xxh) calls mouse_cb on every packet; it tracks the
;     position in a 640x200 space and queues button changes for the main loop
;   - INT 1Ch counts timer ticks (double-click timing, cursor blink); the clock is the RTC
;   - text is the BIOS 8x16 font ROM squeezed to 8x8 (row pairs OR-ed), word wrapped
;   - the main loop sleeps with HLT until the next interrupt

cpu 8086
bits 16
org 0x7C00

BB_SEG          equ 0x2000                  ; back buffer
VGA_SEG         equ 0xA000
SCR_W           equ 320
SCR_H           equ 200
DESK_H          equ 185                     ; the taskbar starts here
NAPPS           equ 7
LH              equ 10                      ; text line height
CUR_W           equ 11
CUR_H           equ 16

; one app = one window (16 bytes)
A_X             equ 0
A_Y             equ 2
A_W             equ 4
A_H             equ 6
A_TITLE         equ 8
A_TEXT          equ 10
A_KIND          equ 12
A_OPEN          equ 13
A_LINES         equ 14
A_CCOL          equ 15
APP_SZ          equ 16

K_TEXT          equ 0
K_TERM          equ 1
K_GIRL          equ 2
K_CLOCK         equ 3
APP_ABOUT       equ 0
APP_CLOCK       equ 5
APP_README      equ 6

START_X         equ 2
START_W         equ 38
TB_X            equ 44                      ; task buttons from here...
TB_W            equ 200                     ; ...this wide
CLK_X           equ 248
MENU_X          equ 2
MENU_W          equ 120
MENU_IH         equ 18
MENU_H          equ 3 + NAPPS * MENU_IH + 3
MENU_Y          equ DESK_H - MENU_H
WM_X            equ 236                     ; the big faint 7 on the desktop
WM_Y            equ 52

%macro BEVEL 2
        mov     byte [c_tl], %1
        mov     byte [c_br], %2
        call    bevel
%endmacro
%macro PEN 1
        mov     byte [pen], %1
%endmacro
%macro RECT 4
        mov     ax, %1
        mov     bx, %2
        mov     cx, %3
        mov     dx, %4
%endmacro

; ===================================================================
; boot sector
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
        push    es
        int     0x13
        pop     es
        jc      .geo
        and     cx, 0x3F
        jz      .geo
        mov     [spt], cx
        mov     cl, dh
        xor     ch, ch
        inc     cx
        mov     [heads], cx
.geo:   mov     ax, 0x07E0
        mov     es, ax
        mov     ax, 1                   ; LBA 1 onwards
        mov     cx, STAGE2_SECTORS
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
        mov     di, 3
.try:   mov     ax, 0x0201
        int     0x13
        jnc     .ok
        dec     di
        jz      .fail
        xor     ax, ax
        int     0x13
        jmp     .try
.ok:    mov     ax, es
        add     ax, 0x20
        mov     es, ax
        pop     cx
        pop     ax
        inc     ax
        loop    .next
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

boot_drive      db 0x80
spt             dw 63
heads           dw 16
s_diskerr       db "7GUI: disk read error", 0

        times 510-($-$$) db 0
        dw      0xAA55

; ===================================================================
; stage 2, at 0000:7E00
; ===================================================================
stage2:
        xor     ax, ax                  ; the loader left ES past the image
        mov     es, ax
        push    es                      ; the 8x16 font ROM -> font8 (8x8, row pairs OR-ed)
        mov     ax, 0x1130
        mov     bh, 0x06
        int     0x10
        mov     [font_off], bp
        mov     [font_seg], es
        push    ds
        push    es
        pop     ds
        mov     si, bp
        xor     ax, ax
        mov     es, ax
        mov     di, font8
        mov     cx, 256 * 8
        xor     dl, dl                  ; the source row above the pair
.f8:    lodsb
        mov     ah, [si]
        inc     si
        test    al, al                  ; a gap right under ink stays a gap (the dot of i, j)
        jnz     .or
        test    dl, dl
        jz      .or
        xor     ah, ah
.or:    or      al, ah
        mov     dl, [si-1]
        stosb
        loop    .f8
        pop     ds
        pop     es

        mov     ax, 0x0013
        int     0x10
        mov     dx, 0x3C8               ; the whole DAC
        xor     al, al
        out     dx, al
        inc     dx
        mov     si, palette
        mov     cx, 768
.pal:   lodsb
        out     dx, al
        loop    .pal

        xor     ax, ax                  ; row offsets
        mov     di, rowoff
        mov     cx, SCR_H
.rt:    stosw
        add     ax, SCR_W
        loop    .rt

        mov     si, apps                ; text windows: height from the word-wrapped text
        mov     cx, NAPPS
.ah:    cmp     word [si+A_H], 0
        jne     .ahn
        push    cx
        push    si
        mov     ax, [si+A_W]
        sub     ax, 14
        mov     cl, 3
        shr     ax, cl
        mov     [lt_cols], ax
        mov     byte [lt_draw], 0
        mov     si, [si+A_TEXT]
        call    layout_text
        pop     si
        mov     ax, [lt_line]
        inc     ax
        mov     [si+A_LINES], al
        mov     dl, [lt_col]
        mov     [si+A_CCOL], dl
        mov     dx, LH
        mul     dx
        add     ax, 6 + 18
        mov     [si+A_H], ax
        pop     cx
.ahn:   add     si, APP_SZ
        loop    .ah

        cli                             ; INT 1Ch: count ticks
        mov     ax, [0x1C*4]
        mov     [old_1c], ax
        mov     ax, [0x1C*4+2]
        mov     [old_1c+2], ax
        mov     word [0x1C*4], timer_isr
        mov     word [0x1C*4+2], 0
        sti

        call    mouse_init
        call    poll_clock
        mov     ax, BB_SEG              ; ES = back buffer from now on
        mov     es, ax
        mov     al, APP_README
        call    open_app
        mov     al, APP_ABOUT
        call    open_app
        RECT    0, 0, SCR_W, SCR_H
        call    mark_dirty

main_loop:
        call    poll_keys
        call    poll_mouse
        call    poll_clock
        call    render
        call    present
        cli
        cmp     byte [mouse_moved], 0
        jne     .busy
        mov     al, [ev_head]
        cmp     al, [ev_tail]
        jne     .busy
        sti                             ; sleep until the next interrupt (timer, key, mouse)
        hlt
        jmp     main_loop
.busy:  sti
        jmp     main_loop

; -------------------------------------------------------------------
; interrupts
; -------------------------------------------------------------------
timer_isr:
        inc     word [cs:ticks]
        jmp     far [cs:old_1c]

mouse_init:
        push    es
        mov     ax, 0xC205              ; initialise, 3-byte packets
        mov     bh, 3
        int     0x15
        jc      .no
        mov     ax, 0xC203              ; resolution 8 counts/mm
        mov     bh, 3
        int     0x15
        xor     ax, ax
        mov     es, ax
        mov     bx, mouse_cb
        mov     ax, 0xC207              ; our handler
        int     0x15
        jc      .no
        mov     ax, 0xC200              ; enable
        mov     bh, 1
        int     0x15
        jc      .no
        mov     byte [have_mouse], 1
.no:    pop     es
        ret

; far-called by the BIOS: [sp+4]=0, [sp+6]=Y, [sp+8]=X, [sp+10]=status
mouse_cb:
        push    ax
        push    bx
        push    si
        push    ds
        push    bp
        mov     bp, sp                  ; +10 ret, +14 zero, +16 Y, +18 X, +20 status
        xor     ax, ax
        mov     ds, ax
        mov     bl, [bp+20]
        test    bl, 0xC0                ; overflow: drop the packet
        jnz     .out
        mov     al, [bp+18]
        xor     ah, ah
        test    bl, 0x10
        jz      .xp
        mov     ah, 0xFF
.xp:    add     ax, [mx]
        jns     .x0
        xor     ax, ax
.x0:    cmp     ax, 639
        jle     .x1
        mov     ax, 639
.x1:    mov     [mx], ax
        mov     al, [bp+16]
        xor     ah, ah
        test    bl, 0x20
        jz      .yp
        mov     ah, 0xFF
.yp:    neg     ax                      ; PS/2 Y grows upwards
        add     ax, [my]
        jns     .y0
        xor     ax, ax
.y0:    cmp     ax, 199
        jle     .y1
        mov     ax, 199
.y1:    mov     [my], ax
        mov     byte [mouse_moved], 1
        and     bl, 3
        cmp     bl, [mbtn]
        je      .out
        mov     [mbtn], bl              ; a button changed: queue (x, y, buttons)
        mov     al, [ev_head]
        mov     bh, al
        inc     bh
        and     bh, 15
        cmp     bh, [ev_tail]
        je      .out
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        mov     ax, [mx]
        shr     ax, 1
        mov     [evq+si], ax
        mov     al, [my]
        mov     [evq+si+2], al
        mov     [evq+si+3], bl
        mov     [ev_head], bh
.out:   pop     bp
        pop     ds
        pop     si
        pop     bx
        pop     ax
        retf

; -------------------------------------------------------------------
; input
; -------------------------------------------------------------------
poll_mouse:
.ev:    cli
        mov     al, [ev_tail]
        cmp     al, [ev_head]
        je      .noev
        mov     bl, al
        inc     bl
        and     bl, 15
        mov     [ev_tail], bl
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        mov     ax, [evq+si]
        mov     bl, [evq+si+2]
        xor     bh, bh
        mov     cl, [evq+si+3]
        sti
        push    cx
        call    motion
        pop     cx
        call    button
        jmp     .ev
.noev:  mov     ax, [mx]
        mov     bx, [my]
        mov     byte [mouse_moved], 0
        sti
        shr     ax, 1
        jmp     motion

button: and     cl, 1
        cmp     cl, [lbtn]
        je      .r
        mov     [lbtn], cl
        test    cl, cl
        jz      on_release
        jmp     on_press
.r:     ret

on_release:
        mov     byte [drag_app], 0xFF
        ret

motion: mov     [cur_x], ax
        mov     [cur_y], bx
        mov     [pt_x], ax
        mov     [pt_y], bx
        mov     al, [drag_app]
        cmp     al, 0xFF
        je      .nodrag
        call    app_ptr
        mov     ax, [pt_x]
        sub     ax, [drag_dx]
        mov     bx, [pt_y]
        sub     bx, [drag_dy]
        call    move_window
.nodrag:
        cmp     byte [menu_open], 0
        je      .r
        mov     al, 0xFF
        mov     si, menu_items_rect
        call    pt_in
        jc      .set
        mov     ax, [pt_y]
        sub     ax, MENU_Y + 3
        mov     bl, MENU_IH
        div     bl
.set:   cmp     al, [menu_hover]
        je      .r
        mov     [menu_hover], al
        call    dirty_menu
.r:     ret

on_press:
        cmp     byte [menu_open], 0
        je      .nomenu
        mov     si, menu_rect
        call    pt_in
        jc      .mclose
        mov     al, [menu_hover]
        cmp     al, 0xFF
        je      .ret
        push    ax
        call    close_menu
        pop     ax
        jmp     open_app
.mclose:
        jmp     close_menu
.nomenu:
        cmp     word [pt_y], DESK_H
        jl      .notb
        mov     si, start_rect
        call    pt_in
        jc      .tbtn
        jmp     open_menu
.tbtn:  call    taskbar_hit
        cmp     al, 0xFF
        je      .ret
        jmp     raise_app
.notb:  call    hit_window
        jc      .desk
        push    ax
        call    raise_app
        pop     ax
        call    app_ptr
        mov     bx, [si+A_X]            ; the close box (a little bigger than drawn)
        add     bx, [si+A_W]
        sub     bx, 17
        mov     [tr], bx
        mov     bx, [si+A_Y]
        add     bx, 3
        mov     [tr+2], bx
        mov     word [tr+4], 13
        mov     word [tr+6], 11
        push    si
        mov     si, tr
        call    pt_in
        pop     si
        jc      .notclose
        jmp     close_app
.notclose:
        mov     bx, [pt_y]              ; the title bar: start dragging
        sub     bx, [si+A_Y]
        cmp     bx, 15
        jge     .ret
        mov     [drag_app], al
        mov     [drag_dy], bx
        mov     bx, [pt_x]
        sub     bx, [si+A_X]
        mov     [drag_dx], bx
.ret:   ret
.desk:  call    hit_icon
        cmp     al, 0xFF
        je      .desel
        cmp     al, [last_icon]
        jne     .single
        mov     dx, [ticks]
        sub     dx, [last_click]
        cmp     dx, 12                  ; about two thirds of a second
        ja      .single
        mov     byte [last_icon], 0xFF
        push    ax
        call    select_icon
        pop     ax
        jmp     open_app
.single:
        mov     [last_icon], al
        mov     dx, [ticks]
        mov     [last_click], dx
        jmp     select_icon
.desel: mov     byte [last_icon], 0xFF
        jmp     select_icon

poll_keys:
.k:     mov     ah, 0x01
        int     0x16
        jz      .r
        xor     ah, ah
        int     0x16
        cmp     al, 27
        je      .esc
        cmp     al, 9
        je      .tab
        cmp     al, 13
        je      .enter
        cmp     al, '7'
        je      .seven
        cmp     ah, 0x3B                ; F1
        je      .f1
        jmp     .k
.esc:   cmp     byte [menu_open], 0
        je      .esc2
        call    close_menu
        jmp     .k
.esc2:  mov     bl, [zcount]
        test    bl, bl
        jz      .k
        xor     bh, bh
        mov     al, [zlist+bx-1]
        call    close_app
        jmp     .k
.tab:   cmp     byte [zcount], 2
        jb      .k
        mov     al, [zlist]             ; the bottom window comes to the top
        call    raise_app
        jmp     .k
.enter: mov     al, [sel_icon]
        cmp     al, 0xFF
        je      .k
        call    open_app
        jmp     .k
.seven: cmp     byte [menu_open], 0
        jne     .sc
        call    open_menu
        jmp     .k
.sc:    call    close_menu
        jmp     .k
.f1:    mov     al, APP_README
        call    open_app
        jmp     .k
.r:     ret

; -------------------------------------------------------------------
; clock: the RTC, checked once per timer tick
; -------------------------------------------------------------------
poll_clock:
        mov     ax, [ticks]
        cmp     ax, [last_ticks]
        je      .r
        mov     [last_ticks], ax
        mov     cl, 3                   ; the README cursor blinks every 8 ticks
        shr     al, cl
        and     al, 1
        cmp     al, [blink]
        je      .nb
        mov     [blink], al
        call    dirty_readme_cursor
.nb:    mov     ah, 0x02
        int     0x1A
        jc      .r
        cmp     dh, [rtc_s]
        jne     .chg
        cmp     cx, [rtc_hm]
        je      .r
.chg:   mov     [rtc_s], dh
        mov     [rtc_hm], cx
        mov     di, time_str
        mov     al, ch
        call    bcd2
        inc     di
        mov     al, cl
        call    bcd2
        inc     di
        mov     al, dh
        call    bcd2
        mov     ah, 0x04
        int     0x1A
        jc      .nd
        mov     di, date_str
        mov     al, ch
        call    bcd2
        mov     al, cl
        call    bcd2
        inc     di
        mov     al, dh
        call    bcd2
        inc     di
        mov     al, dl
        call    bcd2
.nd:    RECT    CLK_X, 188, 70, 11
        call    mark_dirty
        mov     al, APP_CLOCK
        call    app_ptr
        cmp     byte [si+A_OPEN], 0
        je      .r
        call    body_rect
        call    mark_dirty
.r:     ret

bcd2:   push    ax                      ; AL = BCD -> two digits at DS:DI
        push    cx
        mov     ah, al
        mov     cl, 4
        shr     al, cl
        add     al, '0'
        mov     [di], al
        mov     al, ah
        and     al, 0x0F
        add     al, '0'
        mov     [di+1], al
        add     di, 2
        pop     cx
        pop     ax
        ret

bcd_bin:                                ; AL = BCD -> binary
        push    cx
        mov     ah, al
        mov     cl, 4
        shr     ah, cl
        and     al, 0x0F
        mov     cl, al
        mov     al, ah
        mov     ah, 10
        mul     ah
        add     al, cl
        pop     cx
        ret

dirty_readme_cursor:
        push    si
        mov     al, APP_README
        call    app_ptr
        cmp     byte [si+A_OPEN], 0
        je      .r
        mov     al, [si+A_LINES]
        dec     al
        mov     ah, LH
        mul     ah
        add     ax, [si+A_Y]
        add     ax, 19
        mov     bx, ax
        mov     al, [si+A_CCOL]
        xor     ah, ah
        mov     cl, 3
        shl     ax, cl
        add     ax, [si+A_X]
        add     ax, 7
        mov     cx, 8
        mov     dx, 8
        call    mark_dirty
.r:     pop     si
        ret

; -------------------------------------------------------------------
; windows, z-order, hit testing
; -------------------------------------------------------------------
app_ptr:                                ; AL = app -> SI = its struct
        push    ax
        push    cx
        xor     ah, ah
        mov     cl, 4
        shl     ax, cl
        add     ax, apps
        mov     si, ax
        pop     cx
        pop     ax
        ret

body_rect:                              ; SI = app -> AX, BX, CX, DX = its body
        mov     ax, [si+A_X]
        add     ax, 3
        mov     bx, [si+A_Y]
        add     bx, 15
        mov     cx, [si+A_W]
        sub     cx, 6
        mov     dx, [si+A_H]
        sub     dx, 18
        ret

pt_in:                                  ; [pt_x],[pt_y] inside the rect at SI? CF=1 if not
        push    ax
        mov     ax, [pt_x]
        sub     ax, [si]
        jl      .o
        cmp     ax, [si+4]
        jge     .o
        mov     ax, [pt_y]
        sub     ax, [si+2]
        jl      .o
        cmp     ax, [si+6]
        jge     .o
        pop     ax
        clc
        ret
.o:     pop     ax
        stc
        ret

hit_window:                             ; -> AL = topmost window under the point, CF=1 if none
        mov     cl, [zcount]
        xor     ch, ch
        jcxz    .miss
.l:     mov     bx, cx
        mov     al, [zlist+bx-1]
        call    app_ptr
        call    pt_in
        jnc     .hit
        loop    .l
.miss:  stc
        ret
.hit:   clc
        ret

icon_rect:                              ; AL = icon -> [tr]
        push    ax
        push    bx
        xor     ah, ah
        mov     bx, ax
        shl     bx, 1
        shl     bx, 1
        mov     ax, [icon_pos+bx]
        sub     ax, 30
        mov     [tr], ax
        mov     ax, [icon_pos+bx+2]
        sub     ax, 2
        mov     [tr+2], ax
        mov     word [tr+4], 60
        mov     word [tr+6], 30
        pop     bx
        pop     ax
        ret

hit_icon:                               ; -> AL = icon or 0FFh
        xor     al, al
.l:     call    icon_rect
        mov     si, tr
        call    pt_in
        jnc     .r
        inc     al
        cmp     al, NAPPS
        jb      .l
        mov     al, 0xFF
.r:     ret

select_icon:                            ; AL = icon or 0FFh
        cmp     al, [sel_icon]
        je      .r
        push    ax
        mov     al, [sel_icon]
        call    dirty_icon
        pop     ax
        mov     [sel_icon], al
        call    dirty_icon
.r:     ret

dirty_icon:
        cmp     al, 0xFF
        je      .r
        push    ax
        push    bx
        push    cx
        push    dx
        call    icon_rect
        RECT    [tr], [tr+2], [tr+4], [tr+6]
        call    mark_dirty
        pop     dx
        pop     cx
        pop     bx
        pop     ax
.r:     ret

dirty_app_si:
        push    ax
        push    bx
        push    cx
        push    dx
        RECT    [si+A_X], [si+A_Y], [si+A_W], [si+A_H]
        call    mark_dirty
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

dirty_top:                              ; the top window (its title bar is about to change)
        push    ax
        push    bx
        push    si
        mov     bl, [zcount]
        test    bl, bl
        jz      .r
        xor     bh, bh
        mov     al, [zlist+bx-1]
        call    app_ptr
        call    dirty_app_si
.r:     pop     si
        pop     bx
        pop     ax
        ret

dirty_taskbar:
        push    ax
        push    bx
        push    cx
        push    dx
        RECT    0, DESK_H, SCR_W, SCR_H - DESK_H
        call    mark_dirty
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

dirty_menu:
        push    ax
        push    bx
        push    cx
        push    dx
        RECT    MENU_X, MENU_Y, MENU_W, MENU_H
        call    mark_dirty
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

z_remove:                               ; AL = app
        push    ax
        push    bx
        push    cx
        xor     bx, bx
        mov     cl, [zcount]
        xor     ch, ch
.f:     cmp     bx, cx
        jae     .r
        cmp     [zlist+bx], al
        je      .s
        inc     bx
        jmp     .f
.s:     inc     bx
        cmp     bx, cx
        jae     .d
        mov     ah, [zlist+bx]
        mov     [zlist+bx-1], ah
        jmp     .s
.d:     dec     byte [zcount]
.r:     pop     cx
        pop     bx
        pop     ax
        ret

z_push:                                 ; AL = app, on top
        push    bx
        mov     bl, [zcount]
        xor     bh, bh
        mov     [zlist+bx], al
        inc     byte [zcount]
        pop     bx
        ret

open_app:                               ; AL = app
        call    app_ptr
        cmp     byte [si+A_OPEN], 0
        jne     raise_app
        mov     byte [si+A_OPEN], 1
        push    ax
        mov     ax, SCR_W               ; keep it on the screen
        sub     ax, [si+A_W]
        cmp     [si+A_X], ax
        jle     .x
        mov     [si+A_X], ax
.x:     mov     ax, DESK_H
        sub     ax, [si+A_H]
        jge     .y0
        xor     ax, ax
.y0:    cmp     [si+A_Y], ax
        jle     .y
        mov     [si+A_Y], ax
.y:     pop     ax
        call    dirty_top
        call    z_push
        call    dirty_app_si
        jmp     dirty_taskbar

raise_app:                              ; AL = app
        mov     bl, [zcount]
        xor     bh, bh
        test    bx, bx
        jz      .r
        cmp     [zlist+bx-1], al
        je      .r
        call    dirty_top
        call    z_remove
        call    z_push
        call    app_ptr
        call    dirty_app_si
        call    dirty_taskbar
.r:     ret

close_app:                              ; AL = app
        call    app_ptr
        cmp     byte [si+A_OPEN], 0
        je      .r
        mov     byte [si+A_OPEN], 0
        call    z_remove
        call    dirty_app_si
        call    dirty_top
        call    dirty_taskbar
        cmp     al, [drag_app]
        jne     .r
        mov     byte [drag_app], 0xFF
.r:     ret

move_window:                            ; SI = app, AX, BX = new position
        mov     cx, 24
        sub     cx, [si+A_W]
        cmp     ax, cx
        jge     .a
        mov     ax, cx
.a:     cmp     ax, SCR_W - 24
        jle     .b
        mov     ax, SCR_W - 24
.b:     cmp     bx, 0
        jge     .c
        xor     bx, bx
.c:     cmp     bx, DESK_H - 15
        jle     .d
        mov     bx, DESK_H - 15
.d:     cmp     ax, [si+A_X]
        jne     .mv
        cmp     bx, [si+A_Y]
        je      .r
.mv:    call    dirty_app_si
        mov     [si+A_X], ax
        mov     [si+A_Y], bx
        call    dirty_app_si
.r:     ret

open_menu:
        mov     byte [menu_open], 1
        mov     byte [menu_hover], 0xFF
        call    dirty_menu
        jmp     dirty_taskbar

close_menu:
        mov     byte [menu_open], 0
        call    dirty_menu
        jmp     dirty_taskbar

tb_layout:                              ; [tb_bw] = task button width for [zcount] buttons
        mov     al, [zcount]
        test    al, al
        jz      .r
        mov     cl, al
        mov     ax, TB_W
        div     cl
        xor     ah, ah
        sub     ax, 2
        cmp     ax, 72
        jbe     .ok
        mov     ax, 72
.ok:    mov     [tb_bw], ax
.r:     ret

taskbar_hit:                            ; -> AL = app of the task button under the point, or 0FFh
        cmp     byte [zcount], 0
        je      .no
        call    tb_layout
        mov     ax, [pt_y]
        cmp     ax, 188
        jl      .no
        cmp     ax, 199
        jge     .no
        mov     ax, [pt_x]
        sub     ax, TB_X
        jl      .no
        mov     cx, [tb_bw]
        add     cx, 2
        xor     dx, dx
        div     cx
        cmp     dx, [tb_bw]
        jae     .no
        cmp     al, [zcount]
        jae     .no
        mov     cl, al                  ; the k-th open app, in app order
        xor     al, al
.f:     call    app_ptr
        cmp     byte [si+A_OPEN], 0
        je      .nx
        cmp     cl, 0
        je      .r
        dec     cl
.nx:    inc     al
        cmp     al, NAPPS
        jb      .f
.no:    mov     al, 0xFF
.r:     ret

mark_dirty:                             ; AX, BX, CX, DX = rect -> union into the dirty rect
        push    ax
        push    bx
        push    cx
        push    dx
        add     cx, ax
        add     dx, bx
        cmp     ax, 0
        jge     .a
        xor     ax, ax
.a:     cmp     bx, 0
        jge     .b
        xor     bx, bx
.b:     cmp     cx, SCR_W
        jle     .c
        mov     cx, SCR_W
.c:     cmp     dx, SCR_H
        jle     .d
        mov     dx, SCR_H
.d:     cmp     ax, cx
        jge     .r
        cmp     bx, dx
        jge     .r
        cmp     byte [dirty], 0
        jne     .u
        mov     [dirty_x0], ax
        mov     [dirty_y0], bx
        mov     [dirty_x1], cx
        mov     [dirty_y1], dx
        mov     byte [dirty], 1
        jmp     .r
.u:     cmp     ax, [dirty_x0]
        jge     .e
        mov     [dirty_x0], ax
.e:     cmp     bx, [dirty_y0]
        jge     .f
        mov     [dirty_y0], bx
.f:     cmp     cx, [dirty_x1]
        jle     .g
        mov     [dirty_x1], cx
.g:     cmp     dx, [dirty_y1]
        jle     .r
        mov     [dirty_y1], dx
.r:     pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; -------------------------------------------------------------------
; the scene, redrawn into the back buffer inside the dirty rect
; -------------------------------------------------------------------
render:
        cmp     byte [dirty], 0
        je      .r
        mov     ax, [dirty_x0]
        mov     [clip_x0], ax
        mov     ax, [dirty_y0]
        mov     [clip_y0], ax
        mov     ax, [dirty_x1]
        mov     [clip_x1], ax
        mov     ax, [dirty_y1]
        mov     [clip_y1], ax
        call    draw_desktop
        call    draw_icons
        xor     bx, bx                  ; windows, bottom to top
.w:     cmp     bl, [zcount]
        jae     .wd
        push    bx
        mov     al, [zlist+bx]
        mov     byte [is_active], 0
        inc     bx
        cmp     bl, [zcount]
        jne     .na
        mov     byte [is_active], 1
.na:    call    app_ptr
        call    draw_window
        pop     bx
        inc     bx
        jmp     .w
.wd:    call    draw_taskbar
        call    draw_menu
.r:     ret

grad_color:                             ; BX = y -> AL = 0..63 down the desktop
        push    cx
        push    dx
        mov     ax, bx
        mov     cl, 6
        shl     ax, cl
        xor     dx, dx
        mov     cx, DESK_H
        div     cx
        pop     dx
        pop     cx
        ret

draw_desktop:
        mov     bx, [clip_y0]
.row:   cmp     bx, [clip_y1]
        jge     .wm
        cmp     bx, DESK_H
        jge     .wm
        call    grad_color
        add     al, 0x60
        mov     [pen], al
        mov     ax, [clip_x0]
        mov     cx, [clip_x1]
        sub     cx, ax
        mov     dx, 1
        call    fill_rect
        inc     bx
        jmp     .row
.wm:    RECT    WM_X, WM_Y, 48, 96      ; a big faint 7, the font ROM at 6x
        call    clip_test
        jc      .r
        mov     dl, '7'
        call    load_big
        xor     si, si
.wr:    mov     al, [bigbuf+si]
        mov     [wm_bits], al
        test    al, al
        jz      .wn
        mov     ax, si
        mov     cx, 6
        mul     cx
        add     ax, WM_Y
        mov     bx, ax
        mov     bp, 6
.ws:    cmp     bx, [clip_y0]
        jl      .wsn
        cmp     bx, [clip_y1]
        jge     .wn
        call    grad_color
        add     al, 0xA0
        mov     [pen], al
        mov     dl, [wm_bits]
        mov     [wm_cur], dl
        mov     ax, WM_X
        mov     cx, 6
        mov     dx, 1
.wb:    shl     byte [wm_cur], 1
        jnc     .wbn
        call    fill_rect
.wbn:   add     ax, 6
        cmp     byte [wm_cur], 0
        jne     .wb
.wsn:   inc     bx
        dec     bp
        jnz     .ws
.wn:    inc     si
        cmp     si, 16
        jb      .wr
.r:     ret

draw_icons:
        xor     al, al
.i:     call    icon_rect
        push    ax
        RECT    [tr], [tr+2], [tr+4], [tr+6]
        call    clip_test
        pop     ax
        jc      .n
        push    ax
        call    draw_icon
        pop     ax
.n:     inc     al
        cmp     al, NAPPS
        jb      .i
        ret

draw_icon:                              ; AL = icon
        xor     ah, ah
        mov     di, ax
        shl     di, 1
        shl     di, 1
        mov     [t_app], al
        mov     ah, al
        xor     al, al
        add     ax, icons
        mov     si, ax
        mov     ax, [icon_pos+di]
        sub     ax, 8
        mov     bx, [icon_pos+di+2]
        mov     cx, 16
        mov     dx, 16
        call    blit_sprite
        mov     al, [t_app]
        call    label_ptr
        call    strlen
        mov     ax, cx
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1                   ; width in pixels
        shl     ax, 1
        shl     ax, 1
        neg     ax
        add     ax, [icon_pos+di]
        add     bx, 19
        mov     dl, [t_app]
        cmp     dl, [sel_icon]
        jne     .plain
        PEN     1
        push    ax
        push    bx
        push    cx
        dec     ax
        dec     bx
        add     cx, 2
        mov     dx, 10
        call    fill_rect
        pop     cx
        pop     bx
        pop     ax
        PEN     15
        jmp     draw_str
.plain: PEN     0
        inc     ax
        inc     bx
        call    draw_str
        dec     ax
        dec     bx
        PEN     15
        jmp     draw_str

label_ptr:                              ; AL = app -> SI = its label
        push    bx
        xor     ah, ah
        mov     bx, ax
        shl     bx, 1
        mov     si, [labels+bx]
        pop     bx
        ret

strlen:                                 ; SI -> CX
        push    si
        xor     cx, cx
.l:     cmp     byte [si], 0
        je      .r
        inc     si
        inc     cx
        jmp     .l
.r:     pop     si
        ret

draw_window:                            ; SI = app, [is_active]
        RECT    [si+A_X], [si+A_Y], [si+A_W], [si+A_H]
        call    clip_test
        jc      .r
        BEVEL   7, 0
        BEVEL   15, 8
        PEN     7
        call    fill_rect
        mov     ax, [si+A_X]            ; title bar
        add     ax, 3
        mov     bx, [si+A_Y]
        add     bx, 3
        mov     cx, [si+A_W]
        sub     cx, 6
        mov     dx, 11
        mov     byte [grad_base], 0x40
        cmp     byte [is_active], 0
        je      .g
        mov     byte [grad_base], 0x20
.g:     call    hgrad
        sub     cx, 16
        call    clip_push
        jc      .nt
        PEN     7
        cmp     byte [is_active], 0
        je      .tc
        PEN     15
.tc:    add     ax, 4
        add     bx, 2
        push    si
        mov     si, [si+A_TITLE]
        call    draw_str
        pop     si
.nt:    call    clip_pop
        mov     ax, [si+A_X]            ; close box
        add     ax, [si+A_W]
        sub     ax, 16
        mov     bx, [si+A_Y]
        add     bx, 4
        mov     cx, 11
        mov     dx, 9
        BEVEL   15, 0
        BEVEL   7, 8
        PEN     7
        call    fill_rect
        PEN     0
        push    si
        mov     si, close_glyph
        mov     cx, 5
        call    draw_glyph
        pop     si
        call    body_rect
        call    clip_push
        jc      .nb
        mov     [body_x], ax
        mov     [body_y], bx
        mov     [body_w], cx
        mov     [body_h], dx
        mov     dl, [si+A_KIND]
        cmp     dl, K_GIRL
        je      .girl
        cmp     dl, K_CLOCK
        je      .clock
        PEN     15
        cmp     dl, K_TERM
        jne     .bg
        PEN     0
.bg:    mov     dx, [body_h]
        call    fill_rect
        PEN     0
        cmp     byte [si+A_KIND], K_TERM
        jne     .txt
        PEN     10
.txt:   add     ax, 4
        mov     [lt_x], ax
        add     bx, 4
        mov     [lt_y], bx
        sub     cx, 8
        mov     cl, 3
        mov     ax, [body_w]
        sub     ax, 8
        shr     ax, cl
        mov     [lt_cols], ax
        mov     byte [lt_draw], 1
        push    si
        mov     si, [si+A_TEXT]
        call    layout_text
        pop     si
        cmp     byte [si+A_KIND], K_TERM
        jne     .nb
        cmp     byte [blink], 0
        je      .nb
        PEN     10                      ; the blinking cursor
        mov     ax, [lt_line]
        mov     bx, LH
        mul     bx
        add     ax, [lt_y]
        mov     bx, ax
        mov     ax, [lt_col]
        mov     cl, 3
        shl     ax, cl
        add     ax, [lt_x]
        mov     cx, 7
        mov     dx, 8
        call    fill_rect
        jmp     .nb
.girl:  push    si
        mov     si, girl
        mov     word [bf_seg], 0
        mov     cx, 128
        mov     dx, 128
        call    blit_far
        pop     si
        jmp     .nb
.clock: call    draw_clock
.nb:    call    clip_pop
.r:     ret

draw_taskbar:
        cmp     word [clip_y1], DESK_H
        jle     .r
        PEN     7
        RECT    0, DESK_H, SCR_W, 1
        call    fill_rect
        PEN     15
        RECT    0, DESK_H + 1, SCR_W, 1
        call    fill_rect
        PEN     7
        RECT    0, DESK_H + 2, SCR_W, SCR_H - DESK_H - 2
        call    fill_rect
        RECT    START_X, 188, START_W, 11
        xor     bp, bp
        cmp     byte [menu_open], 0
        je      .up
        BEVEL   0, 15
        BEVEL   8, 7
        inc     bp
        jmp     .st
.up:    BEVEL   15, 0
        BEVEL   7, 8
.st:    mov     ax, START_X + 4
        add     ax, bp
        mov     bx, 190
        add     bx, bp
        PEN     4
        mov     dl, '7'
        call    draw_char
        add     ax, 8
        PEN     0
        mov     si, s_gui
        call    draw_str
        cmp     byte [zcount], 0
        je      .clock
        call    tb_layout
        mov     word [tb_x], TB_X
        xor     al, al
.t:     mov     [t_app], al
        call    app_ptr
        cmp     byte [si+A_OPEN], 0
        je      .tn
        mov     bl, [zcount]
        xor     bh, bh
        mov     byte [t_pressed], 0
        cmp     al, [zlist+bx-1]
        jne     .tup
        mov     byte [t_pressed], 1
.tup:   RECT    [tb_x], 188, [tb_bw], 11
        cmp     byte [t_pressed], 0
        je      .tr
        BEVEL   0, 15
        BEVEL   8, 7
        jmp     .tt
.tr:    BEVEL   15, 0
        BEVEL   7, 8
.tt:    sub     cx, 2
        call    clip_push
        jc      .tc
        mov     ax, [tb_x]
        add     ax, 4
        mov     bx, 190
        cmp     byte [t_pressed], 0
        je      .tx
        inc     ax
        inc     bx
.tx:    PEN     0
        push    ax
        mov     al, [t_app]
        call    label_ptr
        pop     ax
        call    draw_str
.tc:    call    clip_pop
        mov     ax, [tb_bw]
        add     ax, 2
        add     [tb_x], ax
.tn:    mov     al, [t_app]
        inc     al
        cmp     al, NAPPS
        jb      .t
.clock: RECT    CLK_X, 188, 70, 11
        BEVEL   8, 15
        PEN     0
        mov     ax, CLK_X + 3
        mov     bx, 190
        mov     si, time_str
        call    draw_str
.r:     ret

draw_menu:
        cmp     byte [menu_open], 0
        je      .r
        RECT    MENU_X, MENU_Y, MENU_W, MENU_H
        call    clip_test
        jc      .r
        BEVEL   7, 0
        BEVEL   15, 8
        PEN     7
        call    fill_rect
        RECT    MENU_X + 3, MENU_Y + 3, 16, MENU_H - 6
        mov     byte [grad_base], 0x20
        call    vgrad
        mov     ax, MENU_X + 7          ; "7GUI" down the stripe
        mov     bx, MENU_Y + MENU_H - 3 - 38
        PEN     14
        mov     dl, '7'
        call    draw_char
        PEN     15
        add     bx, 9
        mov     dl, 'G'
        call    draw_char
        add     bx, 9
        mov     dl, 'U'
        call    draw_char
        add     bx, 9
        mov     dl, 'I'
        call    draw_char
        mov     byte [m_i], 0
        mov     word [m_y], MENU_Y + 3
.i:     mov     al, [m_i]
        mov     bx, [m_y]
        mov     byte [t_pen], 0
        cmp     al, [menu_hover]
        jne     .ni
        mov     byte [t_pen], 15
        PEN     1
        mov     ax, MENU_X + 21
        mov     cx, MENU_W - 24
        mov     dx, MENU_IH
        call    fill_rect
.ni:    mov     ah, [m_i]
        xor     al, al
        add     ax, icons
        mov     si, ax
        mov     ax, MENU_X + 23
        inc     bx
        mov     cx, 16
        mov     dx, 16
        call    blit_sprite
        mov     al, [t_pen]
        mov     [pen], al
        mov     al, [m_i]
        call    label_ptr
        mov     ax, MENU_X + 44
        add     bx, 4
        call    draw_str
        add     word [m_y], MENU_IH
        inc     byte [m_i]
        cmp     byte [m_i], NAPPS
        jb      .i
.r:     ret

; -------------------------------------------------------------------
; the clock window: an analog face (sine table) and an LCD
; -------------------------------------------------------------------
draw_clock:
        PEN     7
        RECT    [body_x], [body_y], [body_w], [body_h]
        call    fill_rect
        mov     ax, [body_x]
        add     ax, 34
        mov     [cc_x], ax
        mov     ax, [body_y]
        add     ax, 33
        mov     [cc_y], ax
        PEN     15                      ; the face: spans from a quarter of the sine
        mov     word [pl_len], 29
        mov     byte [ang], 0
.disc:  mov     al, [ang]
        call    polar
        mov     [t_hx], ax
        mov     [t_hy], bx
        mov     ax, [cc_x]
        sub     ax, [t_hx]
        mov     cx, [t_hx]
        shl     cx, 1
        inc     cx
        mov     dx, 1
        mov     bx, [cc_y]
        add     bx, [t_hy]
        call    fill_rect
        mov     bx, [cc_y]
        sub     bx, [t_hy]
        call    fill_rect
        inc     byte [ang]
        cmp     byte [ang], 65
        jb      .disc
        PEN     0
        mov     word [pl_len], 30
        call    ring
        PEN     8
        mov     word [pl_len], 29
        call    ring
        PEN     0                       ; 12 hour marks
        mov     word [pl_len], 25
        mov     byte [tk], 0
.tk:    mov     al, [tk]
        xor     ah, ah
        mov     cl, 6
        shl     ax, cl
        mov     cl, 3
        div     cl
        call    polar
        add     ax, [cc_x]
        add     bx, [cc_y]
        mov     cx, 2
        mov     dx, 2
        call    fill_rect
        inc     byte [tk]
        cmp     byte [tk], 12
        jb      .tk
        mov     al, [rtc_hm+1]
        call    bcd_bin
        mov     [hr], al
        mov     al, [rtc_hm]
        call    bcd_bin
        mov     [mn], al
        mov     al, [rtc_s]
        call    bcd_bin
        mov     [sc], al
        mov     al, [hr]                ; hour: ((h mod 12) * 60 + m) * 16 / 45
        xor     ah, ah
        mov     bl, 12
        div     bl
        mov     al, ah
        xor     ah, ah
        mov     bx, 60
        mul     bx
        mov     bl, [mn]
        xor     bh, bh
        add     ax, bx
        mov     cl, 4
        shl     ax, cl
        xor     dx, dx
        mov     bx, 45
        div     bx
        PEN     0
        mov     byte [hand_thick], 1
        mov     cx, 15
        call    hand
        mov     al, [mn]                ; minute: (m * 60 + s) * 16 / 225
        xor     ah, ah
        mov     bx, 60
        mul     bx
        mov     bl, [sc]
        xor     bh, bh
        add     ax, bx
        mov     cl, 4
        shl     ax, cl
        xor     dx, dx
        mov     bx, 225
        div     bx
        mov     byte [hand_thick], 0
        mov     cx, 23
        call    hand
        mov     al, [sc]                ; second: s * 64 / 15
        xor     ah, ah
        mov     cl, 6
        shl     ax, cl
        mov     bl, 15
        div     bl
        PEN     12
        mov     cx, 26
        call    hand
        PEN     0
        mov     ax, [cc_x]
        dec     ax
        mov     bx, [cc_y]
        dec     bx
        mov     cx, 3
        mov     dx, 3
        call    fill_rect
        PEN     12
        inc     ax
        inc     bx
        mov     cx, 1
        mov     dx, 1
        call    fill_rect
        mov     ax, [body_x]            ; the LCD
        add     ax, 70
        mov     bx, [body_y]
        add     bx, 6
        mov     cx, 118
        mov     dx, 40
        BEVEL   8, 15
        PEN     16
        call    fill_rect
        PEN     17
        mov     ax, [body_x]
        add     ax, 75
        mov     bx, [body_y]
        add     bx, 10
        mov     si, time_str
        mov     cx, 5
.dg:    mov     dl, [si]
        call    draw_big
        add     ax, 16
        inc     si
        loop    .dg
        add     bx, 22
        mov     si, time_str + 5
        call    draw_str
        PEN     0
        mov     ax, [body_x]
        add     ax, 89
        mov     bx, [body_y]
        add     bx, 52
        mov     si, date_str
        jmp     draw_str

ring:                                   ; 256 points at [pl_len] around (cc_x, cc_y)
        mov     byte [ang], 0
.l:     mov     al, [ang]
        call    polar
        add     ax, [cc_x]
        add     bx, [cc_y]
        call    put_pixel
        inc     byte [ang]
        jnz     .l
        ret

hand:                                   ; AL = angle (256 = full turn), CX = length
        mov     [pl_len], cx
        call    polar
        add     ax, [cc_x]
        add     bx, [cc_y]
        mov     [l_x1], ax
        mov     [l_y1], bx
        mov     ax, [cc_x]
        mov     [l_x0], ax
        mov     ax, [cc_y]
        mov     [l_y0], ax
        call    draw_line
        cmp     byte [hand_thick], 0
        je      .r
        inc     word [l_x0]
        inc     word [l_x1]
        call    draw_line
        dec     word [l_x0]
        dec     word [l_x1]
        inc     word [l_y0]
        inc     word [l_y1]
        call    draw_line
.r:     ret

polar:                                  ; AL = angle, [pl_len] -> AX = dx, BX = dy (12 o'clock = 0)
        push    cx
        push    dx
        mov     [pl_a], al
        call    sinv
        imul    word [pl_len]
        mov     cl, 6
        sar     ax, cl
        push    ax
        mov     al, [pl_a]
        add     al, 64
        call    sinv
        imul    word [pl_len]
        mov     cl, 6
        sar     ax, cl
        neg     ax
        mov     bx, ax
        pop     ax
        pop     dx
        pop     cx
        ret

sinv:                                   ; AL = angle -> AX = 63 sin, signed
        push    bx
        mov     bl, al
        xor     bh, bh
        mov     al, [sine+bx]
        xor     ah, ah
        shl     ax, 1
        sub     ax, 63
        pop     bx
        ret

draw_line:                              ; Bresenham, (l_x0, l_y0) to (l_x1, l_y1)
        push    ax
        push    bx
        push    cx
        push    si
        push    bp
        mov     ax, [l_x1]
        sub     ax, [l_x0]
        mov     si, 1
        jge     .1
        neg     ax
        neg     si
.1:     mov     [ln_dx], ax
        mov     [ln_sx], si
        mov     ax, [l_y1]
        sub     ax, [l_y0]
        mov     si, 1
        jge     .2
        neg     ax
        neg     si
.2:     neg     ax
        mov     [ln_dy], ax
        mov     [ln_sy], si
        mov     bp, [ln_dx]
        add     bp, ax
        mov     ax, [l_x0]
        mov     bx, [l_y0]
.l:     call    put_pixel
        cmp     ax, [l_x1]
        jne     .s
        cmp     bx, [l_y1]
        je      .d
.s:     mov     cx, bp
        shl     cx, 1
        cmp     cx, [ln_dy]
        jl      .nx
        add     bp, [ln_dy]
        add     ax, [ln_sx]
.nx:    cmp     cx, [ln_dx]
        jg      .l
        add     bp, [ln_dx]
        add     bx, [ln_sy]
        jmp     .l
.d:     pop     bp
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; -------------------------------------------------------------------
; text: word-wrapped layout. 0 ends, 10 = new line, 1, c = colour c
; -------------------------------------------------------------------
layout_text:                            ; SI = text, [lt_x], [lt_y], [lt_cols], [lt_draw]
        push    si
        mov     word [lt_col], 0
        mov     word [lt_line], 0
.loop:  mov     al, [si]
        test    al, al
        jz      .done
        cmp     al, 10
        jne     .nnl
        inc     si
        mov     word [lt_col], 0
        inc     word [lt_line]
        jmp     .loop
.nnl:   cmp     al, ' '
        jne     .nsp
        inc     si
        cmp     word [lt_col], 0
        je      .loop
        inc     word [lt_col]
        jmp     .loop
.nsp:   cmp     al, 1
        jne     .word
        mov     al, [si+1]
        mov     [pen], al
        add     si, 2
        jmp     .loop
.word:  mov     di, si                  ; measure the word
        xor     cx, cx
.m:     mov     al, [di]
        test    al, al
        jz      .md
        cmp     al, 10
        je      .md
        cmp     al, ' '
        je      .md
        cmp     al, 1
        jne     .mc
        add     di, 2
        jmp     .m
.mc:    inc     cx
        inc     di
        jmp     .m
.md:    mov     ax, [lt_col]
        test    ax, ax
        jz      .put
        add     ax, cx
        cmp     ax, [lt_cols]
        jbe     .put
        mov     word [lt_col], 0
        inc     word [lt_line]
.put:   cmp     si, di
        jae     .loop
        mov     al, [si]
        cmp     al, 1
        jne     .pc
        mov     al, [si+1]
        mov     [pen], al
        add     si, 2
        jmp     .put
.pc:    mov     ax, [lt_col]
        cmp     ax, [lt_cols]
        jb      .pc2
        mov     word [lt_col], 0
        inc     word [lt_line]
.pc2:   cmp     byte [lt_draw], 0
        je      .nd
        mov     ax, [lt_line]
        mov     bx, LH
        mul     bx
        add     ax, [lt_y]
        mov     bx, ax
        mov     ax, [lt_col]
        mov     cl, 3
        shl     ax, cl
        add     ax, [lt_x]
        mov     dl, [si]
        call    draw_char
.nd:    inc     si
        inc     word [lt_col]
        jmp     .put
.done:  pop     si
        ret

draw_str:                               ; AX, BX, SI = string, colour [pen]
        push    ax
        push    dx
        push    si
.l:     mov     dl, [si]
        inc     si
        test    dl, dl
        jz      .d
        call    draw_char
        add     ax, 8
        jmp     .l
.d:     pop     si
        pop     dx
        pop     ax
        ret

draw_char:                              ; AX, BX, DL = character
        push    cx
        push    dx
        push    si
        xor     dh, dh
        mov     si, dx
        shl     si, 1
        shl     si, 1
        shl     si, 1
        add     si, font8
        mov     cx, 8
        call    draw_glyph
        pop     si
        pop     dx
        pop     cx
        ret

draw_glyph:                             ; AX, BX, SI = rows of 8 pixels, CX = rows, clipped
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        cmp     ax, [clip_x1]
        jge     .r
        mov     dx, ax
        add     dx, 8
        cmp     dx, [clip_x0]
        jle     .r
        mov     dh, [pen]
.row:   cmp     bx, [clip_y0]
        jl      .next
        cmp     bx, [clip_y1]
        jge     .r
        mov     dl, [si]
        test    dl, dl
        jz      .next
        mov     di, bx
        shl     di, 1
        mov     di, [rowoff+di]
        add     di, ax
        mov     bp, ax
.bit:   shl     dl, 1
        jnc     .nb
        cmp     bp, [clip_x0]
        jl      .nb
        cmp     bp, [clip_x1]
        jge     .nb
        mov     [es:di], dh
.nb:    inc     di
        inc     bp
        test    dl, dl
        jnz     .bit
.next:  inc     si
        inc     bx
        loop    .row
.r:     pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

load_big:                               ; DL = character -> bigbuf, its 16 ROM rows
        push    ax
        push    bx
        push    cx
        push    si
        push    ds
        mov     al, dl
        xor     ah, ah
        mov     cl, 4
        shl     ax, cl
        lds     si, [font_off]
        add     si, ax
        xor     bx, bx
.l:     mov     al, [si+bx]
        mov     [cs:bigbuf+bx], al
        inc     bx
        cmp     bx, 16
        jb      .l
        pop     ds
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

draw_big:                               ; AX, BX, DL: an 8x16 ROM glyph at 2x
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        call    load_big
        xor     si, si
        mov     cx, 2
        mov     dx, 2
.row:   push    ax
        mov     dl, [bigbuf+si]
        mov     [wm_cur], dl
        mov     dx, 2
.bit:   shl     byte [wm_cur], 1
        jnc     .nb
        call    fill_rect
.nb:    add     ax, 2
        cmp     byte [wm_cur], 0
        jne     .bit
        pop     ax
        add     bx, 2
        inc     si
        cmp     si, 16
        jb      .row
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; -------------------------------------------------------------------
; primitives, into the back buffer (ES), clipped to clip_x0..clip_y1
; -------------------------------------------------------------------
clip_test:                              ; AX, BX, CX, DX: CF=1 if outside the clip
        push    ax
        cmp     ax, [clip_x1]
        jge     .no
        add     ax, cx
        cmp     ax, [clip_x0]
        jle     .no
        cmp     bx, [clip_y1]
        jge     .no
        mov     ax, bx
        add     ax, dx
        cmp     ax, [clip_y0]
        jle     .no
        pop     ax
        clc
        ret
.no:    pop     ax
        stc
        ret

clip_push:                              ; clip &= AX, BX, CX, DX (one level). CF=1 if empty
        push    ax
        push    bx
        push    cx
        push    dx
        push    ax
        mov     ax, [clip_x0]
        mov     [clip_sv], ax
        mov     ax, [clip_y0]
        mov     [clip_sv+2], ax
        mov     ax, [clip_x1]
        mov     [clip_sv+4], ax
        mov     ax, [clip_y1]
        mov     [clip_sv+6], ax
        pop     ax
        add     cx, ax
        add     dx, bx
        cmp     ax, [clip_x0]
        jle     .a
        mov     [clip_x0], ax
.a:     cmp     cx, [clip_x1]
        jge     .b
        mov     [clip_x1], cx
.b:     cmp     bx, [clip_y0]
        jle     .c
        mov     [clip_y0], bx
.c:     cmp     dx, [clip_y1]
        jge     .d
        mov     [clip_y1], dx
.d:     mov     ax, [clip_x0]
        cmp     ax, [clip_x1]
        jge     .e
        mov     ax, [clip_y0]
        cmp     ax, [clip_y1]
        jge     .e
        clc
        jmp     .r
.e:     stc
.r:     pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

clip_pop:
        push    ax
        mov     ax, [clip_sv]
        mov     [clip_x0], ax
        mov     ax, [clip_sv+2]
        mov     [clip_y0], ax
        mov     ax, [clip_sv+4]
        mov     [clip_x1], ax
        mov     ax, [clip_sv+6]
        mov     [clip_y1], ax
        pop     ax
        ret

fill_rect:                              ; AX, BX, CX, DX = x, y, w, h in colour [pen]
        push    ax
        push    bx
        push    cx
        push    dx
        push    di
        add     cx, ax
        add     dx, bx
        cmp     ax, [clip_x0]
        jge     .a
        mov     ax, [clip_x0]
.a:     cmp     cx, [clip_x1]
        jle     .b
        mov     cx, [clip_x1]
.b:     sub     cx, ax
        jle     .r
        cmp     bx, [clip_y0]
        jge     .c
        mov     bx, [clip_y0]
.c:     cmp     dx, [clip_y1]
        jle     .d
        mov     dx, [clip_y1]
.d:     sub     dx, bx
        jle     .r
        shl     bx, 1
        mov     di, [rowoff+bx]
        add     di, ax
        mov     al, [pen]
        mov     ah, al
        mov     bx, SCR_W
        sub     bx, cx
.row:   push    cx
        shr     cx, 1
        rep     stosw
        jnc     .e
        stosb
.e:     pop     cx
        add     di, bx
        dec     dx
        jnz     .row
.r:     pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

put_pixel:                              ; AX, BX in colour [pen]
        cmp     ax, [clip_x0]
        jl      .r
        cmp     ax, [clip_x1]
        jge     .r
        cmp     bx, [clip_y0]
        jl      .r
        cmp     bx, [clip_y1]
        jge     .r
        push    ax
        push    di
        mov     di, bx
        shl     di, 1
        mov     di, [rowoff+di]
        add     di, ax
        mov     al, [pen]
        mov     [es:di], al
        pop     di
        pop     ax
.r:     ret

bevel:                                  ; AX, BX, CX, DX: [c_tl] top/left, [c_br] bottom/right
        mov     [bv_x], ax              ; returns the rect 1 pixel inside
        mov     [bv_y], bx
        mov     [bv_w], cx
        mov     [bv_h], dx
        push    ax
        mov     al, [c_tl]
        mov     [pen], al
        pop     ax
        mov     dx, 1
        call    fill_rect
        mov     cx, 1
        mov     dx, [bv_h]
        call    fill_rect
        push    ax
        mov     al, [c_br]
        mov     [pen], al
        pop     ax
        add     ax, [bv_w]
        dec     ax
        call    fill_rect
        mov     ax, [bv_x]
        add     bx, [bv_h]
        dec     bx
        mov     cx, [bv_w]
        mov     dx, 1
        call    fill_rect
        mov     ax, [bv_x]
        inc     ax
        mov     bx, [bv_y]
        inc     bx
        mov     cx, [bv_w]
        sub     cx, 2
        mov     dx, [bv_h]
        sub     dx, 2
        ret

hgrad:                                  ; AX, BX, CX, DX: 32 colours from [grad_base], left to right
        push    ax
        push    cx
        push    si
        push    bp
        mov     [g_w], cx
        push    ax
        mov     al, [grad_base]
        mov     [pen], al
        pop     ax
        mov     si, cx
        test    si, si
        jle     .d
        xor     bp, bp
        mov     cx, 1
.c:     call    fill_rect
        inc     ax
        add     bp, 32
.adj:   cmp     bp, [g_w]
        jb      .n
        sub     bp, [g_w]
        inc     byte [pen]
        jmp     .adj
.n:     dec     si
        jnz     .c
.d:     pop     bp
        pop     si
        pop     cx
        pop     ax
        ret

vgrad:                                  ; the same, top to bottom
        push    bx
        push    dx
        push    si
        push    bp
        mov     [g_w], dx
        push    ax
        mov     al, [grad_base]
        mov     [pen], al
        pop     ax
        mov     si, dx
        test    si, si
        jle     .d
        xor     bp, bp
        mov     dx, 1
.c:     call    fill_rect
        inc     bx
        add     bp, 32
.adj:   cmp     bp, [g_w]
        jb      .n
        sub     bp, [g_w]
        inc     byte [pen]
        jmp     .adj
.n:     dec     si
        jnz     .c
.d:     pop     bp
        pop     si
        pop     dx
        pop     bx
        ret

blit_sprite:                            ; AX, BX, CX = w, DX = h, SI = pixels (0FFh = clear)
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        mov     [bs_w], cx
        mov     bp, dx
.row:   cmp     bx, [clip_y0]
        jl      .skip
        cmp     bx, [clip_y1]
        jge     .done
        push    ax
        push    si
        mov     di, bx
        shl     di, 1
        mov     di, [rowoff+di]
        add     di, ax
        mov     cx, [bs_w]
.px:    mov     dl, [si]
        inc     si
        cmp     dl, 0xFF
        je      .np
        cmp     ax, [clip_x0]
        jl      .np
        cmp     ax, [clip_x1]
        jge     .np
        mov     [es:di], dl
.np:    inc     di
        inc     ax
        loop    .px
        pop     si
        pop     ax
.skip:  add     si, [bs_w]
        inc     bx
        dec     bp
        jnz     .row
.done:  pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

blit_far:                               ; AX, BX, CX = w, DX = h, [bf_seg]:SI, opaque
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        mov     [bf_x], ax
        mov     [bf_w], cx
        mov     [bf_y], bx
        mov     [bf_h], dx
        cmp     ax, [clip_x0]
        jge     .1
        mov     ax, [clip_x0]
.1:     mov     cx, [bf_x]
        add     cx, [bf_w]
        cmp     cx, [clip_x1]
        jle     .2
        mov     cx, [clip_x1]
.2:     sub     cx, ax
        jle     .r
        mov     [bf_cnt], cx
        mov     [bf_xa], ax
        sub     ax, [bf_x]
        add     si, ax
        mov     dx, bx
        add     dx, [bf_h]
        cmp     dx, [clip_y1]
        jle     .3
        mov     dx, [clip_y1]
.3:     cmp     bx, [clip_y0]
        jge     .4
        mov     ax, [clip_y0]
        sub     ax, bx
        push    dx
        mul     word [bf_w]
        pop     dx
        add     si, ax
        mov     bx, [clip_y0]
.4:     sub     dx, bx
        jle     .r
        mov     di, bx
        shl     di, 1
        mov     di, [rowoff+di]
        add     di, [bf_xa]
        mov     bx, [bf_w]
        mov     ax, [bf_cnt]
        mov     bp, [bf_seg]
        push    ds
        mov     ds, bp
.row:   mov     cx, ax
        push    si
        push    di
        rep     movsb
        pop     di
        pop     si
        add     si, bx
        add     di, SCR_W
        dec     dx
        jnz     .row
        pop     ds
.r:     pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; -------------------------------------------------------------------
; presenting: dirty rect -> video memory in vblank, then the cursor
; -------------------------------------------------------------------
present:
        cmp     byte [dirty], 0
        jne     .go
        cmp     byte [cursor_on], 0
        je      .go
        mov     ax, [cur_x]
        cmp     ax, [drawn_x]
        jne     .go
        mov     ax, [cur_y]
        cmp     ax, [drawn_y]
        jne     .go
        ret
.go:    call    vsync
        cmp     byte [dirty], 0
        je      .cur
        mov     ax, [dirty_x0]
        mov     bx, [dirty_y0]
        mov     cx, [dirty_x1]
        sub     cx, ax
        mov     dx, [dirty_y1]
        sub     dx, bx
        call    copy_rect
        mov     byte [dirty], 0
.cur:   cmp     byte [cursor_on], 0
        je      .draw
        RECT    [drawn_x], [drawn_y], CUR_W, CUR_H
        call    copy_rect
.draw:  mov     ax, [cur_x]
        mov     [drawn_x], ax
        mov     ax, [cur_y]
        mov     [drawn_y], ax
        mov     byte [cursor_on], 1
        jmp     draw_cursor

vsync:  push    ax
        push    dx
        mov     dx, 0x3DA
.a:     in      al, dx
        test    al, 8
        jnz     .a
.b:     in      al, dx
        test    al, 8
        jz      .b
        pop     dx
        pop     ax
        ret

copy_rect:                              ; AX, BX, CX, DX: back buffer -> A000
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es
        add     cx, ax
        add     dx, bx
        cmp     ax, 0
        jge     .a
        xor     ax, ax
.a:     cmp     bx, 0
        jge     .b
        xor     bx, bx
.b:     cmp     cx, SCR_W
        jle     .c
        mov     cx, SCR_W
.c:     cmp     dx, SCR_H
        jle     .d
        mov     dx, SCR_H
.d:     sub     cx, ax
        jle     .r
        sub     dx, bx
        jle     .r
        shl     bx, 1
        mov     di, [rowoff+bx]
        add     di, ax
        mov     si, di
        mov     bx, SCR_W
        sub     bx, cx
        mov     ax, BB_SEG
        mov     ds, ax
        mov     ax, VGA_SEG
        mov     es, ax
.row:   push    cx
        shr     cx, 1
        rep     movsw
        jnc     .e
        movsb
.e:     pop     cx
        add     si, bx
        add     di, bx
        dec     dx
        jnz     .row
.r:     pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

draw_cursor:                            ; the arrow at (drawn_x, drawn_y), straight into A000
        push    es
        mov     ax, VGA_SEG
        mov     es, ax
        mov     si, cursor_spr
        mov     bx, [drawn_y]
        mov     bp, CUR_H
.row:   cmp     bx, SCR_H
        jge     .d
        mov     di, bx
        shl     di, 1
        mov     di, [rowoff+di]
        mov     ax, [drawn_x]
        add     di, ax
        mov     cx, CUR_W
.px:    mov     dl, [si]
        inc     si
        cmp     dl, 0xFF
        je      .n
        cmp     ax, SCR_W
        jae     .n
        mov     [es:di], dl
.n:     inc     di
        inc     ax
        loop    .px
        inc     bx
        dec     bp
        jnz     .row
.d:     pop     es
        ret

; ===================================================================
; data
; ===================================================================
;          x    y    w    h   title     text
apps:   dw 124,   4, 192,   0, t_about,  x_about
        db K_TEXT, 0, 0, 0
        dw 100,  10, 214,   0, t_work,   x_work
        db K_TEXT, 0, 0, 0
        dw  70,  14, 244,   0, t_proj,   x_proj
        db K_TEXT, 0, 0, 0
        dw 138,  66, 180,   0, t_gh,     x_gh
        db K_TEXT, 0, 0, 0
        dw 160,  24, 134, 146, t_girl,   0
        db K_GIRL, 0, 0, 0
        dw 114,  94, 200,  84, t_clock,  0
        db K_CLOCK, 0, 0, 0
        dw 120,  24, 196,   0, t_readme, x_readme
        db K_TERM, 0, 0, 0

icon_pos:
        dw 34, 8,  34, 48,  34, 88,  34, 128
        dw 96, 8,  96, 48,  96, 88
labels: dw l_about, l_work, l_proj, l_gh, l_girl, l_clock, l_readme

menu_rect       dw MENU_X, MENU_Y, MENU_W, MENU_H
menu_items_rect dw MENU_X + 21, MENU_Y + 3, MENU_W - 24, NAPPS * MENU_IH
start_rect      dw START_X, 188, START_W, 11

close_glyph     db 11000110b, 01101100b, 00111000b, 01101100b, 11000110b

l_about  db "About", 0
l_work   db "Work", 0
l_proj   db "Projects", 0
l_gh     db "GitHub", 0
l_girl   db "Girl", 0
l_clock  db "Clock", 0
l_readme db "Readme", 0
t_about  db "About Ali", 0
t_work   db "Work", 0
t_proj   db "Projects", 0
t_gh     db "GitHub", 0
t_girl   db "girl.raw", 0
t_clock  db "Clock", 0
t_readme db "README.TXT", 0
s_gui    db "GUI", 0

%define C(c) 1, c
%define BUL 1, 4, 7, 1, 0

x_about db C(1), "Ali Almohaya", C(0), 10
        db "a.k.a. ", C(4), "Almo7aya", C(0), 10, 10
        db "Staff Web Engineer at Anghami & OSN+.", 10, 10
        db "From Yemen, living in Riyadh.", 10, 10
        db "Beyond the web: low-level programming, emulation, C++ and graphics, just for the fun of it.", 0

x_work  db C(1), "Staff Web Engineer", C(0), 10
        db "at Anghami & OSN+", 10, 10
        db "Builds the web and smart-TV streaming apps. Specialist in video "
        db C(4), "playback", C(0), " and ", C(4), "DRM", C(0), ", the kind of work nobody notices when it's done right.", 10, 10
        db C(1), "Skills", C(0), 10
        db "TypeScript, JavaScript, React, Preact, Node.js, C++, Go, Rust, Lua, Docker, CI.", 0

x_proj  db BUL, " ", C(1), "KytyPS5", C(0), " open-source PS5 emulator in C++. Ali contributes fixes.", 10
        db BUL, " ", C(1), "PS5 Shader Lab", C(0), " C++20 shader regression tool.", 10
        db BUL, " ", C(1), "Learning KytyPS5", C(0), " a course on how a PS5 emulator works.", 10
        db BUL, " ", C(1), "GoWAN", C(0), " Go multi-WAN SOCKS5 for OpenWrt.", 10
        db BUL, " ", C(1), "openingh.nvim", C(0), " 163 stars", 10
        db BUL, " ", C(1), "neogruvbox.nvim", 10
        db BUL, " ", C(1), "7OS", 0

x_gh    db C(1), "github.com/Almo7aya", C(0), 10, 10
        db "Merged patches in:", 10
        db BUL, " Preact", 10
        db BUL, " LunarVim", 10
        db BUL, " ani-cli", 10
        db BUL, " Live Server", 0

x_readme db C(15), "7GUI 1.0", C(10), " for the 8086", 10, 10
        db "INT 13h disk loader", 10
        db "mode 13h, 256 colours", 10
        db "back buffer + vblank", 10
        db "PS/2 mouse, INT 15h", 10
        db "RTC clock, INT 1Ah", 10, 10
        db C(14), "double-click", C(10), " an icon to open it, drag a title bar to move. "
        db C(14), "Esc", C(10), " closes, ", C(14), "Tab", C(10), " cycles, ", C(14), "7", C(10), " opens the menu.", 10, 10
        db "C:\>", 0

time_str db "00:00:00", 0
date_str db "0000-00-00", 0

font_off    dw 0                        ; font_off, font_seg: a far pointer for LDS
font_seg    dw 0
old_1c      dd 0
ticks       dw 0
last_ticks  dw 0xFFFF
blink       db 0
rtc_s       db 0xFF
rtc_hm      dw 0xFFFF
have_mouse  db 0
mx          dw 320                      ; mouse, in a 640x200 space
my          dw 100
mbtn        db 0
mouse_moved db 0
ev_head     db 0
ev_tail     db 0
evq         times 16 * 4 db 0
cur_x       dw 160
cur_y       dw 100
drawn_x     dw 0
drawn_y     dw 0
cursor_on   db 0
pt_x        dw 0
pt_y        dw 0
lbtn        db 0
drag_app    db 0xFF
drag_dx     dw 0
drag_dy     dw 0
menu_open   db 0
menu_hover  db 0xFF
sel_icon    db 0xFF
last_icon   db 0xFF
last_click  dw 0
zcount      db 0
zlist       times 8 db 0
dirty       db 0
dirty_x0    dw 0
dirty_y0    dw 0
dirty_x1    dw 0
dirty_y1    dw 0
clip_x0     dw 0
clip_y0     dw 0
clip_x1     dw SCR_W
clip_y1     dw SCR_H
clip_sv     times 4 dw 0
pen         db 0
c_tl        db 0
c_br        db 0
grad_base   db 0
is_active   db 0
bv_x        dw 0
bv_y        dw 0
bv_w        dw 0
bv_h        dw 0
g_w         dw 0
tr          times 4 dw 0
bs_w        dw 0
bf_x        dw 0
bf_y        dw 0
bf_w        dw 0
bf_h        dw 0
bf_cnt      dw 0
bf_xa       dw 0
bf_seg      dw 0
lt_x        dw 0
lt_y        dw 0
lt_cols     dw 0
lt_col      dw 0
lt_line     dw 0
lt_draw     db 0
body_x      dw 0
body_y      dw 0
body_w      dw 0
body_h      dw 0
cc_x        dw 0
cc_y        dw 0
pl_len      dw 0
pl_a        db 0
ang         db 0
tk          db 0
hr          db 0
mn          db 0
sc          db 0
hand_thick  db 0
t_hx        dw 0
t_hy        dw 0
l_x0        dw 0
l_y0        dw 0
l_x1        dw 0
l_y1        dw 0
ln_dx       dw 0
ln_dy       dw 0
ln_sx       dw 0
ln_sy       dw 0
wm_bits     db 0
wm_cur      db 0
bigbuf      times 16 db 0
tb_bw       dw 0
tb_x        dw 0
t_app       db 0
t_pressed   db 0
t_pen       db 0
m_i         db 0
m_y         dw 0
rowoff      times SCR_H dw 0

sine:
%include "sine.inc"
palette:    incbin "palette.bin"
icons:      incbin "icons.bin"
cursor_spr: incbin "cursor.bin"
font8       times 256 * 8 db 0
girl:       incbin "girl.bin"
image_end:
        times (512 - (image_end - $$) % 512) % 512 db 0
STAGE2_SECTORS equ (image_end - stage2 + 511) / 512
        times ((image_end - $$) / (0x10000 - 0x7C00)) * -1 db 0     ; fails if it outgrows segment 0
