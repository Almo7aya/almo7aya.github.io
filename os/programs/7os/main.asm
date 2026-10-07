; almo7aya.asm · 7OS 0.8, a tiny real-mode operating system for almo7aya.dev
;
;   build:  npm run os            (nasm + os/build.mjs, which also packs the filesystem)
;   run:    qemu-system-i386 -drive format=raw,file=public/os/almo7aya.img
;
; disk layout (512-byte sectors, LBA):
;   0        stage 1, the boot sector
;   1..31    stage 2, the kernel + shell (loaded at 0000:7E00)
;   32       7FS directory: 32 entries of 16 bytes
;   33..     file data, each file starts on a sector boundary
;
; what it does:
;   - reads the disk geometry and loads files through INT 13h (LBA -> CHS by hand)
;   - draws a colour console straight into VGA text memory at B800:0000
;   - hooks INT 1Ch (called by the BIOS timer interrupt, 18.2 Hz) for a live clock
;   - "demo" switches to mode 13h, draws a plasma, writes with the BIOS font ROM
;     (INT 10h AX=1130h) and animates by rotating the DAC palette, synced to vblank

cpu 8086
bits 16
org 0x7C00

KERNEL_SECTORS  equ 31
DIR_LBA         equ 32
FILE_SEG        equ 0x2000                  ; files are loaded at 2000:0000

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

        mov     si, s_loading
        call    bputs
        mov     ax, 0x0200 + KERNEL_SECTORS     ; AH=02h read, AL=count
        mov     cx, 0x0002                      ; cylinder 0, sector 2
        xor     dh, dh
        mov     dl, [boot_drive]
        mov     bx, stage2
        int     0x13
        jc      .fail
        jmp     0x0000:stage2

.fail:  mov     si, s_diskerr
        call    bputs
.halt:  hlt
        jmp     .halt

bputs:  lodsb
        test    al, al
        jz      .done
        mov     ah, 0x0E
        xor     bx, bx
        int     0x10
        jmp     bputs
.done:  ret

boot_drive      db 0x80
s_loading       db "7OS: loading kernel...", 13, 10, 0
s_diskerr       db "disk read error", 0

        times 510-($-$$) db 0
        dw      0xAA55

; ===================================================================
; stage 2 · kernel, at 0000:7E00
; ===================================================================
COLOR           equ 0x01                    ; in strings: 0x01, attr
A_TXT           equ 0x07
A_HI            equ 0x0F
A_DIM           equ 0x08
A_CYAN          equ 0x0B
A_YELLOW        equ 0x0E
A_GREEN         equ 0x0A
A_RED           equ 0x0C
A_BAR           equ 0x1F
A_BAR_HI        equ 0x1E
A_BAR_CYAN      equ 0x1B
%define C(a) COLOR, a

stage2:
        call    disk_init
        call    hook_timer
        call    screen_init
        mov     si, s_boot
        call    type_out
        call    fs_count
        call    print_dec
        mov     si, s_boot2
        call    puts

shell:  mov     si, s_prompt
        call    puts
        call    read_line
        call    run_command
        jmp     shell

; -------------------------------------------------------------------
; disk: geometry from INT 13h/08h, LBA -> CHS, one sector at a time
; -------------------------------------------------------------------
spt     dw 63
heads   dw 16

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

; AX = LBA, CX = count, ES:BX = buffer. CF set on error
read_sectors:
        push    ax
        push    bx
        push    cx
        push    dx
.next:  push    ax
        push    cx
        xor     dx, dx
        div     word [spt]              ; AX = LBA / spt, DX = LBA % spt
        mov     cl, dl
        inc     cl                      ; sectors count from 1
        xor     dx, dx
        div     word [heads]            ; AX = cylinder, DX = head
        mov     ch, al
        ror     ah, 1
        ror     ah, 1
        and     ah, 0xC0
        or      cl, ah                  ; cylinder bits 8-9 live in CL bits 6-7
        mov     dh, dl
        mov     dl, [boot_drive]
        mov     ax, 0x0201
        int     0x13
        pop     cx
        pop     ax
        jc      .out
        add     bx, 512
        inc     ax
        loop    .next
        clc
