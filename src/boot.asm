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

    mov     cx, 3
.try:
    push    cx
    mov     ax, KERNEL_SEGMENT
    mov     es, ax
    mov     bx, KERNEL_OFFSET
    mov     ah, 0x02
    mov     al, KERNEL_SECTORS
    mov     ch, 0
    mov     cl, 2
    mov     dh, 0
    mov     dl, [boot_drive]
    int     0x13
    pop     cx
    jnc     .ok
    xor     ah, ah
    mov     dl, [boot_drive]
    int     0x13
    loop    .try
    jmp     disk_error
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
boot_msg:    db 'llmos: loading kernel...', 13, 10, 0
err_msg:     db 'llmos: disk read failed', 13, 10, 0

times 510-($-$$) db 0
dw 0xAA55
