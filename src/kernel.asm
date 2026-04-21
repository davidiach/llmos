; =============================================================================
; llmos - kernel
;
;   An operating system whose primary user is a language model.
;
;   No keyboard. No human prompt. The kernel's entire interaction surface is
;   a line-oriented text protocol over COM1 at 115200 8N1. Every VGA write
;   is mirrored from the serial channel so a human can watch the model drive
;   the machine.
;
;   Wire protocol (docs/PROTOCOL.md has the full spec):
;     >  request:  CMD [key=value ...]\n
;     <  response: ok [key=value ...]\n     |  err code=X detail="..."\n
;     #  kernel:   unsolicited event or banner
;
;   Primitives in this build:
;     help                     list primitives
;     describe NAME            schema of one primitive
;     cpu.vendor               CPUID vendor + family/model/stepping
;     cpu.features             decoded CPUID leaf 1 EDX feature flags
;     mem.query                conventional + extended memory from BIOS
;     mem.read addr=H len=N    hex-encoded memory bytes (max 256)
;     rtc.now                  RTC date+time as ISO-ish
;     ticks.since_boot         BIOS ticks since boot, in ms
;     io.in port=H             8-bit port read (allowlisted)
; =============================================================================

[BITS 16]
[ORG 0x1000]

; ----- UART 16550 on COM1 ----------------------------------------------------
COM1_BASE   equ 0x3F8
COM1_THR    equ COM1_BASE + 0       ; transmit holding (DLAB=0)
COM1_RBR    equ COM1_BASE + 0       ; receive buffer   (DLAB=0)
COM1_DLL    equ COM1_BASE + 0       ; divisor low      (DLAB=1)
COM1_IER    equ COM1_BASE + 1       ; interrupt enable (DLAB=0)
COM1_DLH    equ COM1_BASE + 1       ; divisor high     (DLAB=1)
COM1_FCR    equ COM1_BASE + 2       ; FIFO control
COM1_LCR    equ COM1_BASE + 3       ; line control
COM1_MCR    equ COM1_BASE + 4       ; modem control
COM1_LSR    equ COM1_BASE + 5       ; line status

INPUT_MAX   equ 256

; =============================================================================
; Entry
; =============================================================================
start:
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0xFFF0
    cld

    ; VGA text mode 80x25.
    mov     ax, 0x0003
    int     0x10

    ; Snapshot boot time for ticks.since_boot.
    push    es
    mov     ax, 0x40
    mov     es, ax
    mov     eax, [es:0x6C]
    pop     es
    mov     [boot_ticks], eax

    call    serial_init

    ; Mirror the banner to VGA and announce over serial.
    mov     si, vga_banner
    call    vga_puts
    mov     si, ready_msg
    call    serial_puts

main_loop:
    mov     di, input_buf
    call    serial_read_line        ; reads a \n-terminated line

    ; Mirror request to VGA, prefixed with "> ".
    mov     al, '>'
    call    vga_putc
    mov     al, ' '
    call    vga_putc
    mov     si, input_buf
    call    vga_puts
    call    vga_newline

    ; Empty line -> just continue.
    cmp     byte [input_buf], 0
    je      main_loop

    ; Parse the line: NUL-terminate the command name, save a pointer to args.
    call    parse_cmd

    ; Dispatch.
    mov     bx, cmd_table
.next:
    mov     si, [bx]
    test    si, si
    jz      .unknown
    mov     di, input_buf
    call    strcmp_z
    jc      .match
    add     bx, 4
    jmp     .next
.match:
    call    word [bx+2]             ; handler writes its own response
    jmp     main_loop
.unknown:
    mov     si, err_unknown_cmd
    call    respond
    jmp     main_loop