.out:   pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; -------------------------------------------------------------------
; 7FS: a flat directory of 16-byte entries
;   +0  name, 8.3 without the dot, space padded (11 bytes)
;   +11 attribute (the colour dir uses)
;   +12 start LBA (word)
;   +14 size in bytes (word)
; -------------------------------------------------------------------
dirbuf  times 512 db 0
dir_ok  db 0

fs_load_dir:
        cmp     byte [dir_ok], 1
        je      .ok
        mov     ax, DIR_LBA
        mov     cx, 1
        mov     bx, dirbuf
        call    read_sectors
        jc      .bad
        mov     byte [dir_ok], 1
.ok:    clc
.bad:   ret

fs_count:                               ; AX = number of files
        call    fs_load_dir
        xor     ax, ax
        mov     si, dirbuf
.loop:  cmp     byte [si], 0
        je      .done
        inc     ax
        add     si, 16
        cmp     si, dirbuf + 512
        jb      .loop
.done:  ret

; DS:SI = 11-byte name. returns SI = entry, CF set if not found
fs_find:
        push    di
        push    cx
        mov     di, dirbuf
.loop:  cmp     byte [di], 0
        je      .miss
        push    si
        push    di
        mov     cx, 11
        repe    cmpsb
        pop     di
        pop     si
        je      .hit
        add     di, 16
        cmp     di, dirbuf + 512
        jb      .loop
.miss:  pop     cx
        pop     di
        stc
        ret
.hit:   mov     si, di
        pop     cx
        pop     di
        clc
        ret

; SI = entry: loads the file to FILE_SEG:0000 and prints it, LF -> CR LF
fsize   dw 0
fs_type:
        push    es
        mov     ax, FILE_SEG
        mov     es, ax
        mov     cx, [si+14]
        mov     [fsize], cx
        add     cx, 511
        mov     cl, ch
        shr     cl, 1                   ; sectors = (size + 511) / 512
        xor     ch, ch
        mov     ax, [si+12]
        xor     bx, bx
        call    read_sectors
        jc      .err
        xor     di, di
        mov     cx, [fsize]
        jcxz    .done
.ch:    mov     al, [es:di]
        inc     di
        cmp     al, 13
        je      .skip
        cmp     al, 10
        jne     .put
        mov     al, 13
        call    putc
        mov     al, 10
.put:   call    putc
.skip:  loop    .ch
.done:  pop     es
        ret
.err:   pop     es
        mov     si, s_ioerr
        jmp     puts

; SI = "about.txt" -> fname = "ABOUT   TXT"
fname   times 11 db ' '
make_83:
        push    di
        mov     di, fname
        mov     cx, 11
        mov     al, ' '
        rep     stosb
        mov     di, fname
        mov     cx, 8
.base:  lodsb
        test    al, al
        jz      .end
        cmp     al, '.'
        je      .ext
        jcxz    .base                   ; names longer than 8: drop the rest
        call    upper
        mov     [di], al
        inc     di
        dec     cx
        jmp     .base
.ext:   mov     di, fname + 8
        mov     cx, 3
.e:     lodsb
        test    al, al
        jz      .end
        call    upper
        mov     [di], al
        inc     di
        loop    .e
.end:   pop     di
        ret

upper:  cmp     al, 'a'
        jb      .r
        cmp     al, 'z'
        ja      .r
        sub     al, 'a' - 'A'
.r:     ret

; -------------------------------------------------------------------
; timer: hook INT 1Ch, which the BIOS calls from IRQ0 18.2 times a second
; -------------------------------------------------------------------
old_1c  dd 0
ticks   dw 0
divider db 1

hook_timer:
        cli
        mov     ax, [0x1C*4]
        mov     [old_1c], ax
        mov     ax, [0x1C*4+2]
        mov     [old_1c+2], ax
        mov     word [0x1C*4], clock_isr
        mov     word [0x1C*4+2], 0
        sti
        ret

