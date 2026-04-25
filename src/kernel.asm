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
;     mem.read{8,16,32} ...    read a typed value from low memory
;     mem.read.seg ...         read bytes from a real-mode segment:offset
;     mem.read.seg{8,16,32} ... read a typed value from segment:offset
;     rtc.now                  RTC date+time as ISO-ish
;     ticks.since_boot         BIOS ticks since boot, in ms
;     io.in port=H             8-bit port read (allowlisted)
;     pci.scan                 enumerate PCI bus 0 via config ports
;     pci.config.read ...      read bytes from a function's config space
;     pci.config.read{8,16,32} ... read a typed config-space value
;     pci.cap.list ...         enumerate a function's PCI capabilities
;     pci.cap.read ...         read bytes from a listed PCI capability
;     pci.bars bdf=BB.DD.F     decode a function's BARs (I/O, mmio32, mmio64)
;     pci.bar.read ...         read bytes from an I/O-space BAR
;     pci.mem.read ...         read bytes from a memory-space BAR
;     pci.mem.read{8,16,32} ... read a typed value from a memory BAR
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
FLAT_CODE_SEL equ 0x08
FLAT_DATA_SEL equ 0x10

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
    dw  cmd_mem_read8,  h_mem_read8
    dw  cmd_mem_read16, h_mem_read16
    dw  cmd_mem_read32, h_mem_read32
    dw  cmd_mem_read_seg, h_mem_read_seg
    dw  cmd_mem_read_seg8, h_mem_read_seg8
    dw  cmd_mem_read_seg16, h_mem_read_seg16
    dw  cmd_mem_read_seg32, h_mem_read_seg32
    dw  cmd_rtc_now,    h_rtc_now
    dw  cmd_ticks,      h_ticks
    dw  cmd_io_in,      h_io_in
    dw  cmd_pci_scan,   h_pci_scan
    dw  cmd_pci_config_read, h_pci_config_read
    dw  cmd_pci_config_read8, h_pci_config_read8
    dw  cmd_pci_config_read16, h_pci_config_read16
    dw  cmd_pci_config_read32, h_pci_config_read32
    dw  cmd_pci_cap_list, h_pci_cap_list
    dw  cmd_pci_cap_read, h_pci_cap_read
    dw  cmd_pci_bars,   h_pci_bars
    dw  cmd_pci_bar_read, h_pci_bar_read
    dw  cmd_pci_mem_read, h_pci_mem_read
    dw  cmd_pci_mem_read8, h_pci_mem_read8
    dw  cmd_pci_mem_read16, h_pci_mem_read16
    dw  cmd_pci_mem_read32, h_pci_mem_read32
    dw  0

align 8
flat_gdt:
    dq  0x0000000000000000
    dw  0xFFFF, 0x0000
    db  0x00, 10011010b, 10001111b, 0x00
    dw  0xFFFF, 0x0000
    db  0x00, 10010010b, 11001111b, 0x00
flat_gdt_end:
flat_gdt_desc:
    dw  flat_gdt_end - flat_gdt - 1
    dd  flat_gdt

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
    dec     ax
    mov     bx, [mem_addr]
    add     bx, ax
    jc      .range
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

; ---- mem.read{8,16,32} addr=H --------------------------------------------
;   Typed little-endian reads from segment 0, with alignment checks for
;   multi-byte widths.
h_mem_read8:
    mov     word [mem_width_bits], 8
    mov     word [mem_width_bytes], 1
    mov     word [mem_typed_usage_ptr], err_mem_read8_usage
    jmp     h_mem_read_typed

h_mem_read16:
    mov     word [mem_width_bits], 16
    mov     word [mem_width_bytes], 2
    mov     word [mem_typed_usage_ptr], err_mem_read16_usage
    jmp     h_mem_read_typed

h_mem_read32:
    mov     word [mem_width_bits], 32
    mov     word [mem_width_bytes], 4
    mov     word [mem_typed_usage_ptr], err_mem_read32_usage

h_mem_read_typed:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_addr
    call    find_kv_hex
    jc      .usage
    mov     [mem_addr], ax

    mov     bx, [mem_width_bytes]
    dec     bx
    mov     ax, 0xFFFF
    sub     ax, bx
    cmp     [mem_addr], ax
    ja      .range

    mov     ax, [mem_addr]
    test    ax, bx
    jnz     .range

    ; Response: ok addr=HHHH width=N value=HH..
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_addr_kw
    call    serial_puts_only
    mov     ax, [mem_addr]
    call    serial_put_hex_word
    mov     si, resp_width_kw
    call    serial_puts_only
    mov     ax, [mem_width_bits]
    call    serial_put_udec
    mov     si, resp_value_kw
    call    serial_puts_only

    mov     bp, [mem_addr]
    cmp     word [mem_width_bytes], 1
    jne     .maybe_word
    mov     al, [ds:bp]
    call    serial_put_hex_byte
    jmp     .done
.maybe_word:
    cmp     word [mem_width_bytes], 2
    jne     .dword
    mov     ax, [ds:bp]
    call    serial_put_hex_word
    jmp     .done
.dword:
    mov     eax, [ds:bp]
    call    serial_put_hex_dword
.done:
    call    respond_end
    ret
.usage:
    mov     si, [mem_typed_usage_ptr]
    call    respond
    ret
.range:
    mov     si, err_mem_typed_range
    call    respond
    ret

; ---- mem.read.seg seg=H offset=H len=N ------------------------------------
;   Bounded byte reads from an explicit real-mode segment:offset.
h_mem_read_seg:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_seg
    call    find_kv_hex
    jc      .usage
    mov     [mem_seg], ax

    mov     si, [arg_ptr]
    mov     di, key_offset
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

    dec     ax
    mov     bx, [mem_addr]
    add     bx, ax
    jc      .range

    ; Response: ok seg=HHHH offset=HHHH len=N data=HEXHEX...
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_seg_kw
    call    serial_puts_only
    mov     ax, [mem_seg]
    call    serial_put_hex_word
    mov     si, resp_offset_kw
    call    serial_puts_only
    mov     ax, [mem_addr]
    call    serial_put_hex_word
    mov     si, resp_len_kw
    call    serial_puts_only
    mov     ax, [mem_len]
    call    serial_put_udec
    mov     si, resp_data_kw
    call    serial_puts_only

    push    es
    mov     ax, [mem_seg]
    mov     es, ax
    mov     cx, [mem_len]
    mov     bx, [mem_addr]
    xor     di, di
.dump:
    mov     al, [es:bx+di]
    call    serial_put_hex_byte
    inc     di
    loop    .dump
    pop     es
    call    respond_end
    ret
.usage:
    mov     si, err_mem_read_seg_usage
    call    respond
    ret
.range:
    mov     si, err_mem_read_seg_range
    call    respond
    ret

; ---- mem.read.seg{8,16,32} seg=H offset=H -------------------------------
;   Typed little-endian reads through an explicit real-mode segment:offset.
h_mem_read_seg8:
    mov     word [mem_width_bits], 8
    mov     word [mem_width_bytes], 1
    mov     word [mem_typed_usage_ptr], err_mem_read_seg8_usage
    jmp     h_mem_read_seg_typed

h_mem_read_seg16:
    mov     word [mem_width_bits], 16
    mov     word [mem_width_bytes], 2
    mov     word [mem_typed_usage_ptr], err_mem_read_seg16_usage
    jmp     h_mem_read_seg_typed

h_mem_read_seg32:
    mov     word [mem_width_bits], 32
    mov     word [mem_width_bytes], 4
    mov     word [mem_typed_usage_ptr], err_mem_read_seg32_usage

h_mem_read_seg_typed:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_seg
    call    find_kv_hex
    jc      .usage
    mov     [mem_seg], ax

    mov     si, [arg_ptr]
    mov     di, key_offset
    call    find_kv_hex
    jc      .usage
    mov     [mem_addr], ax

    mov     bx, [mem_width_bytes]
    dec     bx
    mov     ax, 0xFFFF
    sub     ax, bx
    cmp     [mem_addr], ax
    ja      .range

    mov     ax, [mem_addr]
    test    ax, bx
    jnz     .range

    ; Response: ok seg=HHHH offset=HHHH width=N value=HH..
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_seg_kw
    call    serial_puts_only
    mov     ax, [mem_seg]
    call    serial_put_hex_word
    mov     si, resp_offset_kw
    call    serial_puts_only
    mov     ax, [mem_addr]
    call    serial_put_hex_word
    mov     si, resp_width_kw
    call    serial_puts_only
    mov     ax, [mem_width_bits]
    call    serial_put_udec
    mov     si, resp_value_kw
    call    serial_puts_only

    push    es
    mov     ax, [mem_seg]
    mov     es, ax
    mov     bx, [mem_addr]
    cmp     word [mem_width_bytes], 1
    jne     .maybe_word
    mov     al, [es:bx]
    pop     es
    call    serial_put_hex_byte
    jmp     .done
.maybe_word:
    cmp     word [mem_width_bytes], 2
    jne     .dword
    mov     ax, [es:bx]
    pop     es
    call    serial_put_hex_word
    jmp     .done
.dword:
    mov     eax, [es:bx]
    pop     es
    call    serial_put_hex_dword
.done:
    call    respond_end
    ret
.usage:
    mov     si, [mem_typed_usage_ptr]
    call    respond
    ret
.range:
    mov     si, err_mem_read_seg_typed_range
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
    mov     [io_value], al
    pop     cx                      ; CX = port
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_port_kw
    call    serial_puts_only
    mov     ax, cx
    call    serial_put_hex_word
    mov     si, resp_value_kw
    call    serial_puts_only
    mov     al, [io_value]
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

