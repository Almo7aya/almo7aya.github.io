; almo7aya.asm · 7OS, a tiny real-mode operating system for almo7aya.dev
;
;   build:  nasm -f bin almo7aya.asm -o almo7aya.img -l almo7aya.lst
;   run:    qemu-system-i386 -drive format=raw,file=almo7aya.img
;
; stage 1 is the 512-byte boot sector: it loads stage 2 from the same disk
; with INT 13h and jumps to it. stage 2 is a colour text console that writes
; straight into video memory at B800:0000, plus a little shell.

cpu 8086
bits 16
org 0x7C00

; ===================================================================
; stage 1 · boot sector
; ===================================================================
boot:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 0x7C00              ; stack grows down, away from us
        sti
        cld
        mov     [boot_drive], dl        ; the BIOS tells us where we came from

        mov     si, s_loading
        call    bputs

        mov     ax, 0x0200 + STAGE2_SECTORS     ; AH=02h read, AL=sector count
        mov     cx, 0x0002              ; cylinder 0, sector 2
        xor     dh, dh                  ; head 0
        mov     dl, [boot_drive]
        mov     bx, stage2              ; ES:BX = 0000:7E00
        int     0x13
        jc      .fail
        jmp     0x0000:stage2           ; far jump also normalises CS to 0

.fail:  mov     si, s_diskerr
        call    bputs
.halt:  hlt
        jmp     .halt

bputs:                                  ; DS:SI -> BIOS teletype
        lodsb
        test    al, al
        jz      .done
        mov     ah, 0x0E
        xor     bx, bx
        int     0x10
        jmp     bputs
.done:  ret

boot_drive      db 0x80
s_loading       db "7OS: loading stage 2...", 13, 10, 0
s_diskerr       db "disk read error", 0

        times 510-($-$$) db 0
        dw      0xAA55                  ; the BIOS refuses to boot without this

; ===================================================================
; stage 2 · loaded at 0000:7E00
; ===================================================================
COLOR   equ 0x01                        ; in strings: 0x01, attr = switch colour
ATTR_TXT        equ 0x07
ATTR_HI         equ 0x0F
ATTR_DIM        equ 0x08
ATTR_CYAN       equ 0x0B
ATTR_YELLOW     equ 0x0E
ATTR_GREEN      equ 0x0A
ATTR_RED        equ 0x0C
ATTR_MAGENTA    equ 0x0D
ATTR_BAR        equ 0x1F                ; white on blue
ATTR_BAR_HI     equ 0x1E                ; yellow on blue

stage2:
        mov     ax, 0x0003              ; 80x25 colour text, clears the screen
        int     0x10
        call    draw_header
        mov     byte [row], 2
        mov     byte [col], 0
        call    sync_cursor

        mov     si, s_boot
        call    type_out
        mov     si, s_hint
        call    puts

shell:
        mov     si, s_prompt
        call    puts
        call    read_line
        call    run_command
        jmp     shell

; -------------------------------------------------------------------
; commands
; -------------------------------------------------------------------
run_command:
        mov     si, line
        cmp     byte [si], 0
        je      .done
        mov     bx, commands
.next:  mov     di, [bx]
        test    di, di
        jz      .unknown
        mov     si, line
        call    strcmp
        je      .found
        add     bx, 4
        jmp     .next
.found: call    [bx+2]
        ret
.unknown:
        mov     si, s_unknown1
        call    puts
        mov     si, line
        call    puts
        mov     si, s_unknown2
        call    puts
.done:  ret

commands:
        dw c_help,    cmd_help
        dw c_about,   cmd_about
        dw c_work,    cmd_work
        dw c_hobbies, cmd_hobbies
        dw c_github,  cmd_github
        dw c_time,    cmd_time
        dw c_ver,     cmd_ver
        dw c_clear,   cmd_clear
        dw c_cls,     cmd_clear
        dw c_seven,   cmd_seven
        dw c_panic,   cmd_panic
        dw c_reboot,  cmd_reboot
        dw 0

c_help    db "help", 0
c_about   db "about", 0
c_work    db "work", 0
c_hobbies db "hobbies", 0
c_github  db "github", 0
c_time    db "time", 0
c_ver     db "ver", 0
c_clear   db "clear", 0
c_cls     db "cls", 0
c_seven   db "7", 0
c_panic   db "panic", 0
c_reboot  db "reboot", 0

cmd_help:
        mov     si, s_help
        jmp     puts
cmd_about:
        mov     si, s_about
        jmp     type_out