clock_isr:
        push    ax
        push    bx
        push    cx
        push    dx
        push    di
        push    ds
        push    es
        xor     ax, ax
        mov     ds, ax                  ; our variables live in segment 0
        inc     word [ticks]
        dec     byte [divider]
        jnz     .chain
        mov     byte [divider], 18      ; about once a second
        cmp     byte [0x449], 3         ; only in text mode
        jne     .chain
        mov     ah, 0x02                ; RTC time, BCD
        int     0x1A
        jc      .chain
        mov     ax, 0xB800
        mov     es, ax
        mov     di, 71 * 2
        mov     bh, A_BAR_HI
        mov     al, ch
        call    .bcd
        mov     al, ':'
        call    .chr
        mov     al, cl
        call    .bcd
        mov     al, ':'
        call    .chr
        mov     al, dh
        call    .bcd
.chain: pushf                           ; chain to whoever had INT 1Ch before us
        call    far [old_1c]
        pop     es
        pop     ds
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret
.bcd:   push    ax
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
        add     al, '0'
        call    .chr
        pop     ax
        and     al, 0x0F
        add     al, '0'
.chr:   mov     ah, bh
        stosw
        ret

; -------------------------------------------------------------------
; screen
; -------------------------------------------------------------------
row     db 0
col     db 0
attr    db A_TXT
fast    db 0

screen_init:
        mov     ax, 0x0003              ; 80x25 text, clears the screen
        int     0x10
        call    draw_header
        mov     byte [row], 2
        mov     byte [col], 0
        jmp     sync_cursor

draw_header:
        push    es
        mov     ax, 0xB800
        mov     es, ax
        xor     di, di
        mov     ax, (A_BAR << 8) | ' '
        mov     cx, 80
        rep     stosw
        xor     di, di
        mov     si, s_bar_left
        mov     ah, A_BAR
        call    .text
        mov     di, 50 * 2
        mov     si, s_bar_gh
        mov     ah, A_BAR_CYAN
        call    .text
        pop     es
        mov     byte [divider], 1       ; draw the clock on the next tick
        ret
.text:  lodsb
        test    al, al
        jz      .ret
        stosw
        jmp     .text
.ret:   ret

putc:                                   ; AL = character, colour from [attr]
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
        mov     word [es:di], (A_TXT << 8) | ' '
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

scroll: push    ax
        push    bx
        push    cx
        push    dx
        mov     ax, 0x0601              ; scroll rows 1-24 up, keep the title bar
        mov     bh, A_TXT
        mov     cx, 0x0100
        mov     dx, 0x184F
        int     0x10
        mov     byte [row], 24
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

sync_cursor:
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

puts:   mov     byte [fast], 1
        jmp     emit
type_out:
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
.done:  mov     byte [attr], A_TXT
        ret

delay:  push    ax                      ; ~12 ms per character, any key skips
        push    cx
        push    dx
        mov     ah, 0x01
        int     0x16
        jz      .wait
        mov     byte [fast], 1
        jmp     .out
.wait:  mov     ah, 0x86
        xor     cx, cx
        mov     dx, 12000
        int     0x15
.out:   pop     dx
        pop     cx
        pop     ax
        ret

print_dec:                              ; AX, unsigned
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.div:   xor     dx, dx
        div     bx
        push    dx
        inc     cx
        test    ax, ax
        jnz     .div
.out:   pop     ax
        add     al, '0'
        call    putc
        loop    .out
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

pad_dec:                                ; AX, right-aligned in 7 columns
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.d:     xor     dx, dx
        div     bx
        inc     cx
        test    ax, ax
        jnz     .d
        mov     bx, 7
        sub     bx, cx
        mov     cx, bx
.sp:    mov     al, ' '
        call    putc
        loop    .sp
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        jmp     print_dec

print_hex16:                            ; AX
        push    ax
        mov     al, ah
        call    print_hex8
        pop     ax
print_hex8:                             ; AL
        push    ax
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
        call    .nib
        pop     ax
.nib:   push    ax
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     .p
        add     al, 7
.p:     call    putc
        pop     ax
        ret

put_bcd:
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

crlf:   push    ax
        mov     al, 13
        call    putc
        mov     al, 10
        call    putc
        pop     ax
        ret

put_n:  lodsb                           ; CX characters from DS:SI
        call    putc
        loop    put_n
        ret

; -------------------------------------------------------------------
; input
; -------------------------------------------------------------------
LINE_MAX equ 60
line    times LINE_MAX+1 db 0
argp    dw 0                            ; first argument, or 0

read_line:
        xor     cx, cx
        mov     di, line