; =============================================================================
; Command dispatch table. (cmd_str_ptr, handler) pairs, NULL-terminated.
; =============================================================================
cmd_table:
    dw  cmd_help,       h_help
    dw  cmd_describe,   h_describe
    dw  cmd_cpu_vendor, h_cpu_vendor
    dw  cmd_cpu_feat,   h_cpu_features
    dw  cmd_mem_query,  h_mem_query
    dw  cmd_mem_read,   h_mem_read
    dw  cmd_rtc_now,    h_rtc_now
    dw  cmd_ticks,      h_ticks
    dw  cmd_io_in,      h_io_in
    dw  0

; =============================================================================
; Handlers. Each writes exactly one response line (may be long).
; =============================================================================

; ---- help -----------------------------------------------------------------
h_help:
    mov     si, help_response
    call    respond
    ret

; ---- describe NAME --------------------------------------------------------
h_describe:
    mov     si, [arg_ptr]
    test    si, si
    jz      .nousage
    mov     bx, schema_table
.loop:
    mov     di, [bx]
    test    di, di
    jz      .notfound
    push    bx
    mov     si, [arg_ptr]
    call    strcmp_z
    pop     bx
    jc      .found
    add     bx, 4
    jmp     .loop
.found:
    mov     si, [bx+2]
    call    respond
    ret
.notfound:
    mov     si, err_describe_unknown
    call    respond
    ret
.nousage:
    mov     si, err_describe_usage
    call    respond
    ret

; ---- cpu.vendor -----------------------------------------------------------
h_cpu_vendor:
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_vendor_kw
    call    serial_puts_only
    ; CPUID leaf 0 -> vendor string in EBX, EDX, ECX (12 chars).
    xor     eax, eax
    cpuid
    mov     [cpu_vbuf+0], ebx
    mov     [cpu_vbuf+4], edx
    mov     [cpu_vbuf+8], ecx
    mov     byte [cpu_vbuf+12], 0
    mov     si, cpu_vbuf
    call    serial_puts_only
    ; family/model/stepping from leaf 1.
    mov     eax, 1
    cpuid
    mov     [cpu_sig], eax
    mov     si, resp_family_kw
    call    serial_puts_only
    mov     al, [cpu_sig+1]
    and     al, 0x0F
    call    serial_put_dec
    mov     si, resp_model_kw
    call    serial_puts_only
    mov     al, [cpu_sig]
    shr     al, 4
    xor     ah, ah
    call    serial_put_dec
    mov     si, resp_stepping_kw
    call    serial_puts_only
    mov     al, [cpu_sig]
    and     al, 0x0F
    xor     ah, ah
    call    serial_put_dec
    call    respond_end
    ret

; ---- cpu.features (a useful subset of CPUID leaf 1 EDX) -------------------
;   Walks feat_table: (name_ptr, bit_index). Emits comma-separated names
;   for each feature bit that is set.
h_cpu_features:
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_features_kw
    call    serial_puts_only
    mov     eax, 1
    cpuid
    mov     [cpu_sig], edx          ; EDX feature bits
    mov     bx, feat_table
    mov     byte [feat_first], 1
.loop:
    mov     si, [bx]
    test    si, si
    jz      .done
    mov     al, [bx+2]              ; bit index
    mov     cl, al
    mov     edx, 1
    shl     edx, cl
    test    [cpu_sig], edx
    jz      .skip
    cmp     byte [feat_first], 1
    jne     .comma
    mov     byte [feat_first], 0
    jmp     .emit
.comma:
    mov     al, ','
    call    serial_putc
.emit:
    call    serial_puts_only
.skip:
    add     bx, 3
    jmp     .loop
.done:
    call    respond_end
    ret

; ---- mem.query ------------------------------------------------------------
h_mem_query:
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_conv_kb
    call    serial_puts_only
    int     0x12                    ; AX = KB conventional
    call    serial_put_udec
    mov     si, resp_ext_kb
    call    serial_puts_only
    mov     ax, 0xE801
    int     0x15
    jc      .no_ext
    test    ax, ax
    jnz     .have
    mov     ax, cx
    mov     bx, dx