cmd_work:
        mov     si, s_work
        jmp     type_out
cmd_hobbies:
        mov     si, s_hobbies
        jmp     type_out
cmd_github:
        mov     si, s_github
        jmp     type_out
cmd_ver:
        mov     si, s_ver
        jmp     puts
cmd_seven:
        mov     si, s_seven
        jmp     puts

cmd_time:                               ; INT 1Ah/AH=02h: RTC time in BCD
        mov     ah, 0x02
        int     0x1A
        jc      .none
        push    dx
        push    cx
        mov     si, s_time
        call    puts
        pop     cx
        mov     al, ch
        call    put_bcd
        mov     al, ':'
        call    putc
        mov     al, cl
        call    put_bcd
        mov     al, ':'
        call    putc
        pop     dx
        mov     al, dh
        call    put_bcd
        mov     al, 13
        call    putc
        mov     al, 10
        jmp     putc
.none:  mov     si, s_notime
        jmp     puts

cmd_clear:
        mov     ax, 0x0600              ; AH=06h scroll up, AL=0 clears
        mov     bh, ATTR_TXT
        mov     cx, 0x0100              ; from row 1, col 0
        mov     dx, 0x184F              ; to row 24, col 79
        int     0x10
        mov     byte [row], 1
        mov     byte [col], 0
        jmp     sync_cursor

cmd_panic:
        mov     si, s_panic
        call    puts
        db      0x0F, 0x0B              ; ud2: invalid opcode on purpose
        cli
.hang:  hlt
        jmp     .hang

cmd_reboot:
        mov     si, s_reboot
        call    puts
        int     0x19                    ; BIOS bootstrap loader: start over

; -------------------------------------------------------------------
; console: writes words (attr << 8 | char) straight into B800:0000
; -------------------------------------------------------------------
row     db 0
col     db 0
attr    db ATTR_TXT
fast    db 0

draw_header:                            ; row 0: a blue title bar
        push    es
        mov     ax, 0xB800
        mov     es, ax
        xor     di, di
        mov     ax, (ATTR_BAR << 8) | ' '
        mov     cx, 80
        rep     stosw
        xor     di, di
        mov     si, s_bar_left
        mov     ah, ATTR_BAR
        call    .text
        mov     di, (80 - 21) * 2
        mov     si, s_bar_right
        mov     ah, ATTR_BAR_HI
        call    .text
        pop     es
        ret
.text:  lodsb
        test    al, al
        jz      .ret
        stosw
        jmp     .text
.ret:   ret

putc:                                   ; AL = character, uses [attr]
        push    ax
        push    bx
        push    di
        push    es
        cmp     al, 13
        je      .cr
        cmp     al, 10
        je      .lf
        cmp     al, 8
        je      .bs
        mov     bx, 0xB800
        mov     es, bx
        call    cell_offset
        mov     ah, [attr]
        mov     [es:di], ax
        inc     byte [col]
        cmp     byte [col], 80
        jb      .out
.lf:    mov     byte [col], 0
        inc     byte [row]
        cmp     byte [row], 25
        jb      .out
        call    scroll
        jmp     .out
.cr:    mov     byte [col], 0
        jmp     .out
.bs:    cmp     byte [col], 0
        je      .out
        dec     byte [col]
        mov     bx, 0xB800
        mov     es, bx
        call    cell_offset
        mov     word [es:di], (ATTR_TXT << 8) | ' '
.out:   call    sync_cursor
        pop     es
        pop     di
        pop     bx
        pop     ax
        ret

cell_offset:                            ; DI = (row * 80 + col) * 2
        push    ax
        mov     al, [row]
        mov     ah, 80
        mul     ah
        add     al, [col]
        adc     ah, 0
        shl     ax, 1
        mov     di, ax
        pop     ax
        ret

scroll:                                 ; keep the title bar, scroll rows 1-24
        push    ax
        push    bx
        push    cx
        push    dx
        mov     ax, 0x0601
        mov     bh, ATTR_TXT
        mov     cx, 0x0100
        mov     dx, 0x184F
        int     0x10
        mov     byte [row], 24
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

sync_cursor:                            ; move the blinking hardware cursor
        push    ax
        push    bx
        push    dx
        mov     ah, 0x02
        xor     bh, bh
        mov     dh, [row]
        mov     dl, [col]
        int     0x10
        pop     dx
        pop     bx
        pop     ax
        ret

puts:                                   ; DS:SI, 0-terminated, 0x01 xx = colour
        mov     byte [fast], 1
        jmp     emit