.key:   xor     ah, ah
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
        mov     byte [attr], A_HI
        call    putc
        mov     byte [attr], A_TXT
        jmp     .key
.back:  jcxz    .key
        dec     di
        dec     cx
        call    putc
        jmp     .key
.enter: mov     byte [di], 0
        jmp     crlf

split_args:                             ; "cmd arg" -> line = "cmd", [argp] = "arg"
        mov     word [argp], 0
        mov     si, line
.sp:    lodsb
        test    al, al
        jz      .r
        cmp     al, ' '
        jne     .sp
        mov     byte [si-1], 0
.skip:  cmp     byte [si], ' '
        jne     .set
        inc     si
        jmp     .skip
.set:   cmp     byte [si], 0
        je      .r
        mov     [argp], si
.r:     ret

strcmp: push    si
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
; commands
; -------------------------------------------------------------------
run_command:
        call    split_args
        cmp     byte [line], 0
        je      .done
        mov     bx, commands
.next:  mov     di, [bx]
        test    di, di
        jz      .file
        mov     si, line
        call    strcmp
        je      .found
        add     bx, 4
        jmp     .next
.found: call    [bx+2]
        ret
.file:  mov     si, line                ; not a command: maybe a file, "about" = ABOUT.TXT
        call    make_83
        cmp     byte [fname + 8], ' '
        jne     .try
        mov     word [fname + 8], 'TX'
        mov     byte [fname + 10], 'T'
.try:   call    fs_load_dir
        mov     si, fname
        call    fs_find
        jc      .nope
        jmp     fs_type
.nope:  mov     si, s_unknown1
        call    puts
        mov     si, line
        call    puts
        mov     si, s_unknown2
        call    puts
.done:  ret

commands:
        dw c_help,   cmd_help
        dw c_dir,    cmd_dir
        dw c_ls,     cmd_dir
        dw c_type,   cmd_type
        dw c_cat,    cmd_type
        dw c_regs,   cmd_regs
        dw c_ints,   cmd_ints
        dw c_uptime, cmd_uptime
        dw c_time,   cmd_time
        dw c_demo,   cmd_demo
        dw c_ver,    cmd_ver
        dw c_clear,  cmd_clear
        dw c_cls,    cmd_clear
        dw c_seven,  cmd_seven
        dw c_panic,  cmd_panic
        dw c_reboot, cmd_reboot
        dw 0

c_help   db "help", 0
c_dir    db "dir", 0
c_ls     db "ls", 0
c_type   db "type", 0
c_cat    db "cat", 0
c_regs   db "regs", 0
c_ints   db "ints", 0
c_uptime db "uptime", 0
c_time   db "time", 0
c_demo   db "demo", 0
c_ver    db "ver", 0
c_clear  db "clear", 0
c_cls    db "cls", 0
c_seven  db "7", 0
c_panic  db "panic", 0
c_reboot db "reboot", 0

cmd_help:
        mov     si, s_help
        jmp     puts
cmd_ver:
        mov     si, s_ver
        jmp     puts
cmd_seven:
        mov     si, s_seven
        jmp     puts

cmd_dir:
        call    fs_load_dir
        jc      .err
        mov     si, s_dirhead
        call    puts
        mov     bx, dirbuf
        xor     dx, dx                  ; total bytes
.ent:   cmp     byte [bx], 0
        je      .end
        mov     al, [bx+11]
        mov     [attr], al
        mov     si, bx
        mov     cx, 8
        call    put_n
        mov     al, ' '
        call    putc
        mov     cx, 3
        call    put_n
        mov     byte [attr], A_TXT
        mov     ax, [bx+14]
        add     dx, ax
        call    pad_dec
        mov     si, s_lba
        call    puts
        mov     ax, [bx+12]
        call    print_dec
        call    crlf
        add     bx, 16
        cmp     bx, dirbuf + 512
        jb      .ent
.end:   mov     si, s_dirfoot
        call    puts
        call    fs_count
        call    print_dec
        mov     si, s_files
        call    puts
        mov     ax, dx
        call    print_dec
        mov     si, s_bytes
        jmp     puts
.err:   mov     si, s_ioerr
        jmp     puts

cmd_type:
        mov     si, [argp]
        test    si, si
        jz      .usage
        call    make_83
        call    fs_load_dir
        mov     si, fname
        call    fs_find
        jc      .nf
        jmp     fs_type