.have:
    push    bx
    call    serial_put_udec
    mov     si, resp_ext_blocks
    call    serial_puts_only
    pop     ax
    call    serial_put_udec
    call    respond_end
    ret
.no_ext:
    mov     al, '0'
    call    serial_putc
    mov     si, resp_ext_blocks
    call    serial_puts_only
    mov     al, '0'
    call    serial_putc
    call    respond_end
    ret

; ---- mem.read addr=H len=N ------------------------------------------------
;   addr: 1-4 hex digits, segment 0 offset
;   len:  1-3 decimal digits, capped at 256
h_mem_read:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_addr
    call    find_kv_hex
    jc      .usage
    mov     [mem_addr], ax
    mov     si, [arg_ptr]
    mov     di, key_len
    call    find_kv_dec
    jc      .usage
    cmp     ax, 256
    ja      .range
    test    ax, ax
    jz      .range
    mov     [mem_len], ax
    ; Response: ok addr=HHHH len=N data=HEXHEX...
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_addr_kw
    call    serial_puts_only
    mov     ax, [mem_addr]
    call    serial_put_hex_word
    mov     si, resp_len_kw
    call    serial_puts_only
    mov     ax, [mem_len]
    call    serial_put_udec
    mov     si, resp_data_kw
    call    serial_puts_only
    mov     cx, [mem_len]
    mov     bp, [mem_addr]
    xor     di, di
.dump:
    mov     al, [ds:bp+di]          ; force DS override (BP defaults to SS)
    call    serial_put_hex_byte
    inc     di
    loop    .dump
    call    respond_end
    ret
.usage:
    mov     si, err_mem_read_usage
    call    respond
    ret
.range:
    mov     si, err_mem_read_range
    call    respond
    ret

; ---- rtc.now --------------------------------------------------------------
h_rtc_now:
    mov     ah, 0x02
    int     0x1A
    jc      .err
    push    cx
    push    dx
    mov     ah, 0x04
    int     0x1A
    jc      .err_pop
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_iso_kw
    call    serial_puts_only
    mov     al, ch
    call    serial_put_bcd
    mov     al, cl
    call    serial_put_bcd
    mov     al, '-'
    call    serial_putc
    mov     al, dh
    call    serial_put_bcd
    mov     al, '-'
    call    serial_putc
    mov     al, dl
    call    serial_put_bcd
    mov     al, 'T'
    call    serial_putc
    pop     dx
    pop     cx
    mov     al, ch
    call    serial_put_bcd
    mov     al, ':'
    call    serial_putc
    mov     al, cl
    call    serial_put_bcd
    mov     al, ':'
    call    serial_putc
    mov     al, dh
    call    serial_put_bcd
    call    respond_end
    ret
.err_pop:
    pop     dx
    pop     cx
.err:
    mov     si, err_rtc
    call    respond
    ret

; ---- ticks.since_boot -----------------------------------------------------
h_ticks:
    push    es
    mov     ax, 0x40
    mov     es, ax
    mov     eax, [es:0x6C]
    pop     es
    sub     eax, [boot_ticks]
    ; ms ≈ ticks * 55 (close enough; real rate 54.9254 ms/tick)
    mov     ebx, 55
    mul     ebx                     ; EDX:EAX — but we'll assume it fits
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_ms_kw
    call    serial_puts_only
    call    serial_put_udec32
    call    respond_end
    ret

; ---- io.in port=H (allowlisted) -------------------------------------------
h_io_in:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_port
    call    find_kv_hex
    jc      .usage
    ; Check allowlist.
    mov     bx, io_allowlist
.chk:
    mov     cx, [bx]
    cmp     cx, 0xFFFF
    je      .denied
    cmp     ax, cx
    je      .allowed
    add     bx, 2
    jmp     .chk
.allowed:
    mov     dx, ax
    push    ax
    in      al, dx
    mov     ah, al                  ; stash result byte
    pop     cx                      ; CX = port
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_port_kw
    call    serial_puts_only
    mov     ax, cx
    call    serial_put_hex_word
    mov     si, resp_value_kw
    call    serial_puts_only
    mov     al, ah
    call    serial_put_hex_byte
    call    respond_end
    ret