; ---- pci.scan -------------------------------------------------------------
;   Enumerate PCI via the legacy config mechanism (ports 0xCF8/0xCFC). Bus 0
;   is always scanned; PCI-to-PCI bridges (header type 0x01) are followed
;   into their secondary bus and recursively beyond that. The queue of buses
;   to visit lives in a 32-byte bitmap (pci_bus_todo): scanning a bus clears
;   its bit; finding a bridge sets the bit for its secondary bus number.
;   Multi-function devices are detected via the header-type high bit at
;   config offset 0x0E.
;
;   Response: ok devices=B.D.F:VVVV:DDDD:CC[,B.D.F:VVVV:DDDD:CC ...]
;     B = bus (2 hex)    D = device (2 hex, 00-1f)    F = function (1 hex, 0-7)
;     V = vendor id (4 hex)    D = device id (4 hex)
;     C = base class byte (2 hex, config offset 0x0B)
;   An empty bus yields `ok devices=`.
h_pci_scan:
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_devices_kw
    call    serial_puts_only

    ; Clear the bus-todo bitmap, then enqueue bus 0.
    push    es
    push    di
    push    ax
    push    cx
    xor     ax, ax
    mov     di, pci_bus_todo
    push    ds
    pop     es
    mov     cx, 16                  ; 32 bytes / 2
    rep stosw
    pop     cx
    pop     ax
    pop     di
    pop     es
    mov     byte [pci_bus_todo], 0x01   ; bit 0 = bus 0

    mov     byte [pci_first], 1
    xor     bx, bx                  ; BL = current bus number to consider