.usage: mov     si, s_typeuse
        jmp     puts
.nf:    mov     si, s_notfound
        jmp     puts

cmd_regs:                               ; the registers as the shell sees them
        pushf
        push    ss
        push    es
        push    ds
        push    cs
        push    sp
        push    bp
        push    di
        push    si
        push    dx
        push    cx
        push    bx
        push    ax
        mov     si, s_regnames
        mov     cx, 13
.r:     mov     byte [attr], A_CYAN
        lodsb
        call    putc
        lodsb
        call    putc
        mov     byte [attr], A_DIM
        mov     al, '='
        call    putc
        mov     byte [attr], A_HI
        pop     ax
        call    print_hex16
        mov     byte [attr], A_TXT
        mov     al, ' '
        call    putc
        cmp     cx, 6                   ; break the line after SP
        jne     .n
        call    crlf
.n:     loop    .r
        jmp     crlf

cmd_ints:
        mov     di, int_list
.i:     mov     al, [di]
        inc     di
        cmp     al, 0xFF
        je      .done
        mov     [cur_int], al
        mov     si, s_int
        call    puts
        mov     byte [attr], A_CYAN
        mov     al, [cur_int]
        call    print_hex8
        mov     si, s_arrow
        call    puts
        xor     bh, bh
        mov     bl, [cur_int]
        shl     bx, 1
        shl     bx, 1
        mov     byte [attr], A_HI
        mov     ax, [bx+2]
        call    print_hex16
        mov     al, ':'
        call    putc
        mov     ax, [bx]
        call    print_hex16
        cmp     word [bx+2], 0
        jne     .rom
        mov     si, s_hooked
        call    puts
        jmp     .nl
.rom:   mov     si, s_rom
        call    puts
.nl:    call    crlf
        jmp     .i
.done:  ret
cur_int  db 0
int_list db 0x08, 0x10, 0x13, 0x16, 0x1A, 0x1C, 0xFF

cmd_uptime:
        mov     si, s_up
        call    puts
        mov     ax, [ticks]
        xor     dx, dx
        mov     bx, 18
        div     bx
        call    print_dec
        mov     si, s_up2
        call    puts
        mov     ax, [ticks]
        call    print_dec
        mov     si, s_up3
        jmp     puts

cmd_time:
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
        jmp     crlf
.none:  mov     si, s_notime
        jmp     puts

cmd_clear:
        mov     ax, 0x0600
        mov     bh, A_TXT
        mov     cx, 0x0100
        mov     dx, 0x184F
        int     0x10
        mov     byte [row], 1
        mov     byte [col], 0
        jmp     sync_cursor

cmd_panic:
        mov     si, s_panic
        call    puts
        db      0x0F, 0x0B              ; ud2: invalid opcode, on purpose
        cli
.hang:  hlt
        jmp     .hang

cmd_reboot:
        mov     si, s_reboot
        call    puts
        int     0x19

; -------------------------------------------------------------------
; demo: mode 13h plasma + palette rotation
; -------------------------------------------------------------------
font_off dw 0
font_seg dw 0
shift    db 0
scale    db 1

cmd_demo:
        push    es
        push    bp
        mov     ax, 0x1130              ; INT 10h/1130h: where is the 8x16 font? ES:BP
        mov     bh, 0x06
        int     0x10
        mov     [font_off], bp
        mov     [font_seg], es
        pop     bp
        pop     es

        mov     ax, 0x0013              ; 320x200, 256 colours, A000:0000
        int     0x10
        push    es
        mov     ax, 0xA000
        mov     es, ax

        ; plasma: c = sin[x] + sin[2y] + sin[x+y] + sin[(x-y)/2], each 0..63
        xor     di, di
        xor     dx, dx                  ; y