.denied:
    mov     si, err_io_denied
    call    respond
    ret
.usage:
    mov     si, err_io_usage
    call    respond
    ret

; =============================================================================
; Protocol helpers
; =============================================================================

; respond: write a fixed string at DS:SI to both serial and VGA, then CRLF.
respond:
    call    serial_puts_only
    call    respond_end
    ret

; respond_end: terminate a partially-written response line. Mirrors the
; entire partial response back out to VGA by re-reading... no, that's
; expensive. Simpler: we mirror inline in every serial_put* helper.
; Actually simpler still: we only mirror the final completed line.
; For now: emit CRLF on serial AND VGA.
respond_end:
    mov     al, 13
    call    serial_putc
    mov     al, 10
    call    serial_putc
    call    vga_newline
    ret

; parse_cmd: in-place parse of input_buf. NUL-terminate the command name and
; set [arg_ptr] to the start of the argument string (or 0 if none).
parse_cmd:
    push    si
    mov     word [arg_ptr], 0
    mov     si, input_buf
.loop:
    mov     al, [si]
    test    al, al
    jz      .done
    cmp     al, ' '
    je      .split
    cmp     al, 13
    je      .strip
    cmp     al, 10
    je      .strip
    inc     si
    jmp     .loop
.strip:
    mov     byte [si], 0
    jmp     .done
.split:
    mov     byte [si], 0
    inc     si
.sp:
    cmp     byte [si], ' '
    jne     .setarg
    inc     si
    jmp     .sp
.setarg:
    cmp     byte [si], 0
    je      .done
    mov     [arg_ptr], si
.done:
    pop     si
    ret

; find_kv_hex: find "KEY=HEXHEX" in the arg string (DS:SI), where DI points
; to a NUL-terminated key. Returns AX = parsed hex value, CF=0 on success.
find_kv_hex:
    call    find_kv
    jc      .no
    call    parse_hex_word
    ret
.no:
    stc
    ret

; find_kv_dec: same as find_kv_hex but the value is decimal.
find_kv_dec:
    call    find_kv
    jc      .no
    call    parse_dec_word
    ret
.no:
    stc
    ret

; find_kv: given arg string at DS:SI and key at DI (NUL-term, no '='),
; locate "KEY=..." at a word boundary and leave SI pointing just past '='.
; CF=0 on success, CF=1 if not found.
find_kv:
    push    bx
    push    bp
    mov     bp, di                  ; BP = key pointer
.word:
    mov     al, [si]
    test    al, al
    jz      .no
    cmp     al, ' '
    je      .sp
    ; try matching BP against SI
    mov     bx, si
    mov     di, bp
.cmp:
    mov     al, [di]
    test    al, al
    jz      .ok
    cmp     al, [bx]
    jne     .skip
    inc     bx
    inc     di
    jmp     .cmp
.ok:
    cmp     byte [bx], '='
    jne     .skip
    mov     si, bx
    inc     si                      ; past '='
    pop     bp
    pop     bx
    clc
    ret
.skip:
    ; advance SI past this word (to next space or end)
    mov     al, [si]
    test    al, al
    jz      .no
    cmp     al, ' '
    je      .sp
    inc     si
    jmp     .skip
.sp:
    inc     si
    jmp     .word
.no:
    pop     bp
    pop     bx
    stc
    ret

; =============================================================================
; Serial I/O (polled)
; =============================================================================

serial_init:
    mov     dx, COM1_IER
    xor     al, al
    out     dx, al                  ; disable interrupts
    mov     dx, COM1_LCR
    mov     al, 0x80
    out     dx, al                  ; DLAB=1
    mov     dx, COM1_DLL
    mov     al, 1
    out     dx, al                  ; 115200 baud, low
    mov     dx, COM1_DLH
    xor     al, al
    out     dx, al                  ; high
    mov     dx, COM1_LCR
    mov     al, 0x03
    out     dx, al                  ; 8N1, DLAB=0
    mov     dx, COM1_FCR
    mov     al, 0xC7
    out     dx, al                  ; FIFOs on, cleared, 14-byte threshold
    mov     dx, COM1_MCR
    mov     al, 0x0B
    out     dx, al                  ; DTR, RTS, OUT2
    ret