.bus_loop:
    ; Check bitmap bit for bus BL. AH = mask, SI = &pci_bus_todo[byte].
    mov     cl, bl
    and     cl, 0x07                ; CL = bit index within byte
    mov     ah, 1
    shl     ah, cl                  ; AH = bit mask
    mov     al, bl
    shr     al, 3                   ; AL = byte index
    mov     si, pci_bus_todo
    mov     dl, al
    xor     dh, dh
    add     si, dx
    test    [si], ah
    jz      .bus_skip
    not     ah
    and     [si], ah                ; clear bit (we're scanning now)
    mov     [pci_bus], bl
    push    bx
    call    pci_scan_one_bus
    pop     bx
.bus_skip:
    inc     bl
    jnz     .bus_loop               ; wraps after 255 -> 0, terminates loop

    call    respond_end
    ret

; ---- pci_scan_one_bus ------------------------------------------------------
;   Enumerate every populated function on [pci_bus]. Emits one record per
;   function (comma-separated continuation of the in-progress response line)
;   and sets pci_bus_todo bits for the secondary bus of any PCI-to-PCI
;   bridge it finds.
pci_scan_one_bus:
    mov     byte [pci_dev], 0
.dev_loop:
    mov     byte [pci_fn], 0
.fn_loop:
    xor     al, al                  ; register offset 0 -> vendor:device
    call    pci_config_read_dword
    cmp     ax, 0xFFFF              ; AX holds the low word = vendor id
    je      .fn_absent
    mov     [pci_ids], eax

    mov     al, 0x08                ; register offset 8 -> class/subclass/prog/rev
    call    pci_config_read_dword
    shr     eax, 24                 ; AL = base class byte
    mov     [pci_class], al

    ; Comma separator (not before the first record of the whole response)
    cmp     byte [pci_first], 1
    jne     .emit_comma
    mov     byte [pci_first], 0
    jmp     .emit_record
.emit_comma:
    mov     al, ','
    call    serial_putc
.emit_record:
    mov     al, [pci_bus]
    call    serial_put_hex_byte
    mov     al, '.'
    call    serial_putc
    mov     al, [pci_dev]
    call    serial_put_hex_byte
    mov     al, '.'
    call    serial_putc
    mov     al, [pci_fn]
    and     al, 0x07
    add     al, '0'
    call    serial_putc
    mov     al, ':'
    call    serial_putc
    mov     ax, [pci_ids]           ; vendor id (low word of register 0)
    call    serial_put_hex_word
    mov     al, ':'
    call    serial_putc
    mov     ax, [pci_ids + 2]       ; device id (high word of register 0)
    call    serial_put_hex_word
    mov     al, ':'
    call    serial_putc
    mov     al, [pci_class]
    call    serial_put_hex_byte

    ; Read header type (byte at config offset 0x0E) for two reasons: (a) the
    ; high bit tells us whether to scan functions 1..7, (b) bits 0..6 == 0x01
    ; means this is a PCI-to-PCI bridge whose secondary bus we must enqueue.
    mov     al, 0x0C
    call    pci_config_read_dword
    shr     eax, 16
    mov     [pci_hdr], al           ; full header-type byte (MF bit + type)
    and     al, 0x7F
    cmp     al, 0x01
    jne     .check_mf

    ; PCI-to-PCI bridge. Read dword at register 0x18; secondary bus is byte 1.
    mov     al, 0x18
    call    pci_config_read_dword
    shr     eax, 8                  ; AL = secondary bus number
    mov     cl, al
    shr     al, 3                   ; byte index into bitmap
    and     cl, 0x07                ; bit index
    mov     ah, 1
    shl     ah, cl
    xor     bh, bh
    mov     bl, al
    or      [pci_bus_todo + bx], ah

.check_mf:
    ; Was this fn=0? If so, multi-function bit (0x80) gates scanning 1..7.
    cmp     byte [pci_fn], 0
    jne     .fn_next
    test    byte [pci_hdr], 0x80
    jz      .dev_next
    jmp     .fn_next

.fn_absent:
    ; Absent function. On fn=0 the whole device slot is empty.
    cmp     byte [pci_fn], 0
    je      .dev_next
.fn_next:
    inc     byte [pci_fn]
    cmp     byte [pci_fn], 8
    jb      .fn_loop
.dev_next:
    inc     byte [pci_dev]
    cmp     byte [pci_dev], 32
    jb      .dev_loop
    ret

; pci_config_read_dword: read a 32-bit config register.
;   Input:  AL = register offset (byte, will be dword-aligned)
;           [pci_bus], [pci_dev], [pci_fn]
;   Output: EAX = dword value read from 0xCFC
;   Clobbers: DX. Caller-preserved: all others.
pci_config_read_dword:
    push    ebx
    push    ecx
    movzx   ebx, al
    and     ebx, 0xFC               ; align to dword
    movzx   ecx, byte [pci_fn]
    and     ecx, 0x07
    shl     ecx, 8
    or      ebx, ecx
    movzx   ecx, byte [pci_dev]
    and     ecx, 0x1F
    shl     ecx, 11
    or      ebx, ecx
    movzx   ecx, byte [pci_bus]
    shl     ecx, 16
    or      ebx, ecx
    or      ebx, 0x80000000         ; enable bit
    mov     dx, 0x0CF8
    mov     eax, ebx
    out     dx, eax
    mov     dx, 0x0CFC
    in      eax, dx
    pop     ecx
    pop     ebx
    ret

; ---- pci.config.read bdf=BB.DD.F offset=H len=N ---------------------------
;   Read up to 16 bytes from a PCI function's 256-byte config space.
;   Config reads are side-effect-free enough to expose directly, but still
;   bounded: the caller names a BDF and cannot walk past offset 0xff.
;
;   Response:
;     ok bdf=BB.DD.F offset=HH len=N data=HEX
h_pci_config_read:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_bdf
    call    find_kv
    jc      .usage
    call    parse_bdf
    jc      .usage

    mov     si, [arg_ptr]
    mov     di, key_offset
    call    find_kv_hex
    jc      .usage
    cmp     ax, 0x00FF
    ja      .range
    mov     [pci_cfg_offset], al

    mov     si, [arg_ptr]
    mov     di, key_len
    call    find_kv_dec
    jc      .usage
    test    ax, ax
    jz      .range
    cmp     ax, 16
    ja      .range
    mov     [pci_cfg_len], ax

    movzx   bx, byte [pci_cfg_offset]
    add     bx, ax
    dec     bx
    cmp     bx, 0x00FF
    ja      .range

    ; Probe presence via vendor id at config offset 0x00.
    xor     al, al
    call    pci_config_read_dword
    cmp     ax, 0xFFFF
    je      .absent

    ; "ok bdf=BB.DD.F offset=HH len=N data=..."
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_bdf_kw
    call    serial_puts_only
    call    emit_pci_bdf
    mov     si, resp_offset_kw
    call    serial_puts_only
    xor     ah, ah
    mov     al, [pci_cfg_offset]
    call    serial_put_hex_byte
    mov     si, resp_len_kw
    call    serial_puts_only
    mov     ax, [pci_cfg_len]
    call    serial_put_udec
    mov     si, resp_data_kw
    call    serial_puts_only

    mov     cx, [pci_cfg_len]
    mov     bl, [pci_cfg_offset]
.dump:
    mov     al, bl
    call    pci_config_read_dword
    mov     dl, bl
    and     dl, 0x03
    jz      .emit
.shift:
    shr     eax, 8
    dec     dl
    jnz     .shift
.emit:
    call    serial_put_hex_byte
    inc     bl
    loop    .dump
    call    respond_end
    ret
.absent:
    mov     si, err_pci_absent
    call    respond
    ret
.range:
    mov     si, err_pci_config_range
    call    respond
    ret
.usage:
    mov     si, err_pci_config_read_usage
    call    respond
    ret

; ---- pci.config.read{8,16,32} bdf=BB.DD.F offset=H ------------------------
;   Read one little-endian typed value from PCI config space.
;
;   Response:
;     ok bdf=BB.DD.F offset=HH width=N value=HEX
h_pci_config_read8:
    mov     word [pci_cfg_len], 1
    mov     word [pci_cfg_width_bits], 8
    mov     word [pci_cfg_usage_ptr], err_pci_config_read8_usage
    jmp     h_pci_config_read_typed

h_pci_config_read16:
    mov     word [pci_cfg_len], 2
    mov     word [pci_cfg_width_bits], 16
    mov     word [pci_cfg_usage_ptr], err_pci_config_read16_usage
    jmp     h_pci_config_read_typed

h_pci_config_read32:
    mov     word [pci_cfg_len], 4
    mov     word [pci_cfg_width_bits], 32
    mov     word [pci_cfg_usage_ptr], err_pci_config_read32_usage

h_pci_config_read_typed:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_bdf
    call    find_kv
    jc      .usage
    call    parse_bdf
    jc      .usage

    mov     si, [arg_ptr]
    mov     di, key_offset
    call    find_kv_hex
    jc      .usage
    cmp     ax, 0x00FF
    ja      .range
    mov     [pci_cfg_offset], al

    movzx   bx, byte [pci_cfg_offset]
    mov     ax, [pci_cfg_len]
    add     bx, ax
    dec     bx
    cmp     bx, 0x00FF
    ja      .range

    cmp     word [pci_cfg_len], 1
    je      .aligned
    mov     al, [pci_cfg_offset]
    mov     bl, [pci_cfg_len]
    dec     bl
    test    al, bl
    jnz     .range
.aligned:
    ; Probe presence via vendor id at config offset 0x00.
    xor     al, al
    call    pci_config_read_dword
    cmp     ax, 0xFFFF
    je      .absent

    ; "ok bdf=BB.DD.F offset=HH width=N value=..."
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_bdf_kw
    call    serial_puts_only
    call    emit_pci_bdf
    mov     si, resp_offset_kw
    call    serial_puts_only
    xor     ah, ah
    mov     al, [pci_cfg_offset]
    call    serial_put_hex_byte
    mov     si, resp_width_kw
    call    serial_puts_only
    mov     ax, [pci_cfg_width_bits]
    call    serial_put_udec
    mov     si, resp_value_kw
    call    serial_puts_only

    mov     al, [pci_cfg_offset]
    call    pci_config_read_dword
    mov     cl, [pci_cfg_offset]
    and     cl, 0x03
    jz      .emit_value
.shift:
    shr     eax, 8
    dec     cl
    jnz     .shift
.emit_value:
    cmp     word [pci_cfg_len], 1
    jne     .maybe_word
    call    serial_put_hex_byte
    jmp     .done
.maybe_word:
    cmp     word [pci_cfg_len], 2
    jne     .dword
    call    serial_put_hex_word
    jmp     .done
.dword:
    call    serial_put_hex_dword
.done:
    call    respond_end
    ret
.absent:
    mov     si, err_pci_absent
    call    respond
    ret
.range:
    mov     si, err_pci_config_typed_range
    call    respond
    ret
.usage:
    mov     si, [pci_cfg_usage_ptr]
    call    respond
    ret

; ---- pci.cap.list bdf=BB.DD.F ---------------------------------------------
;   Walk the conventional PCI capability linked list for a function.
;
;   Response:
;     ok bdf=BB.DD.F caps=OO:II[,OO:II...] truncated=N malformed=N
;       OO = capability offset, II = capability id.
h_pci_cap_list:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_bdf
    call    find_kv
    jc      .usage
    call    parse_bdf
    jc      .usage

    ; Probe presence via vendor id at config offset 0x00.
    xor     al, al
    call    pci_config_read_dword
    cmp     ax, 0xFFFF
    je      .absent

    mov     byte [pci_cap_truncated], 0
    mov     byte [pci_cap_malformed], 0

    ; Status bit 4 says whether the conventional capability list exists.
    mov     al, 0x04
    call    pci_config_read_dword
    shr     eax, 16
    test    ax, 0x0010
    jz      .no_caps

    ; Header types 0 and 1 put the first capability pointer at 0x34.
    ; CardBus (type 2) uses 0x14; other header types are treated as empty.
    mov     al, 0x0C
    call    pci_config_read_dword
    shr     eax, 16
    and     al, 0x7F
    cmp     al, 0x02
    je      .ptr14
    cmp     al, 0x01
    jbe     .ptr34
    jmp     .no_caps
.ptr34:
    mov     al, 0x34
    call    pci_config_read_dword
    jmp     .got_ptr
.ptr14:
    mov     al, 0x14
    call    pci_config_read_dword
.got_ptr:
    mov     bl, al
    test    bl, bl
    jz      .no_caps
    and     bl, 0xFC
    cmp     bl, 0x40
    jae     .store_ptr
    mov     byte [pci_cap_malformed], 1
    mov     bl, 0
.store_ptr:
    mov     [pci_cap_ptr], bl
    jmp     .emit_prefix
.no_caps:
    mov     byte [pci_cap_ptr], 0

.emit_prefix:
    ; "ok bdf=BB.DD.F caps=..."
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_bdf_kw
    call    serial_puts_only
    call    emit_pci_bdf
    mov     si, resp_caps_kw
    call    serial_puts_only

    cmp     byte [pci_cap_ptr], 0
    je      .done_caps

    mov     byte [pci_first], 1
    mov     cx, 48                  ; hard stop against cycles or bad chains
.cap_loop:
    mov     al, [pci_cap_ptr]
    cmp     al, 0x40
    jb      .malformed
    cmp     al, 0xFC
    ja      .malformed

    call    pci_config_read_dword
    mov     [pci_cap_id], al
    mov     bl, ah                  ; next capability pointer

    cmp     byte [pci_first], 1
    jne     .comma
    mov     byte [pci_first], 0
    jmp     .emit_cap
.comma:
    mov     al, ','
    call    serial_putc
.emit_cap:
    mov     al, [pci_cap_ptr]
    call    serial_put_hex_byte
    mov     al, ':'
    call    serial_putc
    mov     al, [pci_cap_id]
    call    serial_put_hex_byte

    test    bl, bl
    jz      .done_caps
    and     bl, 0xFC
    cmp     bl, 0x40
    jb      .malformed
    mov     [pci_cap_ptr], bl
    loop    .cap_loop
    mov     byte [pci_cap_truncated], 1
    jmp     .done_caps
.malformed:
    mov     byte [pci_cap_malformed], 1
.done_caps:
    mov     si, resp_truncated_kw
    call    serial_puts_only
    xor     ah, ah
    mov     al, [pci_cap_truncated]
    call    serial_put_udec
    mov     si, resp_malformed_kw
    call    serial_puts_only
    xor     ah, ah
    mov     al, [pci_cap_malformed]
    call    serial_put_udec
    call    respond_end
    ret
.absent:
    mov     si, err_pci_absent
    call    respond
    ret
.usage:
    mov     si, err_pci_cap_list_usage
    call    respond
    ret

; ---- pci.cap.read bdf=BB.DD.F cap=HH offset=H len=N -----------------------
;   Read up to 16 bytes relative to a capability returned by pci.cap.list.
;   The capability offset must be present in the device's linked list.
;
;   Response:
;     ok bdf=BB.DD.F cap=HH id=HH offset=HH len=N data=HEX
h_pci_cap_read:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_bdf
    call    find_kv
    jc      .usage
    call    parse_bdf
    jc      .usage

    mov     si, [arg_ptr]
    mov     di, key_cap
    call    find_kv_hex
    jc      .usage
    cmp     ax, 0x00FF
    ja      .range
    mov     [pci_cap_target], al
    cmp     al, 0x40
    jb      .range
    cmp     al, 0xFC
    ja      .range
    test    al, 0x03
    jnz     .range

    mov     si, [arg_ptr]
    mov     di, key_offset
    call    find_kv_hex
    jc      .usage
    cmp     ax, 0x00FF
    ja      .range
    mov     [pci_cap_offset], ax

    mov     si, [arg_ptr]
    mov     di, key_len
    call    find_kv_dec
    jc      .usage
    test    ax, ax
    jz      .range
    cmp     ax, 16
    ja      .range
    mov     [pci_cap_len], ax

    movzx   bx, byte [pci_cap_target]
    add     bx, [pci_cap_offset]
    cmp     bx, 0x00FF
    ja      .range
    mov     [pci_cap_eff_offset], bx
    add     bx, ax
    dec     bx
    cmp     bx, 0x00FF
    ja      .range

    ; Probe presence via vendor id at config offset 0x00.
    xor     al, al
    call    pci_config_read_dword
    cmp     ax, 0xFFFF
    je      .absent

    ; Status bit 4 says whether the conventional capability list exists.
    mov     al, 0x04
    call    pci_config_read_dword
    shr     eax, 16
    test    ax, 0x0010
    jz      .not_found

    ; Header types 0 and 1 put the first capability pointer at 0x34.
    ; CardBus (type 2) uses 0x14; other header types have no supported list.
    mov     al, 0x0C
    call    pci_config_read_dword
    shr     eax, 16
    and     al, 0x7F
    cmp     al, 0x02
    je      .ptr14
    cmp     al, 0x01
    jbe     .ptr34
    jmp     .not_found
.ptr34:
    mov     al, 0x34
    call    pci_config_read_dword
    jmp     .got_ptr
.ptr14:
    mov     al, 0x14
    call    pci_config_read_dword
.got_ptr:
    mov     bl, al
    test    bl, bl
    jz      .not_found
    and     bl, 0xFC
    cmp     bl, 0x40
    jb      .not_found

    mov     cx, 48
.find_loop:
    mov     al, bl
    cmp     al, 0x40
    jb      .not_found
    cmp     al, 0xFC
    ja      .not_found
    call    pci_config_read_dword
    mov     [pci_cap_id], al
    cmp     bl, [pci_cap_target]
    je      .found
    mov     bl, ah
    test    bl, bl
    jz      .not_found
    and     bl, 0xFC
    cmp     bl, 0x40
    jb      .not_found
    loop    .find_loop
    jmp     .not_found

.found:
    ; "ok bdf=BB.DD.F cap=HH id=HH offset=HH len=N data=..."
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_bdf_kw
    call    serial_puts_only
    call    emit_pci_bdf
    mov     si, resp_cap_kw
    call    serial_puts_only
    mov     al, [pci_cap_target]
    call    serial_put_hex_byte
    mov     si, resp_id_kw
    call    serial_puts_only
    mov     al, [pci_cap_id]
    call    serial_put_hex_byte
    mov     si, resp_offset_kw
    call    serial_puts_only
    mov     ax, [pci_cap_offset]
    call    serial_put_hex_byte
    mov     si, resp_len_kw
    call    serial_puts_only
    mov     ax, [pci_cap_len]
    call    serial_put_udec
    mov     si, resp_data_kw
    call    serial_puts_only

    mov     cx, [pci_cap_len]
    mov     bl, [pci_cap_eff_offset]
.dump:
    mov     al, bl
    call    pci_config_read_dword
    mov     dl, bl
    and     dl, 0x03
    jz      .emit
.shift:
    shr     eax, 8
    dec     dl
    jnz     .shift
.emit:
    call    serial_put_hex_byte
    inc     bl
    loop    .dump
    call    respond_end
    ret
.not_found:
    mov     si, err_pci_cap_not_found
    call    respond
    ret
.absent:
    mov     si, err_pci_absent
    call    respond
    ret
.range:
    mov     si, err_pci_cap_read_range
    call    respond
    ret
.usage:
    mov     si, err_pci_cap_read_usage
    call    respond
    ret

; ---- pci.bars bdf=BB.DD.F -------------------------------------------------
;   Decode the Base Address Registers of a single PCI function. Type 0 headers
;   carry six BARs (config offsets 0x10..0x24); type 1 (PCI-to-PCI bridge)
;   headers carry two (0x10..0x14); other header types have none and the
;   response emits `bars=` with no records.
;
;   Each populated slot becomes one comma-separated record. The low bits of
;   the raw dword encode the kind:
;     bit 0   = 1 -> I/O BAR       record: `N:io:HHHHHHHH`
;     bit 0   = 0 -> memory BAR
;       bits[2:1] = 00 (32-bit)    record: `N:m32:HHHHHHHH:p|n`
;       bits[2:1] = 10 (64-bit)    record: `N:m64:HHHHHHHHHHHHHHHH:p|n`
;                                  (consumes the next slot, which is skipped)
;       bits[2:1] = 01 (<1 MB)     record: `N:mlt1:HHHHHHHH:p|n`
;       bits[2:1] = 11 (reserved)  record: `N:rsv:HHHHHHHH:p|n`
;     `p` or `n` is the prefetch bit (bit 3) of the low dword.
;     An unused slot (raw == 0) is reported as `N:none`.
;     A 64-bit BAR declared on the last available slot (so there is no room
;     for the high dword) is reported as `N:m64trunc:HHHHHHHH:p|n` — only
;     the low 32 bits are reported, and the device is self-contradictory.
;
;   An unpopulated function yields `err code=unavailable detail="no such
;   function"`. A malformed BDF yields `bad_arg`.
h_pci_bars:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_bdf
    call    find_kv
    jc      .usage
    call    parse_bdf
    jc      .usage

    ; Probe presence via vendor id at config offset 0x00.
    xor     al, al
    call    pci_config_read_dword
    cmp     ax, 0xFFFF
    je      .absent

    ; Header type (config 0x0E) -> number of BAR slots.
    mov     al, 0x0C
    call    pci_config_read_dword
    shr     eax, 16
    and     al, 0x7F
    mov     cl, 6                   ; default: 6 slots (header type 0x00)
    cmp     al, 0x00
    je      .got_nbars
    mov     cl, 2                   ; PCI-to-PCI bridge: 2 slots
    cmp     al, 0x01
    je      .got_nbars
    xor     cl, cl                  ; other header types: no BARs
.got_nbars:
    mov     [pci_nbars], cl

    ; "ok bdf=BB.DD.F bars="
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_bdf_kw
    call    serial_puts_only
    mov     al, [pci_bus]
    call    serial_put_hex_byte
    mov     al, '.'
    call    serial_putc
    mov     al, [pci_dev]
    call    serial_put_hex_byte
    mov     al, '.'
    call    serial_putc
    mov     al, [pci_fn]
    and     al, 0x07
    add     al, '0'
    call    serial_putc
    mov     si, resp_bars_kw
    call    serial_puts_only

    mov     byte [pci_first], 1
    xor     bl, bl                  ; BL = current BAR index
.bar_loop:
    cmp     bl, [pci_nbars]
    jae     .done

    ; Separator: comma before every record except the first.
    cmp     byte [pci_first], 1
    jne     .comma
    mov     byte [pci_first], 0
    jmp     .emit
.comma:
    mov     al, ','
    call    serial_putc
.emit:
    mov     al, bl
    add     al, '0'
    call    serial_putc
    mov     al, ':'
    call    serial_putc

    ; Read BAR at offset 0x10 + 4*BL.
    mov     al, bl
    shl     al, 2
    add     al, 0x10
    call    pci_config_read_dword
    mov     [pci_bar_lo], eax

    test    eax, eax
    jnz     .populated
    mov     si, str_none
    call    serial_puts_only
    inc     bl
    jmp     .bar_loop
.populated:
    test    al, 0x01
    jz      .mem

    ; ---- I/O BAR -------------------------------------------------------
    and     eax, 0xFFFFFFFC
    mov     si, str_io
    call    serial_puts_only
    call    serial_put_hex_dword
    inc     bl
    jmp     .bar_loop

.mem:
    ; Decode type (bits 2:1) and prefetch (bit 3) from the low byte.
    mov     dl, al
    mov     dh, dl
    shr     dh, 3
    and     dh, 0x01
    mov     [pci_pref], dh
    and     dl, 0x06
    shr     dl, 1                   ; DL = memory type (0,1,2,3)

    cmp     dl, 2
    je      .m64
    cmp     dl, 1
    je      .mlt1
    cmp     dl, 3
    je      .rsv

    ; 32-bit memory BAR.
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     si, str_m32
    call    serial_puts_only
    call    serial_put_hex_dword
    call    emit_pref_suffix
    inc     bl
    jmp     .bar_loop

.m64:
    ; 64-bit memory BAR — reads the high dword from slot BL+1.
    mov     al, bl
    inc     al
    cmp     al, [pci_nbars]
    jae     .m64_truncated          ; malformed: no room for the high slot
    shl     al, 2
    add     al, 0x10
    call    pci_config_read_dword
    mov     [pci_bar_hi], eax
    mov     si, str_m64
    call    serial_puts_only
    mov     eax, [pci_bar_hi]
    call    serial_put_hex_dword
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    call    serial_put_hex_dword
    call    emit_pref_suffix
    add     bl, 2                   ; consumed two slots
    jmp     .bar_loop

.m64_truncated:
    ; Self-contradictory device: BAR claims 64-bit but there's no room for
    ; the high dword. Emit a distinct token so the model can tell this
    ; apart from a well-formed 32-bit BAR.
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     si, str_m64trunc
    call    serial_puts_only
    call    serial_put_hex_dword
    call    emit_pref_suffix
    inc     bl
    jmp     .bar_loop

.mlt1:
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     si, str_mlt1
    call    serial_puts_only
    call    serial_put_hex_dword
    call    emit_pref_suffix
    inc     bl
    jmp     .bar_loop

.rsv:
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     si, str_rsv
    call    serial_puts_only
    call    serial_put_hex_dword
    call    emit_pref_suffix
    inc     bl
    jmp     .bar_loop

.done:
    call    respond_end
    ret
.absent:
    mov     si, err_pci_absent
    call    respond
    ret
.usage:
    mov     si, err_pci_bars_usage
    call    respond
    ret

; ---- pci.bar.read bdf=BB.DD.F bar=N offset=H len=N ------------------------
;   Read up to 16 bytes from an I/O-space BAR. The address is intentionally
;   BAR-relative rather than arbitrary: the caller must first identify a PCI
;   function, choose one of its declared BAR slots, and stay near the BAR base
;   (offset <= ff, len <= 16) inside 16-bit I/O port space. Memory BARs are
;   denied in this first version; most QEMU MMIO windows live above real mode's
;   direct addressable range anyway.
;
;   Response:
;     ok bdf=BB.DD.F bar=N kind=io port=HHHH offset=HHHH len=N data=HEX
h_pci_bar_read:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_bdf
    call    find_kv
    jc      .usage
    call    parse_bdf
    jc      .usage

    mov     si, [arg_ptr]
    mov     di, key_bar
    call    find_kv_dec
    jc      .usage
    cmp     ax, 5
    ja      .range
    mov     [pci_bar_idx], al

    mov     si, [arg_ptr]
    mov     di, key_offset
    call    find_kv_hex
    jc      .usage
    cmp     ax, 0x00FF
    ja      .range
    mov     [pci_bar_offset], ax

    mov     si, [arg_ptr]
    mov     di, key_len
    call    find_kv_dec
    jc      .usage
    test    ax, ax
    jz      .range
    cmp     ax, 16
    ja      .range
    mov     [pci_bar_len], ax

    ; Probe presence via vendor id at config offset 0x00.
    xor     al, al
    call    pci_config_read_dword
    cmp     ax, 0xFFFF
    je      .absent

    ; Header type (config 0x0E) -> number of BAR slots.
    mov     al, 0x0C
    call    pci_config_read_dword
    shr     eax, 16
    and     al, 0x7F
    mov     cl, 6                   ; default: 6 slots (header type 0x00)
    cmp     al, 0x00
    je      .got_nbars
    mov     cl, 2                   ; PCI-to-PCI bridge: 2 slots
    cmp     al, 0x01
    je      .got_nbars
    xor     cl, cl                  ; other header types: no BARs
.got_nbars:
    mov     [pci_nbars], cl
    mov     al, [pci_bar_idx]
    cmp     al, [pci_nbars]
    jae     .range

    ; Read BAR at offset 0x10 + 4*bar.
    mov     al, [pci_bar_idx]
    shl     al, 2
    add     al, 0x10
    call    pci_config_read_dword
    mov     [pci_bar_lo], eax
    test    eax, eax
    jz      .bar_absent
    test    al, 0x01
    jz      .not_io

    ; I/O BAR: low two bits are flags, the rest is the base port. The CPU's
    ; IN instruction addresses 16-bit port space, so reject any base/offset
    ; combination that does not fit.
    and     eax, 0xFFFFFFFC
    cmp     eax, 0x0000FFFF
    ja      .port_range
    mov     bx, ax
    add     bx, [pci_bar_offset]
    jc      .port_range
    mov     ax, [pci_bar_len]
    dec     ax
    add     ax, bx
    jc      .port_range
    mov     [pci_bar_port], bx

    ; "ok bdf=BB.DD.F bar=N kind=io port=HHHH offset=HHHH len=N data=..."
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_bdf_kw
    call    serial_puts_only
    call    emit_pci_bdf
    mov     si, resp_bar_kw
    call    serial_puts_only
    xor     ah, ah
    mov     al, [pci_bar_idx]
    call    serial_put_udec
    mov     si, resp_kind_io_kw
    call    serial_puts_only
    mov     si, resp_port_kw
    call    serial_puts_only
    mov     ax, [pci_bar_port]
    call    serial_put_hex_word
    mov     si, resp_offset_kw
    call    serial_puts_only
    mov     ax, [pci_bar_offset]
    call    serial_put_hex_word
    mov     si, resp_len_kw
    call    serial_puts_only
    mov     ax, [pci_bar_len]
    call    serial_put_udec
    mov     si, resp_data_kw
    call    serial_puts_only
    mov     cx, [pci_bar_len]
    mov     dx, [pci_bar_port]
.dump:
    in      al, dx
    call    serial_put_hex_byte
    inc     dx
    loop    .dump
    call    respond_end
    ret
.absent:
    mov     si, err_pci_absent
    call    respond
    ret
.bar_absent:
    mov     si, err_pci_bar_absent
    call    respond
    ret
.not_io:
    mov     si, err_pci_bar_non_io
    call    respond
    ret
.port_range:
    mov     si, err_pci_bar_port_range
    call    respond
    ret
.range:
    mov     si, err_pci_bar_range
    call    respond
    ret
.usage:
    mov     si, err_pci_bar_read_usage
    call    respond
    ret

; ---- pci.mem.read bdf=BB.DD.F bar=N offset=H len=N ------------------------
;   Read up to 16 bytes from a memory-space BAR. This is the MMIO sibling of
;   pci.bar.read: the caller still names a PCI function and BAR slot instead
;   of an arbitrary address. Access uses an unreal-mode FS cache with a flat
;   4 GB limit, while DS/SS stay in ordinary real-mode shape.
;
;   Response:
;     ok bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=HHHHHHHH offset=HHHH len=N data=HEX
h_pci_mem_read:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_bdf
    call    find_kv
    jc      .usage
    call    parse_bdf
    jc      .usage

    mov     si, [arg_ptr]
    mov     di, key_bar
    call    find_kv_dec
    jc      .usage
    cmp     ax, 5
    ja      .range
    mov     [pci_bar_idx], al

    mov     si, [arg_ptr]
    mov     di, key_offset
    call    find_kv_hex
    jc      .usage
    cmp     ax, 0x00FF
    ja      .range
    mov     [pci_bar_offset], ax

    mov     si, [arg_ptr]
    mov     di, key_len
    call    find_kv_dec
    jc      .usage
    test    ax, ax
    jz      .range
    cmp     ax, 16
    ja      .range
    mov     [pci_bar_len], ax

    ; Probe presence via vendor id at config offset 0x00.
    xor     al, al
    call    pci_config_read_dword
    cmp     ax, 0xFFFF
    je      .absent

    ; Header type (config 0x0E) -> number of BAR slots.
    mov     al, 0x0C
    call    pci_config_read_dword
    shr     eax, 16
    and     al, 0x7F
    mov     cl, 6
    cmp     al, 0x00
    je      .got_nbars
    mov     cl, 2
    cmp     al, 0x01
    je      .got_nbars
    xor     cl, cl
.got_nbars:
    mov     [pci_nbars], cl
    mov     al, [pci_bar_idx]
    cmp     al, [pci_nbars]
    jae     .range

    ; Read BAR at offset 0x10 + 4*bar.
    mov     al, [pci_bar_idx]
    shl     al, 2
    add     al, 0x10
    call    pci_config_read_dword
    mov     [pci_bar_lo], eax
    test    eax, eax
    jz      .bar_absent
    test    al, 0x01
    jnz     .not_mem

    mov     dl, al
    and     dl, 0x06
    shr     dl, 1                   ; DL = memory type (0,1,2,3)
    cmp     dl, 2
    je      .m64
    cmp     dl, 1
    je      .mlt1
    cmp     dl, 3
    je      .unsupported

    ; 32-bit memory BAR.
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     word [pci_mem_kind_ptr], str_kind_m32
    jmp     .got_base

.mlt1:
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     word [pci_mem_kind_ptr], str_kind_mlt1
    jmp     .got_base

.m64:
    ; 64-bit memory BAR. This v0.1 read path can address only the low
    ; 32-bit physical space, so high dwords other than zero are rejected.
    mov     al, [pci_bar_idx]
    inc     al
    cmp     al, [pci_nbars]
    jae     .unsupported
    shl     al, 2
    add     al, 0x10
    call    pci_config_read_dword
    test    eax, eax
    jnz     .addr_range
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     word [pci_mem_kind_ptr], str_kind_m64

.got_base:
    movzx   ebx, word [pci_bar_offset]
    add     eax, ebx
    jc      .addr_range
    mov     [pci_mem_addr], eax
    mov     ebx, eax
    movzx   eax, word [pci_bar_len]
    dec     eax
    add     eax, ebx
    jc      .addr_range

    ; "ok bdf=BB.DD.F bar=N kind=K addr=HHHHHHHH offset=HHHH len=N data=..."
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_bdf_kw
    call    serial_puts_only
    call    emit_pci_bdf
    mov     si, resp_bar_kw
    call    serial_puts_only
    xor     ah, ah
    mov     al, [pci_bar_idx]
    call    serial_put_udec
    mov     si, resp_kind_kw
    call    serial_puts_only
    mov     si, [pci_mem_kind_ptr]
    call    serial_puts_only
    mov     si, resp_addr_kw
    call    serial_puts_only
    mov     eax, [pci_mem_addr]
    call    serial_put_hex_dword
    mov     si, resp_offset_kw
    call    serial_puts_only
    mov     ax, [pci_bar_offset]
    call    serial_put_hex_word
    mov     si, resp_len_kw
    call    serial_puts_only
    mov     ax, [pci_bar_len]
    call    serial_put_udec
    mov     si, resp_data_kw
    call    serial_puts_only

    mov     cx, [pci_bar_len]
    mov     esi, [pci_mem_addr]
.dump:
    call    enable_flat_fs
    mov     al, [fs:esi]
    push    esi
    call    serial_put_hex_byte
    pop     esi
    inc     esi
    loop    .dump
    call    respond_end
    ret

.absent:
    mov     si, err_pci_absent
    call    respond
    ret
.bar_absent:
    mov     si, err_pci_bar_absent
    call    respond
    ret
.not_mem:
    mov     si, err_pci_mem_non_mem
    call    respond
    ret
.unsupported:
    mov     si, err_pci_mem_unsupported
    call    respond
    ret
.addr_range:
    mov     si, err_pci_mem_addr_range
    call    respond
    ret
.range:
    mov     si, err_pci_bar_range
    call    respond
    ret
.usage:
    mov     si, err_pci_mem_read_usage
    call    respond
    ret

; ---- pci.mem.read{8,16,32} bdf=BB.DD.F bar=N offset=H ---------------------
;   Typed little-endian reads from a memory-space BAR. These are intentionally
;   the same constrained BAR-relative operation as pci.mem.read, but return a
;   decoded value instead of a byte string.
;
;   Response:
;     ok bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=HHHHHHHH offset=HHHH width=N value=HEX
h_pci_mem_read8:
    mov     word [pci_bar_len], 1
    mov     word [pci_mem_width_bits], 8
    mov     word [pci_mem_usage_ptr], err_pci_mem_read8_usage
    jmp     h_pci_mem_read_typed

h_pci_mem_read16:
    mov     word [pci_bar_len], 2
    mov     word [pci_mem_width_bits], 16
    mov     word [pci_mem_usage_ptr], err_pci_mem_read16_usage
    jmp     h_pci_mem_read_typed

h_pci_mem_read32:
    mov     word [pci_bar_len], 4
    mov     word [pci_mem_width_bits], 32
    mov     word [pci_mem_usage_ptr], err_pci_mem_read32_usage

h_pci_mem_read_typed:
    mov     si, [arg_ptr]
    test    si, si
    jz      .usage
    mov     di, key_bdf
    call    find_kv
    jc      .usage
    call    parse_bdf
    jc      .usage

    mov     si, [arg_ptr]
    mov     di, key_bar
    call    find_kv_dec
    jc      .usage
    cmp     ax, 5
    ja      .range
    mov     [pci_bar_idx], al

    mov     si, [arg_ptr]
    mov     di, key_offset
    call    find_kv_hex
    jc      .usage
    cmp     ax, 0x00FF
    ja      .range
    mov     [pci_bar_offset], ax
    cmp     word [pci_bar_len], 1
    je      .aligned
    cmp     word [pci_bar_len], 2
    jne     .align32
    test    ax, 0x0001
    jnz     .range
    jmp     .aligned
.align32:
    test    ax, 0x0003
    jnz     .range
.aligned:

    ; Probe presence via vendor id at config offset 0x00.
    xor     al, al
    call    pci_config_read_dword
    cmp     ax, 0xFFFF
    je      .absent

    ; Header type (config 0x0E) -> number of BAR slots.
    mov     al, 0x0C
    call    pci_config_read_dword
    shr     eax, 16
    and     al, 0x7F
    mov     cl, 6
    cmp     al, 0x00
    je      .got_nbars
    mov     cl, 2
    cmp     al, 0x01
    je      .got_nbars
    xor     cl, cl
.got_nbars:
    mov     [pci_nbars], cl
    mov     al, [pci_bar_idx]
    cmp     al, [pci_nbars]
    jae     .range

    ; Read BAR at offset 0x10 + 4*bar.
    mov     al, [pci_bar_idx]
    shl     al, 2
    add     al, 0x10
    call    pci_config_read_dword
    mov     [pci_bar_lo], eax
    test    eax, eax
    jz      .bar_absent
    test    al, 0x01
    jnz     .not_mem

    mov     dl, al
    and     dl, 0x06
    shr     dl, 1                   ; DL = memory type (0,1,2,3)
    cmp     dl, 2
    je      .m64
    cmp     dl, 1
    je      .mlt1
    cmp     dl, 3
    je      .unsupported

    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     word [pci_mem_kind_ptr], str_kind_m32
    jmp     .got_base

.mlt1:
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     word [pci_mem_kind_ptr], str_kind_mlt1
    jmp     .got_base

.m64:
    mov     al, [pci_bar_idx]
    inc     al
    cmp     al, [pci_nbars]
    jae     .unsupported
    shl     al, 2
    add     al, 0x10
    call    pci_config_read_dword
    test    eax, eax
    jnz     .addr_range
    mov     eax, [pci_bar_lo]
    and     eax, 0xFFFFFFF0
    mov     word [pci_mem_kind_ptr], str_kind_m64

.got_base:
    movzx   ebx, word [pci_bar_offset]
    add     eax, ebx
    jc      .addr_range
    mov     [pci_mem_addr], eax
    mov     ebx, eax
    movzx   eax, word [pci_bar_len]
    dec     eax
    add     eax, ebx
    jc      .addr_range

    ; "ok bdf=BB.DD.F bar=N kind=K addr=HHHHHHHH offset=HHHH width=N value=..."
    mov     si, resp_ok_prefix
    call    serial_puts_only
    mov     si, resp_bdf_kw
    call    serial_puts_only
    call    emit_pci_bdf
    mov     si, resp_bar_kw
    call    serial_puts_only
    xor     ah, ah
    mov     al, [pci_bar_idx]
    call    serial_put_udec
    mov     si, resp_kind_kw
    call    serial_puts_only
    mov     si, [pci_mem_kind_ptr]
    call    serial_puts_only
    mov     si, resp_addr_kw
    call    serial_puts_only
    mov     eax, [pci_mem_addr]
    call    serial_put_hex_dword
    mov     si, resp_offset_kw
    call    serial_puts_only
    mov     ax, [pci_bar_offset]
    call    serial_put_hex_word
    mov     si, resp_width_kw
    call    serial_puts_only
    mov     ax, [pci_mem_width_bits]
    call    serial_put_udec
    mov     si, resp_value_kw
    call    serial_puts_only

    mov     esi, [pci_mem_addr]
    call    enable_flat_fs
    cmp     word [pci_bar_len], 1
    je      .read8
    cmp     word [pci_bar_len], 2
    je      .read16
    mov     eax, [fs:esi]
    call    serial_put_hex_dword
    jmp     .done
.read16:
    mov     ax, [fs:esi]
    call    serial_put_hex_word
    jmp     .done
.read8:
    mov     al, [fs:esi]
    call    serial_put_hex_byte
.done:
    call    respond_end
    ret

.absent:
    mov     si, err_pci_absent
    call    respond
    ret
.bar_absent:
    mov     si, err_pci_bar_absent
    call    respond
    ret
.not_mem:
    mov     si, err_pci_mem_non_mem
    call    respond
    ret
.unsupported:
    mov     si, err_pci_mem_unsupported
    call    respond
    ret
.addr_range:
    mov     si, err_pci_mem_addr_range
    call    respond
    ret
.range:
    mov     si, err_pci_mem_typed_range
    call    respond
    ret
.usage:
    mov     si, [pci_mem_usage_ptr]
    call    respond
    ret

; enable_flat_fs: leave FS with a base-0, 4 GB data descriptor cache while
; returning to real mode. DS/ES/SS are deliberately not reloaded.
enable_flat_fs:
    pushf
    push    eax
    cli
    in      al, 0x92
    or      al, 0x02                ; enable A20 via fast gate
    and     al, 0xFE                ; avoid the reset bit
    out     0x92, al
    lgdt    [flat_gdt_desc]
    mov     eax, cr0
    or      eax, 0x00000001
    mov     cr0, eax
    jmp     FLAT_CODE_SEL:.pmode
.pmode:
    mov     ax, FLAT_DATA_SEL
    mov     fs, ax
    mov     eax, cr0
    and     eax, 0xFFFFFFFE
    mov     cr0, eax
    jmp     0x0000:.real
.real:
    pop     eax
    popf
    ret

emit_pci_bdf:
    mov     al, [pci_bus]
    call    serial_put_hex_byte
    mov     al, '.'
    call    serial_putc
    mov     al, [pci_dev]
    call    serial_put_hex_byte
    mov     al, '.'
    call    serial_putc
    mov     al, [pci_fn]
    and     al, 0x07
    add     al, '0'
    call    serial_putc
    ret

; emit_pref_suffix: appends ":p" (prefetchable) or ":n" using [pci_pref].
emit_pref_suffix:
    mov     al, ':'
    call    serial_putc
    mov     al, 'n'
    cmp     byte [pci_pref], 0
    je      .out
    mov     al, 'p'
.out:
    call    serial_putc
    ret

; parse_bdf: DS:SI -> "BB.DD.F" where BB and DD are 1-4 hex digits (bounded
; by bus<=0xFF, device<=0x1F) and F is a single decimal digit 0..7 followed
; by end-of-string or an argument separator. Writes pci_bus/pci_dev/pci_fn.
; CF=0 on success.
parse_bdf:
    call    parse_hex_word
    jc      .bad
    cmp     ax, 0x00FF
    ja      .bad
    mov     [pci_bus], al
    cmp     byte [si], '.'
    jne     .bad
    inc     si
    call    parse_hex_word
    jc      .bad
    cmp     ax, 0x001F
    ja      .bad
    mov     [pci_dev], al
    cmp     byte [si], '.'
    jne     .bad
    inc     si
    mov     al, [si]
    sub     al, '0'
    cmp     al, 7
    ja      .bad
    mov     [pci_fn], al
    inc     si
    mov     al, [si]
    test    al, al
    jz      .ok
    cmp     al, ' '
    jne     .bad
.ok:
    clc
    ret
.bad:
    stc
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
    jc      .no
    call    kv_value_done
    ret
.no:
    stc
    ret

; find_kv_dec: same as find_kv_hex but the value is decimal.
find_kv_dec:
    call    find_kv
    jc      .no
    call    parse_dec_word
    jc      .no
    call    kv_value_done
    ret
.no:
    stc
    ret

kv_value_done:
    cmp     byte [si], 0
    je      .ok
    cmp     byte [si], ' '
    je      .ok
    stc
    ret
.ok:
    clc
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

; serial_put_hex_dword: EAX = dword, emit 8 lowercase hex digits (MSB first).
serial_put_hex_dword:
    push    eax
    shr     eax, 16
    call    serial_put_hex_word
    pop     eax
    call    serial_put_hex_word
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
    push    dx
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
    test    dx, dx
    jnz     .overflow_pop
    mov     bx, ax
    pop     ax
    xor     ah, ah
    add     bx, ax
    jc      .overflow
    inc     si
    inc     cx
    cmp     cx, 5
    jb      .l
.e:
    or      cx, cx
    jz      .none
    mov     ax, bx
    clc
    pop     dx
    pop     cx
    pop     bx
    ret
.none:
    stc
    pop     dx
    pop     cx
    pop     bx
    ret
.overflow_pop:
    pop     ax
.overflow:
    stc
    pop     dx
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

ready_msg:      db '# llmos v0.1 proto=1 primitives=29', 13, 10, 0

; Command names (NUL-terminated)
cmd_help:       db 'help', 0
cmd_describe:   db 'describe', 0
cmd_cpu_vendor: db 'cpu.vendor', 0
cmd_cpu_feat:   db 'cpu.features', 0
cmd_mem_query:  db 'mem.query', 0
cmd_mem_read:   db 'mem.read', 0
cmd_mem_read8:  db 'mem.read8', 0
cmd_mem_read16: db 'mem.read16', 0
cmd_mem_read32: db 'mem.read32', 0
cmd_mem_read_seg: db 'mem.read.seg', 0
cmd_mem_read_seg8: db 'mem.read.seg8', 0
cmd_mem_read_seg16: db 'mem.read.seg16', 0
cmd_mem_read_seg32: db 'mem.read.seg32', 0
cmd_rtc_now:    db 'rtc.now', 0
cmd_ticks:      db 'ticks.since_boot', 0
cmd_io_in:      db 'io.in', 0
cmd_pci_scan:   db 'pci.scan', 0
cmd_pci_config_read: db 'pci.config.read', 0
cmd_pci_config_read8: db 'pci.config.read8', 0
cmd_pci_config_read16: db 'pci.config.read16', 0
cmd_pci_config_read32: db 'pci.config.read32', 0
cmd_pci_cap_list: db 'pci.cap.list', 0
cmd_pci_cap_read: db 'pci.cap.read', 0
cmd_pci_bars:   db 'pci.bars', 0
cmd_pci_bar_read: db 'pci.bar.read', 0
cmd_pci_mem_read: db 'pci.mem.read', 0
cmd_pci_mem_read8: db 'pci.mem.read8', 0
cmd_pci_mem_read16: db 'pci.mem.read16', 0
cmd_pci_mem_read32: db 'pci.mem.read32', 0

; Argument key strings
key_addr:       db 'addr', 0
key_seg:        db 'seg', 0
key_len:        db 'len', 0
key_port:       db 'port', 0
key_bdf:        db 'bdf', 0
key_bar:        db 'bar', 0
key_offset:     db 'offset', 0
key_cap:        db 'cap', 0

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
resp_seg_kw:        db ' seg=', 0
resp_len_kw:        db ' len=', 0
resp_data_kw:       db ' data=', 0
resp_iso_kw:        db ' iso=', 0
resp_ms_kw:         db ' ms=', 0
resp_port_kw:       db ' port=', 0
resp_value_kw:      db ' value=', 0
resp_devices_kw:    db ' devices=', 0
resp_bdf_kw:        db ' bdf=', 0
resp_bar_kw:        db ' bar=', 0
resp_bars_kw:       db ' bars=', 0
resp_offset_kw:     db ' offset=', 0
resp_cap_kw:        db ' cap=', 0
resp_id_kw:         db ' id=', 0
resp_kind_kw:       db ' kind=', 0
resp_kind_io_kw:    db ' kind=io', 0
resp_width_kw:      db ' width=', 0
resp_caps_kw:       db ' caps=', 0
resp_truncated_kw:  db ' truncated=', 0
resp_malformed_kw:  db ' malformed=', 0

; pci.bars record-kind prefixes (each includes the trailing ':' separator so
; the base-address hex can be appended directly).
str_none:           db 'none', 0
str_io:             db 'io:', 0
str_m32:            db 'm32:', 0
str_m64:            db 'm64:', 0
str_m64trunc:       db 'm64trunc:', 0
str_mlt1:           db 'mlt1:', 0
str_rsv:            db 'rsv:', 0
str_kind_m32:       db 'm32', 0
str_kind_m64:       db 'm64', 0
str_kind_mlt1:      db 'mlt1', 0

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
    db 'err code=out_of_range detail="addr or len out of range"', 0
err_mem_read8_usage:
    db 'err code=bad_arg detail="usage: mem.read8 addr=HHHH"', 0
err_mem_read16_usage:
    db 'err code=bad_arg detail="usage: mem.read16 addr=HHHH"', 0
err_mem_read32_usage:
    db 'err code=bad_arg detail="usage: mem.read32 addr=HHHH"', 0
err_mem_typed_range:
    db 'err code=out_of_range detail="addr or alignment out of range"', 0
err_mem_read_seg_usage:
    db 'err code=bad_arg detail="usage: mem.read.seg seg=HHHH offset=HHHH len=N"', 0
err_mem_read_seg_range:
    db 'err code=out_of_range detail="offset or len out of range"', 0
err_mem_read_seg8_usage:
    db 'err code=bad_arg detail="usage: mem.read.seg8 seg=HHHH offset=HHHH"', 0
err_mem_read_seg16_usage:
    db 'err code=bad_arg detail="usage: mem.read.seg16 seg=HHHH offset=HHHH"', 0
err_mem_read_seg32_usage:
    db 'err code=bad_arg detail="usage: mem.read.seg32 seg=HHHH offset=HHHH"', 0
err_mem_read_seg_typed_range:
    db 'err code=out_of_range detail="offset or alignment out of range"', 0
err_rtc:
    db 'err code=unavailable detail="RTC read failed"', 0
err_io_denied:
    db 'err code=denied detail="port not in allowlist"', 0
err_io_usage:
    db 'err code=bad_arg detail="usage: io.in port=HH"', 0
err_pci_bars_usage:
    db 'err code=bad_arg detail="usage: pci.bars bdf=BB.DD.F"', 0
err_pci_config_read_usage:
    db 'err code=bad_arg detail="usage: pci.config.read bdf=BB.DD.F offset=HH len=N"', 0
err_pci_config_read8_usage:
    db 'err code=bad_arg detail="usage: pci.config.read8 bdf=BB.DD.F offset=HH"', 0
err_pci_config_read16_usage:
    db 'err code=bad_arg detail="usage: pci.config.read16 bdf=BB.DD.F offset=HH"', 0
err_pci_config_read32_usage:
    db 'err code=bad_arg detail="usage: pci.config.read32 bdf=BB.DD.F offset=HH"', 0
err_pci_config_range:
    db 'err code=out_of_range detail="offset or len out of range"', 0
err_pci_config_typed_range:
    db 'err code=out_of_range detail="offset or alignment out of range"', 0
err_pci_cap_list_usage:
    db 'err code=bad_arg detail="usage: pci.cap.list bdf=BB.DD.F"', 0
err_pci_cap_read_usage:
    db 'err code=bad_arg detail="usage: pci.cap.read bdf=BB.DD.F cap=HH offset=HH len=N"', 0
err_pci_cap_read_range:
    db 'err code=out_of_range detail="cap, offset, or len out of range"', 0
err_pci_cap_not_found:
    db 'err code=unavailable detail="capability not found"', 0
err_pci_bar_read_usage:
    db 'err code=bad_arg detail="usage: pci.bar.read bdf=BB.DD.F bar=N offset=HH len=N"', 0
err_pci_mem_read_usage:
    db 'err code=bad_arg detail="usage: pci.mem.read bdf=BB.DD.F bar=N offset=HH len=N"', 0
err_pci_mem_read8_usage:
    db 'err code=bad_arg detail="usage: pci.mem.read8 bdf=BB.DD.F bar=N offset=HH"', 0
err_pci_mem_read16_usage:
    db 'err code=bad_arg detail="usage: pci.mem.read16 bdf=BB.DD.F bar=N offset=HH"', 0
err_pci_mem_read32_usage:
    db 'err code=bad_arg detail="usage: pci.mem.read32 bdf=BB.DD.F bar=N offset=HH"', 0
err_pci_absent:
    db 'err code=unavailable detail="no such function"', 0
err_pci_bar_absent:
    db 'err code=unavailable detail="BAR not present"', 0
err_pci_bar_non_io:
    db 'err code=denied detail="only I/O BAR reads are supported"', 0
err_pci_bar_range:
    db 'err code=out_of_range detail="bar, offset, or len out of range"', 0
err_pci_bar_port_range:
    db 'err code=out_of_range detail="I/O port range exceeds 16-bit space"', 0
err_pci_mem_non_mem:
    db 'err code=denied detail="only memory BAR reads are supported"', 0
err_pci_mem_unsupported:
    db 'err code=unavailable detail="unsupported memory BAR"', 0
err_pci_mem_addr_range:
    db 'err code=out_of_range detail="MMIO address exceeds 32-bit space"', 0
err_pci_mem_typed_range:
    db 'err code=out_of_range detail="bar, offset, or alignment out of range"', 0

; Help response (full line).
help_response:
    db 'ok primitives=help,describe,cpu.vendor,cpu.features,mem.query,mem.read,mem.read8,mem.read16,mem.read32,mem.read.seg,mem.read.seg8,mem.read.seg16,mem.read.seg32,rtc.now,ticks.since_boot,io.in,pci.scan,pci.config.read,pci.config.read8,pci.config.read16,pci.config.read32,pci.cap.list,pci.cap.read,pci.bars,pci.bar.read,pci.mem.read,pci.mem.read8,pci.mem.read16,pci.mem.read32', 0

; Schema table: (name_ptr, schema_line_ptr). NULL-terminated.
schema_table:
    dw  cmd_help,       sch_help
    dw  cmd_describe,   sch_describe
    dw  cmd_cpu_vendor, sch_cpu_vendor
    dw  cmd_cpu_feat,   sch_cpu_feat
    dw  cmd_mem_query,  sch_mem_query
    dw  cmd_mem_read,   sch_mem_read
    dw  cmd_mem_read8,  sch_mem_read8
    dw  cmd_mem_read16, sch_mem_read16
    dw  cmd_mem_read32, sch_mem_read32
    dw  cmd_mem_read_seg, sch_mem_read_seg
    dw  cmd_mem_read_seg8, sch_mem_read_seg8
    dw  cmd_mem_read_seg16, sch_mem_read_seg16
    dw  cmd_mem_read_seg32, sch_mem_read_seg32
    dw  cmd_rtc_now,    sch_rtc_now
    dw  cmd_ticks,      sch_ticks
    dw  cmd_io_in,      sch_io_in
    dw  cmd_pci_scan,   sch_pci_scan
    dw  cmd_pci_config_read, sch_pci_config_read
    dw  cmd_pci_config_read8, sch_pci_config_read8
    dw  cmd_pci_config_read16, sch_pci_config_read16
    dw  cmd_pci_config_read32, sch_pci_config_read32
    dw  cmd_pci_cap_list, sch_pci_cap_list
    dw  cmd_pci_cap_read, sch_pci_cap_read
    dw  cmd_pci_bars,   sch_pci_bars
    dw  cmd_pci_bar_read, sch_pci_bar_read
    dw  cmd_pci_mem_read, sch_pci_mem_read
    dw  cmd_pci_mem_read8, sch_pci_mem_read8
    dw  cmd_pci_mem_read16, sch_pci_mem_read16
    dw  cmd_pci_mem_read32, sch_pci_mem_read32
    dw  0

sch_help:       db 'ok name=help args=none returns=primitives=CSV', 0
sch_describe:   db 'ok name=describe args=NAME returns=schema-line', 0
sch_cpu_vendor: db 'ok name=cpu.vendor args=none returns="vendor=S family=N model=N stepping=N"', 0
sch_cpu_feat:   db 'ok name=cpu.features args=none returns="features=CSV (from CPUID leaf 1 EDX)"', 0
sch_mem_query:  db 'ok name=mem.query args=none returns="conv_kb=N ext_kb=N ext_blocks_64k=N"', 0
sch_mem_read:   db 'ok name=mem.read args="addr=H(1-4) len=N(1-256)" returns="addr=H len=N data=HEX" notes="reads bytes from segment 0; range may not cross offset ffff"', 0
sch_mem_read8:  db 'ok name=mem.read8 args="addr=H(1-4)" returns="addr=H width=8 value=HH" notes="reads one byte from segment 0"', 0
sch_mem_read16: db 'ok name=mem.read16 args="addr=H(1-4,aligned)" returns="addr=H width=16 value=HHHH" notes="reads one little-endian aligned word from segment 0"', 0
sch_mem_read32: db 'ok name=mem.read32 args="addr=H(1-4,aligned)" returns="addr=H width=32 value=HHHHHHHH" notes="reads one little-endian aligned dword from segment 0"', 0
sch_mem_read_seg: db 'ok name=mem.read.seg args="seg=H(0-ffff) offset=H(0-ffff) len=N(1-256)" returns="seg=H offset=H len=N data=HEX" notes="reads bytes through a real-mode segment:offset; range may not cross offset ffff"', 0
sch_mem_read_seg8: db 'ok name=mem.read.seg8 args="seg=H(0-ffff) offset=H(0-ffff)" returns="seg=H offset=H width=8 value=HH" notes="reads one byte through a real-mode segment:offset"', 0
sch_mem_read_seg16: db 'ok name=mem.read.seg16 args="seg=H(0-ffff) offset=H(0-ffff,aligned)" returns="seg=H offset=H width=16 value=HHHH" notes="reads one little-endian aligned word through a real-mode segment:offset"', 0
sch_mem_read_seg32: db 'ok name=mem.read.seg32 args="seg=H(0-ffff) offset=H(0-ffff,aligned)" returns="seg=H offset=H width=32 value=HHHHHHHH" notes="reads one little-endian aligned dword through a real-mode segment:offset"', 0
sch_rtc_now:    db 'ok name=rtc.now args=none returns="iso=YYYY-MM-DDTHH:MM:SS"', 0
sch_ticks:      db 'ok name=ticks.since_boot args=none returns="ms=N"', 0
sch_io_in:      db 'ok name=io.in args="port=H" returns="port=H value=H" allowlist=0x20,0x21,0x40,0x43,0x60,0x61,0x64,0x70,0x71,0x3f8,0x3f9,0x3fa,0x3fb,0x3fc,0x3fd,0x3fe,0x3ff', 0
sch_pci_scan:   db 'ok name=pci.scan args=none returns="devices=B.D.F:VVVV:DDDD:CC[,...]" scope="bus 0 + any PCI-to-PCI bridges reachable from it; class = base class byte"', 0
sch_pci_config_read: db 'ok name=pci.config.read args="bdf=BB.DD.F offset=H(0-ff) len=N(1-16)" returns="bdf=BB.DD.F offset=H len=N data=HEX" notes="reads PCI config-space bytes; absent functions return unavailable"', 0
sch_pci_config_read8: db 'ok name=pci.config.read8 args="bdf=BB.DD.F offset=H(0-ff)" returns="bdf=BB.DD.F offset=H width=8 value=HH" notes="reads one little-endian byte from PCI config space"', 0
sch_pci_config_read16: db 'ok name=pci.config.read16 args="bdf=BB.DD.F offset=H(0-ff,aligned)" returns="bdf=BB.DD.F offset=H width=16 value=HHHH" notes="reads one little-endian aligned word from PCI config space"', 0
sch_pci_config_read32: db 'ok name=pci.config.read32 args="bdf=BB.DD.F offset=H(0-ff,aligned)" returns="bdf=BB.DD.F offset=H width=32 value=HHHHHHHH" notes="reads one little-endian aligned dword from PCI config space"', 0
sch_pci_cap_list: db 'ok name=pci.cap.list args="bdf=BB.DD.F" returns="bdf=BB.DD.F caps=OFF:ID[,..] truncated=N malformed=N" notes="walks conventional PCI capability list; empty list returns caps=; malformed chains are bounded and flagged"', 0
sch_pci_cap_read: db 'ok name=pci.cap.read args="bdf=BB.DD.F cap=H(offset from pci.cap.list) offset=H(0-ff) len=N(1-16)" returns="bdf=BB.DD.F cap=H id=H offset=H len=N data=HEX" notes="cap must be present in the capability list; offset is relative to cap"', 0
sch_pci_bars:   db 'ok name=pci.bars args="bdf=BB.DD.F" returns="bdf=BB.DD.F bars=I:KIND[:BASE[:p|n]],..." kinds="none|io:BASE32|m32:BASE32:p|n|m64:BASE64:p|n|m64trunc:BASE32:p|n|mlt1:BASE32:p|n|rsv:BASE32:p|n" slots="6 for header-type 0, 2 for header-type 1, else 0" notes="m64 consumes I+1; m64trunc flags a self-contradictory 64-bit BAR on the last slot; bdf format matches pci.scan"', 0
sch_pci_bar_read: db 'ok name=pci.bar.read args="bdf=BB.DD.F bar=N offset=H(0-ff) len=N(1-16)" returns="bdf=BB.DD.F bar=N kind=io port=H offset=H len=N data=HEX" notes="reads I/O-space BARs only; memory BARs return denied"', 0
sch_pci_mem_read: db 'ok name=pci.mem.read args="bdf=BB.DD.F bar=N offset=H(0-ff) len=N(1-16)" returns="bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=H offset=H len=N data=HEX" notes="reads memory-space BARs only via flat FS; I/O BARs return denied; 64-bit BARs require high dword zero"', 0
sch_pci_mem_read8: db 'ok name=pci.mem.read8 args="bdf=BB.DD.F bar=N offset=H(0-ff)" returns="bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=H offset=H width=8 value=HH" notes="reads one little-endian byte from a memory BAR; I/O BARs return denied"', 0
sch_pci_mem_read16: db 'ok name=pci.mem.read16 args="bdf=BB.DD.F bar=N offset=H(0-ff,aligned)" returns="bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=H offset=H width=16 value=HHHH" notes="reads one little-endian aligned word from a memory BAR; I/O BARs return denied"', 0
sch_pci_mem_read32: db 'ok name=pci.mem.read32 args="bdf=BB.DD.F bar=N offset=H(0-ff,aligned)" returns="bdf=BB.DD.F bar=N kind=m32|m64|mlt1 addr=H offset=H width=32 value=HHHHHHHH" notes="reads one little-endian aligned dword from a memory BAR; I/O BARs return denied"', 0

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
mem_seg:        dw 0
mem_len:        dw 0
mem_width_bits: dw 0
mem_width_bytes: dw 0
mem_typed_usage_ptr: dw 0
feat_first:     db 0
io_value:       db 0
pci_bus:        db 0
pci_dev:        db 0
pci_fn:         db 0
pci_first:      db 0
pci_class:      db 0
pci_hdr:        db 0
pci_ids:        dd 0
pci_bus_todo:   times 32 db 0      ; 256-bit bitmap of buses still to scan
pci_cfg_offset: db 0
pci_cfg_len:    dw 0
pci_cfg_width_bits: dw 0
pci_cfg_usage_ptr: dw 0
pci_cap_ptr:    db 0
pci_cap_id:     db 0
pci_cap_target: db 0
pci_cap_offset: dw 0
pci_cap_eff_offset: dw 0
pci_cap_len:    dw 0
pci_cap_truncated: db 0
pci_cap_malformed: db 0
pci_nbars:      db 0
pci_pref:       db 0
pci_bar_lo:     dd 0
pci_bar_hi:     dd 0
pci_bar_idx:    db 0
pci_bar_offset: dw 0
pci_bar_len:    dw 0
pci_bar_port:   dw 0
pci_mem_addr:   dd 0
pci_mem_kind_ptr: dw 0
pci_mem_width_bits: dw 0
pci_mem_usage_ptr: dw 0