type_out:                               ; same, but typed out like a terminal
        mov     byte [fast], 0
emit:   lodsb
        test    al, al
        jz      .done
        cmp     al, COLOR
        jne     .char
        lodsb
        mov     [attr], al
        jmp     emit
.char:  call    putc
        cmp     byte [fast], 0
        jne     emit
        call    delay
        jmp     emit
.done:  mov     byte [attr], ATTR_TXT
        ret

delay:                                  ; ~12 ms per character, any key skips
        push    ax
        push    cx
        push    dx
        mov     ah, 0x01                ; INT 16h/01h: is a key waiting?
        int     0x16
        jz      .wait
        mov     byte [fast], 1          ; yes: print the rest instantly
        jmp     .out
.wait:  mov     ah, 0x86                ; INT 15h/86h: wait CX:DX microseconds
        xor     cx, cx
        mov     dx, 12000
        int     0x15
.out:   pop     dx
        pop     cx
        pop     ax
        ret

put_bcd:                                ; AL = two BCD digits
        push    ax
        mov     ah, al
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
        add     al, '0'
        call    putc
        mov     al, ah
        and     al, 0x0F
        add     al, '0'
        call    putc
        pop     ax
        ret

; -------------------------------------------------------------------
; input
; -------------------------------------------------------------------
LINE_MAX equ 48
line    times LINE_MAX+1 db 0

read_line:                              ; reads into [line], lower-cased
        xor     cx, cx
        mov     di, line
.key:   xor     ah, ah                  ; INT 16h/00h: wait for a key
        int     0x16
        cmp     al, 13
        je      .enter
        cmp     al, 8
        je      .back
        cmp     al, ' '
        jb      .key
        cmp     al, '~'
        ja      .key
        cmp     cx, LINE_MAX
        jae     .key
        cmp     al, 'A'
        jb      .store
        cmp     al, 'Z'
        ja      .store
        add     al, 'a' - 'A'
.store: mov     [di], al
        inc     di
        inc     cx
        mov     byte [attr], ATTR_HI
        call    putc
        mov     byte [attr], ATTR_TXT
        jmp     .key
.back:  jcxz    .key
        dec     di
        dec     cx
        call    putc                    ; AL = 8 erases the last cell
        jmp     .key
.enter: mov     byte [di], 0
        mov     al, 13
        call    putc
        mov     al, 10
        jmp     putc

strcmp:                                 ; SI vs DI, ZF set when equal
        push    si
        push    di
.loop:  mov     al, [si]
        cmp     al, [di]
        jne     .out
        test    al, al
        jz      .out
        inc     si
        inc     di
        jmp     .loop
.out:   pop     di
        pop     si
        ret

; -------------------------------------------------------------------
; text
; -------------------------------------------------------------------
%define C(a) COLOR, a

s_bar_left   db " 7OS 0.7 ", 0xB3, " Ali Almohaya ", 0xB3, " staff web engineer", 0
s_bar_right  db " github.com/Almo7aya ", 0

s_boot  db C(ATTR_DIM), "7OS 0.7 ", 0xFA, " real mode ", 0xFA, " stage 2 at 0000:7E00", 13, 10, 13, 10
        db C(ATTR_HI), "Ali Almohaya (Almo", C(ATTR_YELLOW), "7", C(ATTR_HI), "aya)", 13, 10
        db C(ATTR_TXT), "Staff web engineer @ Anghami & OSN+", 13, 10
        db "Video player, DRM and TV apps by day.", 13, 10
        db "Emulators and C++ after hours.", 13, 10
        db "Yemen ", 0x1A, " Riyadh", 13, 10
        db C(ATTR_CYAN), "github.com/Almo", C(ATTR_YELLOW), "7", C(ATTR_CYAN), "aya", 13, 10, 13, 10, 0
s_hint  db C(ATTR_DIM), "type ", C(ATTR_HI), "help", C(ATTR_DIM), " and press enter", 13, 10, 0
s_prompt db C(ATTR_YELLOW), "almo7aya", C(ATTR_DIM), "> ", 0
s_unknown1 db C(ATTR_RED), "unknown command: ", C(ATTR_TXT), 0
s_unknown2 db C(ATTR_DIM), " (try help)", 13, 10, 0