; serial_putc: emit the byte in AL over COM1. Also mirrors to VGA.
serial_putc:
    push    dx
    push    ax
.wait:
    mov     dx, COM1_LSR
    in      al, dx
    test    al, 0x20                ; THR empty
    jz      .wait
    pop     ax
    push    ax
    mov     dx, COM1_THR
    out     dx, al
    pop     ax
    pop     dx
    ; Mirror to VGA (excluding CR; newlines are \n on VGA too).
    cmp     al, 13
    je      .skip_mirror
    call    vga_putc
.skip_mirror:
    ret

; serial_putc_raw: emit without mirroring to VGA.
serial_putc_raw:
    push    dx
    push    ax
.wait:
    mov     dx, COM1_LSR
    in      al, dx
    test    al, 0x20
    jz      .wait
    pop     ax
    push    ax
    mov     dx, COM1_THR
    out     dx, al
    pop     ax
    pop     dx
    ret

; serial_getc: read a byte from COM1 into AL (blocking).
serial_getc:
    push    dx
.wait:
    mov     dx, COM1_LSR
    in      al, dx
    test    al, 0x01
    jz      .wait
    mov     dx, COM1_RBR
    in      al, dx
    pop     dx
    ret

; serial_puts: write NUL-terminated DS:SI over serial (with VGA mirror).
serial_puts:
    pusha
.loop:
    lodsb
    test    al, al
    jz      .done
    call    serial_putc
    jmp     .loop
.done:
    popa
    ret

; serial_puts_only: same as serial_puts but does not mirror to VGA (used by
; handlers that emit key=value chunks, so that VGA mirrors the whole final
; line atomically via a helper — kept for symmetry, currently same as above).
serial_puts_only:
    pusha
.loop:
    lodsb
    test    al, al
    jz      .done
    call    serial_putc
    jmp     .loop
.done:
    popa
    ret

; serial_read_line: read one \n-terminated line into [DI], NUL-terminate.
;   Strips \r. Caps at INPUT_MAX-1. Echoes each char to VGA (not back to
;   serial) so the audience can see what the model typed.
serial_read_line:
    push    ax
    push    bp
    mov     bp, di