.row:   xor     cx, cx                  ; x
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
        stosb                           ; 0..252, colour 255 stays for text
        inc     cx
        cmp     cx, 320
        jb      .px
        inc     dx
        cmp     dx, 200
        jb      .row

        mov     si, s_demo_big          ; written with the BIOS font ROM at 4x
        mov     bx, 32
        mov     dx, 50
        mov     byte [scale], 4
        call    draw_text
        mov     byte [scale], 1
        mov     si, s_demo_small
        mov     bx, 64
        mov     dx, 140
        call    draw_text
        mov     si, s_demo_key
        mov     bx, 108
        mov     dx, 172
        call    draw_text

        mov     dx, 0x3C8               ; DAC colour 255 = white
        mov     al, 255
        out     dx, al
        inc     dx
        mov     al, 63
        out     dx, al
        out     dx, al
        out     dx, al
.frame: call    vsync
        call    set_palette
        inc     byte [shift]
        mov     ah, 0x01                ; any key ends it
        int     0x16
        jz      .frame
        xor     ah, ah
        int     0x16
        pop     es
        call    screen_init
        mov     si, s_demo_bye
        jmp     puts

vsync:  mov     dx, 0x3DA               ; wait for the start of vertical retrace
.a:     in      al, dx
        test    al, 8
        jnz     .a
.b:     in      al, dx
        test    al, 8
        jz      .b
        ret

set_palette:                            ; DAC colours 0..254 from the sine, rotated
        mov     dx, 0x3C8
        xor     al, al
        out     dx, al
        inc     dx
        xor     cx, cx
        xor     bh, bh
.c:     mov     bl, cl
        add     bl, [shift]
        mov     al, [sine + bx]
        out     dx, al                  ; red
        add     bl, 85
        mov     al, [sine + bx]
        shr     al, 1
        out     dx, al                  ; green
        add     bl, 85
        mov     al, [sine + bx]
        out     dx, al                  ; blue
        inc     cx
        cmp     cx, 255
        jb      .c
        ret

; SI = text, BX = x, DX = y, colour 255, ES = A000
draw_text:
.ch:    lodsb
        test    al, al
        jz      .done
        push    si
        push    ds
        push    dx
        xor     ah, ah
        mov     cl, 4
        shl     ax, cl                  ; char * 16
        mov     si, [font_off]
        add     si, ax
        mov     ds, [font_seg]
        mov     cx, 16
.glyph: mov     ah, [si]
        inc     si
        push    cx
        push    bx
        mov     cx, 8
.bit:   shl     ah, 1
        jnc     .skip
        call    block
.skip:  add     bl, [cs:scale]
        adc     bh, 0
        loop    .bit
        pop     bx
        pop     cx
        add     dl, [cs:scale]
        adc     dh, 0
        loop    .glyph
        pop     dx
        pop     ds
        pop     si
        mov     al, [scale]
        xor     ah, ah
        mov     cl, 3
        shl     ax, cl                  ; x += 8 * scale
        add     bx, ax
        jmp     .ch
.done:  ret

block:                                  ; scale x scale pixels of colour 255 at (BX, DX)
        push    ax
        push    cx
        push    dx
        push    di
        mov     ax, 320
        mul     dx
        add     ax, bx
        mov     di, ax
        mov     cl, [cs:scale]
        xor     ch, ch
.y:     push    cx
        push    di
        mov     cl, [cs:scale]
        mov     al, 255
        rep     stosb
        pop     di
        pop     cx
        add     di, 320
        loop    .y
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret

sine:                                   ; 256 bytes, 0..63, written by build.mjs
%include "sine.inc"

; -------------------------------------------------------------------
; text
; -------------------------------------------------------------------
s_bar_left   db " 7OS 0.8 ", 0xB3, " Ali Almohaya ", 0xB3, " staff web engineer", 0
s_bar_gh     db "github.com/Almo7aya", 0

s_boot  db C(A_DIM), "7OS 0.8 ", 0xFA, " 8086 real mode ", 0xFA, " kernel at 0000:7E00 ", 0xFA, " INT 1Ch hooked", 13, 10, 13, 10
        db C(A_HI), "Ali Almohaya (Almo", C(A_YELLOW), "7", C(A_HI), "aya)", 13, 10
        db C(A_TXT), "Staff web engineer @ Anghami & OSN+", 13, 10
        db "Video player, DRM and TV apps by day.", 13, 10
        db "Emulators and C++ after hours.", 13, 10
        db "Yemen ", 0x1A, " Riyadh", 13, 10
        db C(A_CYAN), "github.com/Almo", C(A_YELLOW), "7", C(A_CYAN), "aya", 13, 10, 13, 10
        db C(A_DIM), "7FS mounted from LBA 32: ", C(A_HI), 0