s_help  db C(ATTR_HI), "commands", 13, 10
        db C(ATTR_CYAN), "  about    ", C(ATTR_TXT), "who I am", 13, 10
        db C(ATTR_CYAN), "  work     ", C(ATTR_TXT), "the day job", 13, 10
        db C(ATTR_CYAN), "  hobbies  ", C(ATTR_TXT), "what I build after hours", 13, 10
        db C(ATTR_CYAN), "  github   ", C(ATTR_TXT), "where the code lives", 13, 10
        db C(ATTR_CYAN), "  time     ", C(ATTR_TXT), "read the real-time clock (INT 1Ah)", 13, 10
        db C(ATTR_CYAN), "  ver      ", C(ATTR_TXT), "about this OS", 13, 10
        db C(ATTR_CYAN), "  clear    ", C(ATTR_TXT), "clear the screen", 13, 10
        db C(ATTR_CYAN), "  7        ", C(ATTR_TXT), "you know", 13, 10
        db C(ATTR_CYAN), "  panic    ", C(ATTR_TXT), "don't", 13, 10
        db C(ATTR_CYAN), "  reboot   ", C(ATTR_TXT), "INT 19h, start over", 13, 10, 0

s_about db C(ATTR_HI), "Ali Almohaya", C(ATTR_DIM), " (Almo7aya)", 13, 10
        db C(ATTR_TXT), "Staff web engineer at Anghami and OSN+. I build apps for", 13, 10
        db "the web and for TVs, mostly the video player: playback and DRM.", 13, 10
        db "After hours I go lower: emulators, C++ and GPUs.", 13, 10
        db "From Yemen, living in Riyadh.", 13, 10, 0

s_work  db C(ATTR_HI), "INT 7Ch ", 0xC4, " work", 13, 10
        db C(ATTR_CYAN), "  00h ", C(ATTR_TXT), "web & TV apps   streaming apps for the web and for TVs", 13, 10
        db C(ATTR_CYAN), "  01h ", C(ATTR_TXT), "video playback  start fast, stay smooth", 13, 10
        db C(ATTR_CYAN), "  02h ", C(ATTR_TXT), "DRM             encrypted video, wherever people watch", 13, 10, 0

s_hobbies db C(ATTR_HI), "INT 7Dh ", 0xC4, " after hours", 13, 10
        db C(ATTR_CYAN), "  KytyPS5         ", C(ATTR_TXT), "PS5 emulator in C++, I contribute fixes", 13, 10
        db C(ATTR_CYAN), "  PS5 Shader Lab  ", C(ATTR_TXT), "C++20, shader compiler regression tool", 13, 10
        db C(ATTR_CYAN), "  Learning Kyty   ", C(ATTR_TXT), "a course on how a PS5 emulator works", 13, 10
        db C(ATTR_CYAN), "  GoWAN           ", C(ATTR_TXT), "Go, multi-WAN SOCKS5 for OpenWrt", 13, 10
        db C(ATTR_CYAN), "  openingh.nvim   ", C(ATTR_TXT), "Lua, open files on GitHub from Neovim", 13, 10
        db C(ATTR_CYAN), "  7OS             ", C(ATTR_TXT), "this. you are running it right now", 13, 10, 0

s_github db C(ATTR_CYAN), "github.com/Almo", C(ATTR_YELLOW), "7", C(ATTR_CYAN), "aya", 13, 10
        db C(ATTR_TXT), "  openingh.nvim, neogruvbox.nvim, GoWAN, PS5 Shader Lab", 13, 10
        db "  and patches in KytyPS5, Preact, LunarVim, ani-cli, Live Server", 13, 10, 0

s_ver   db "7OS 0.7 ", 0xFA, " 8086 real mode ", 0xFA, " two stages, assembled with NASM", 13, 10, 0
s_time  db C(ATTR_DIM), "RTC ", C(ATTR_HI), 0
s_notime db "no real-time clock", 13, 10, 0
s_reboot db C(ATTR_DIM), "INT 19h...", 13, 10, 0

s_seven db C(ATTR_YELLOW)
        db "  ", 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 13, 10
        db "        ", 0xDB, 0xDB, 13, 10
        db "       ", 0xDB, 0xDB, 13, 10
        db "      ", 0xDB, 0xDB, 13, 10
        db "     ", 0xDB, 0xDB, 13, 10, 0

s_panic db 13, 10, C(ATTR_RED), "Kernel panic - not syncing: user typed 'panic'", 13, 10
        db C(ATTR_DIM), "executing UD2. real hardware hangs here.", 13, 10, 0

stage2_end:

STAGE2_SECTORS equ (stage2_end - stage2 + 511) / 512

        ; pad the image to a whole number of sectors
        times (STAGE2_SECTORS * 512) - (stage2_end - stage2) db 0