.next:
    call    serial_getc
    cmp     al, 13
    je      .next                   ; ignore CR
    cmp     al, 10
    je      .done
    cmp     al, 8                   ; BS (harmless — model shouldn't send)
    je      .back
    mov     bx, di
    sub     bx, bp
    cmp     bx, INPUT_MAX-1
    jae     .next
    stosb
    jmp     .next
.back:
    cmp     di, bp
    je      .next
    dec     di
    jmp     .next
.done:
    xor     al, al
    stosb
    pop     bp
    pop     ax
    ret

; serial_put_hex_byte: AL = byte, emit 2 lowercase hex digits.
serial_put_hex_byte:
    push    ax
    push    cx
    mov     cl, al
    shr     al, 4
    call    .nib
    mov     al, cl
    and     al, 0x0F
    call    .nib
    pop     cx
    pop     ax
    ret
.nib:
    cmp     al, 10
    jb      .d
    add     al, 'a'-10-'0'
.d:
    add     al, '0'
    call    serial_putc
    ret

; serial_put_hex_word: AX = word, emit 4 lowercase hex digits.
serial_put_hex_word:
    push    ax
    mov     al, ah
    call    serial_put_hex_byte
    pop     ax
    call    serial_put_hex_byte
    ret

; serial_put_bcd: AL = BCD byte, emit as two decimal digits.
serial_put_bcd:
    push    ax
    push    ax
    shr     al, 4
    add     al, '0'
    call    serial_putc
    pop     ax
    and     al, 0x0F
    add     al, '0'
    call    serial_putc
    pop     ax
    ret

; serial_put_udec: AX = unsigned word, emit as decimal.
serial_put_udec:
    pusha
    xor     cx, cx
    mov     bx, 10
    test    ax, ax
    jnz     .div
    mov     al, '0'
    call    serial_putc
    jmp     .end
.div:
    xor     dx, dx
    div     bx
    push    dx
    inc     cx
    test    ax, ax
    jnz     .div
.p:
    pop     dx
    mov     al, dl
    add     al, '0'
    call    serial_putc
    loop    .p
.end:
    popa
    ret

; serial_put_dec: AL = byte, emit as unsigned decimal. (Wrapper.)
serial_put_dec:
    xor     ah, ah
    call    serial_put_udec
    ret

; serial_put_udec32: EAX = unsigned 32-bit, emit as decimal.
serial_put_udec32:
    pushad
    xor     ecx, ecx
    mov     ebx, 10
    test    eax, eax
    jnz     .div
    mov     al, '0'
    call    serial_putc
    jmp     .end
.div:
    xor     edx, edx
    div     ebx
    push    edx
    inc     ecx
    test    eax, eax
    jnz     .div
.p:
    pop     edx
    mov     al, dl
    add     al, '0'
    call    serial_putc
    loop    .p
.end:
    popad
    ret

; =============================================================================
; VGA helpers (BIOS teletype, auto-scrolling)
; =============================================================================

vga_putc:
    pusha
    mov     ah, 0x0E
    mov     bh, 0
    int     0x10
    popa
    ret

vga_newline:
    push    ax
    mov     al, 13
    call    vga_putc
    mov     al, 10
    call    vga_putc
    pop     ax
    ret

vga_puts:
    pusha
.loop:
    lodsb
    test    al, al
    jz      .done
    call    vga_putc
    jmp     .loop
.done:
    popa
    ret

; =============================================================================
; String helpers
; =============================================================================

; strcmp_z: compare NUL-terminated strings at DS:SI and ES:DI.
;   CF=1 if equal, CF=0 otherwise. (Used for dispatch.)
strcmp_z:
    push    si
    push    di
    push    ax
.l:
    mov     al, [si]
    cmp     al, [di]
    jne     .no
    or      al, al
    jz      .yes
    inc     si
    inc     di
    jmp     .l
.yes:
    stc
    jmp     .end
.no:
    clc
.end:
    pop     ax
    pop     di
    pop     si
    ret

; parse_hex_word: DS:SI -> AX. SI advances. CF=0 on success, CF=1 if no digits.
parse_hex_word:
    push    bx
    push    cx
    xor     bx, bx
    xor     cx, cx
.l:
    mov     al, [si]
    cmp     al, '0'
    jb      .e
    cmp     al, '9'
    jbe     .d
    and     al, 0xDF                ; fold
    cmp     al, 'A'
    jb      .e
    cmp     al, 'F'
    ja      .e
    sub     al, 'A'-10
    jmp     .a
.d:
    sub     al, '0'
.a:
    shl     bx, 4
    or      bl, al
    inc     si
    inc     cx
    cmp     cx, 4
    jb      .l
.e:
    or      cx, cx
    jz      .none
    mov     ax, bx
    clc
    pop     cx
    pop     bx
    ret
.none:
    stc
    pop     cx
    pop     bx
    ret

; parse_dec_word: DS:SI -> AX. SI advances. CF=0 on success, CF=1 if no digits.
parse_dec_word:
    push    bx
    push    cx
    xor     bx, bx
    xor     cx, cx
.l:
    mov     al, [si]
    cmp     al, '0'
    jb      .e
    cmp     al, '9'
    ja      .e
    sub     al, '0'
    ; bx = bx*10 + al
    push    ax
    mov     ax, bx
    mov     bx, 10
    mul     bx
    mov     bx, ax
    pop     ax
    xor     ah, ah
    add     bx, ax
    inc     si
    inc     cx
    cmp     cx, 5
    jb      .l
.e:
    or      cx, cx
    jz      .none
    mov     ax, bx
    clc
    pop     cx
    pop     bx
    ret
.none:
    stc
    pop     cx
    pop     bx
    ret

; =============================================================================
; Data - command strings, response fragments, schema table
; =============================================================================

vga_banner:
    db '+---------------------------------+', 13, 10
    db '|  llmos v0.1  (proto=1)          |', 13, 10
    db '|  COM1 115200 8N1 - LLM driven   |', 13, 10
    db '+---------------------------------+', 13, 10, 13, 10, 0

ready_msg:      db '# llmos v0.1 proto=1 primitives=9', 13, 10, 0

; Command names (NUL-terminated)
cmd_help:       db 'help', 0
cmd_describe:   db 'describe', 0
cmd_cpu_vendor: db 'cpu.vendor', 0
cmd_cpu_feat:   db 'cpu.features', 0
cmd_mem_query:  db 'mem.query', 0
cmd_mem_read:   db 'mem.read', 0
cmd_rtc_now:    db 'rtc.now', 0
cmd_ticks:      db 'ticks.since_boot', 0
cmd_io_in:      db 'io.in', 0

; Argument key strings
key_addr:       db 'addr', 0
key_len:        db 'len', 0
key_port:       db 'port', 0

; Response line fragments (all include trailing space where appropriate)
resp_ok_prefix:     db 'ok', 0
resp_vendor_kw:     db ' vendor=', 0
resp_family_kw:     db ' family=', 0
resp_model_kw:      db ' model=', 0
resp_stepping_kw:   db ' stepping=', 0
resp_features_kw:   db ' features=', 0
resp_conv_kb:       db ' conv_kb=', 0
resp_ext_kb:        db ' ext_kb=', 0
resp_ext_blocks:    db ' ext_blocks_64k=', 0
resp_addr_kw:       db ' addr=', 0
resp_len_kw:        db ' len=', 0
resp_data_kw:       db ' data=', 0
resp_iso_kw:        db ' iso=', 0
resp_ms_kw:         db ' ms=', 0
resp_port_kw:       db ' port=', 0
resp_value_kw:      db ' value=', 0

; Error responses (full lines, including newline)
err_unknown_cmd:
    db 'err code=unknown_cmd detail="try `help`"', 0
err_describe_usage:
    db 'err code=bad_arg detail="usage: describe NAME"', 0
err_describe_unknown:
    db 'err code=unknown_cmd detail="no such primitive"', 0
err_mem_read_usage:
    db 'err code=bad_arg detail="usage: mem.read addr=HHHH len=N"', 0
err_mem_read_range:
    db 'err code=out_of_range detail="len must be 1..256"', 0
err_rtc:
    db 'err code=unavailable detail="RTC read failed"', 0
err_io_denied:
    db 'err code=denied detail="port not in allowlist"', 0
err_io_usage:
    db 'err code=bad_arg detail="usage: io.in port=HH"', 0

; Help response (full line).
help_response:
    db 'ok primitives=help,describe,cpu.vendor,cpu.features,mem.query,mem.read,rtc.now,ticks.since_boot,io.in', 0

; Schema table: (name_ptr, schema_line_ptr). NULL-terminated.
schema_table:
    dw  cmd_help,       sch_help
    dw  cmd_describe,   sch_describe
    dw  cmd_cpu_vendor, sch_cpu_vendor
    dw  cmd_cpu_feat,   sch_cpu_feat
    dw  cmd_mem_query,  sch_mem_query
    dw  cmd_mem_read,   sch_mem_read
    dw  cmd_rtc_now,    sch_rtc_now
    dw  cmd_ticks,      sch_ticks
    dw  cmd_io_in,      sch_io_in
    dw  0

sch_help:       db 'ok name=help args=none returns=primitives=CSV', 0
sch_describe:   db 'ok name=describe args=NAME returns=schema-line', 0
sch_cpu_vendor: db 'ok name=cpu.vendor args=none returns="vendor=S family=N model=N stepping=N"', 0
sch_cpu_feat:   db 'ok name=cpu.features args=none returns="features=CSV (from CPUID leaf 1 EDX)"', 0
sch_mem_query:  db 'ok name=mem.query args=none returns="conv_kb=N ext_kb=N ext_blocks_64k=N"', 0
sch_mem_read:   db 'ok name=mem.read args="addr=H(1-4) len=N(1-256)" returns="addr=H len=N data=HEX"', 0
sch_rtc_now:    db 'ok name=rtc.now args=none returns="iso=YYYY-MM-DDTHH:MM:SS"', 0
sch_ticks:      db 'ok name=ticks.since_boot args=none returns="ms=N"', 0
sch_io_in:      db 'ok name=io.in args="port=H" returns="port=H value=H" allowlist=0x20,0x21,0x40,0x43,0x60,0x61,0x64,0x70,0x71', 0

; io.in allowlist (terminator 0xFFFF)
io_allowlist:
    dw  0x0020, 0x0021              ; PIC master cmd/data
    dw  0x0040, 0x0043              ; PIT ch0, PIT control
    dw  0x0060, 0x0061, 0x0064      ; keyboard + system control
    dw  0x0070, 0x0071              ; CMOS index + data
    dw  0x03F8, 0x03F9, 0x03FA, 0x03FB
    dw  0x03FC, 0x03FD, 0x03FE, 0x03FF ; COM1 (so the LLM can introspect itself)
    dw  0xFFFF

; CPUID leaf 1 EDX feature table: each entry is 3 bytes — (name_ptr: word,
; bit_index: byte). Terminator is a word of zero.
feat_table:
    dw  feat_fpu
    db  0
    dw  feat_vme
    db  1
    dw  feat_de
    db  2
    dw  feat_pse
    db  3
    dw  feat_tsc
    db  4
    dw  feat_msr
    db  5
    dw  feat_pae
    db  6
    dw  feat_mce
    db  7
    dw  feat_cx8
    db  8
    dw  feat_apic
    db  9
    dw  feat_sep
    db  11
    dw  feat_mtrr
    db  12
    dw  feat_pge
    db  13
    dw  feat_cmov
    db  15
    dw  feat_pat
    db  16
    dw  feat_clflush
    db  19
    dw  feat_mmx
    db  23
    dw  feat_fxsr
    db  24
    dw  feat_sse
    db  25
    dw  feat_sse2
    db  26
    dw  feat_htt
    db  28
    dw  0
    db  0

feat_fpu:     db 'fpu', 0
feat_vme:     db 'vme', 0
feat_de:      db 'de', 0
feat_pse:     db 'pse', 0
feat_tsc:     db 'tsc', 0
feat_msr:     db 'msr', 0
feat_pae:     db 'pae', 0
feat_mce:     db 'mce', 0
feat_cx8:     db 'cx8', 0
feat_apic:    db 'apic', 0
feat_sep:     db 'sep', 0
feat_mtrr:    db 'mtrr', 0
feat_pge:     db 'pge', 0
feat_cmov:    db 'cmov', 0
feat_pat:     db 'pat', 0
feat_clflush: db 'clflush', 0
feat_mmx:     db 'mmx', 0
feat_fxsr:    db 'fxsr', 0
feat_sse:     db 'sse', 0
feat_sse2:    db 'sse2', 0
feat_htt:     db 'htt', 0

; =============================================================================
; BSS - uninitialised state
; =============================================================================
input_buf:      times INPUT_MAX db 0
arg_ptr:        dw 0
cpu_vbuf:       times 13 db 0
cpu_sig:        dd 0
boot_ticks:     dd 0
mem_addr:       dw 0
mem_len:        dw 0
feat_first:     db 0

