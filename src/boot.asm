; =============================================================================
; llmos - Stage 1 bootloader (512 bytes, loaded by BIOS at 0x7C00)
;
;   BIOS loads this sector to 0x7C00 in 16-bit real mode. We set up segments
;   and a stack, read the kernel from the next KERNEL_SECTORS sectors into
;   0x0000:0x1000, and jump to it.
;
;   Defensive: reset the disk before reading, retry up to 3 times on failure.
; =============================================================================

[BITS 16]
[ORG 0x7C00]

KERNEL_SEGMENT  equ 0x0000
KERNEL_OFFSET   equ 0x1000
KERNEL_SECTORS  equ 32              ; 16 KB of kernel space (does not collide
                                    ; with the bootloader image at 0x7C00)
SECTORS_PER_TRACK equ 18
HEADS_PER_CYL    equ 2

start:
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00
    sti
    cld

    mov     [boot_drive], dl

    mov     si, boot_msg
    call    print

    xor     ah, ah
    mov     dl, [boot_drive]
    int     0x13                    ; reset disk

    mov     ax, KERNEL_SEGMENT
    mov     es, ax
    mov     bx, KERNEL_OFFSET
    mov     byte [kernel_cyl], 0
    mov     byte [kernel_head], 0
    mov     byte [kernel_sector], 2
    mov     byte [kernel_left], KERNEL_SECTORS

.load_next:
    cmp     byte [kernel_left], 0
    je      .ok
    mov     cx, 3
.try:
    push    bx
    push    cx
    mov     ah, 0x02
    mov     al, 1
    mov     ch, [kernel_cyl]
    mov     cl, [kernel_sector]
    mov     dh, [kernel_head]
    mov     dl, [boot_drive]
    int     0x13
    pop     cx
    pop     bx
    jnc     .advance
    push    bx
    push    cx
    xor     ah, ah
    mov     dl, [boot_drive]
    int     0x13
    pop     cx
    pop     bx
    loop    .try
    jmp     disk_error

.advance:
    add     bx, 512
    dec     byte [kernel_left]
    inc     byte [kernel_sector]
    cmp     byte [kernel_sector], SECTORS_PER_TRACK + 1
    jb      .load_next
    mov     byte [kernel_sector], 1
    inc     byte [kernel_head]
    cmp     byte [kernel_head], HEADS_PER_CYL
    jb      .load_next
    mov     byte [kernel_head], 0
    inc     byte [kernel_cyl]
    jmp     .load_next
.ok:
    jmp     KERNEL_SEGMENT:KERNEL_OFFSET

disk_error:
    mov     si, err_msg
    call    print
.hang:
    hlt
    jmp     .hang

print:
    pusha
.loop:
    lodsb
    or      al, al
    jz      .done
    mov     ah, 0x0E
    mov     bh, 0
    int     0x10
    jmp     .loop
.done:
    popa
    ret

boot_drive:  db 0
kernel_cyl:  db 0
kernel_head: db 0
kernel_sector: db 0
kernel_left: db 0
boot_msg:    db 'llmos: loading kernel...', 13, 10, 0
err_msg:     db 'llmos: disk read failed', 13, 10, 0

times 510-($-$$) db 0
dw 0xAA55