s_boot2 db C(A_DIM), " files. try ", C(A_HI), "help", C(A_DIM), ", ", C(A_HI), "dir", C(A_DIM), " or ", C(A_HI), "demo", 13, 10, 0
s_prompt db C(A_YELLOW), "almo7aya", C(A_DIM), "> ", 0
s_unknown1 db C(A_RED), "unknown command: ", C(A_TXT), 0
s_unknown2 db C(A_DIM), " (try help)", 13, 10, 0
s_ioerr db C(A_RED), "disk read error", 13, 10, 0
s_notfound db C(A_RED), "file not found", C(A_DIM), " (try dir)", 13, 10, 0
s_typeuse db C(A_DIM), "usage: type FILE.TXT", 13, 10, 0

s_help  db C(A_HI), "commands", 13, 10
        db C(A_CYAN), "  dir          ", C(A_TXT), "list the files on the 7FS disk", 13, 10
        db C(A_CYAN), "  type FILE    ", C(A_TXT), "print a file, or just type its name: about, work...", 13, 10
        db C(A_CYAN), "  demo         ", C(A_TXT), "mode 13h plasma, palette rotation, font ROM", 13, 10
        db C(A_CYAN), "  regs         ", C(A_TXT), "dump the CPU registers", 13, 10
        db C(A_CYAN), "  ints         ", C(A_TXT), "show the interrupt vector table", 13, 10
        db C(A_CYAN), "  uptime       ", C(A_TXT), "timer ticks since boot (INT 1Ch)", 13, 10
        db C(A_CYAN), "  time         ", C(A_TXT), "read the real-time clock (INT 1Ah)", 13, 10
        db C(A_CYAN), "  ver  clear  7  panic  reboot", 13, 10, 0

s_dirhead db C(A_DIM), " Volume in drive C is 7OS", 13, 10, " Directory of C:\", 13, 10, 13, 10, 0
s_dirfoot db C(A_DIM), "      ", 0
s_lba   db C(A_DIM), "  LBA ", 0
s_files db C(A_DIM), " file(s)  ", 0
s_bytes db C(A_DIM), " bytes", 13, 10, 0
s_regnames db "AXBXCXDXSIDIBPSPCSDSESSSFL"
s_int   db C(A_DIM), "  INT ", 0
s_arrow db C(A_DIM), "h -> ", 0
s_hooked db C(A_YELLOW), "  hooked by 7OS", 0
s_rom   db C(A_DIM), "  BIOS ROM", 0
s_up    db C(A_DIM), "up ", C(A_HI), 0
s_up2   db C(A_DIM), " s (", C(A_HI), 0
s_up3   db C(A_DIM), " ticks of IRQ0 at 18.2 Hz)", 13, 10, 0
s_ver   db "7OS 0.8 ", 0xFA, " 8086 real mode ", 0xFA, " NASM ", 0xFA, " 7FS ", 0xFA, " github.com/Almo7aya", 13, 10, 0
s_time  db C(A_DIM), "RTC ", C(A_HI), 0
s_notime db "no real-time clock", 13, 10, 0
s_reboot db C(A_DIM), "INT 19h...", 13, 10, 0
s_demo_big   db "ALMO7AYA", 0
s_demo_small db "7OS ", 0xFA, " MODE 13H ", 0xFA, " 8086", 0
s_demo_key   db "PRESS ANY KEY", 0
s_demo_bye   db C(A_DIM), "back in text mode 03h", 13, 10, 0

s_seven db C(A_YELLOW)
        db "  ", 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 13, 10
        db "        ", 0xDB, 0xDB, 13, 10
        db "       ", 0xDB, 0xDB, 13, 10
        db "      ", 0xDB, 0xDB, 13, 10
        db "     ", 0xDB, 0xDB, 13, 10, 0

s_panic db 13, 10, C(A_RED), "Kernel panic - not syncing: user typed 'panic'", 13, 10
        db C(A_DIM), "executing UD2. real hardware hangs here.", 13, 10, 0

kernel_end:
        times (KERNEL_SECTORS * 512) - (kernel_end - stage2) db 0   ; fails to build if the kernel outgrows its sectors
