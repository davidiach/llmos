# =============================================================================
# llmos Makefile
# =============================================================================

AS      := nasm
QEMU    := qemu-system-i386

SRC_DIR    := src
BUILD_DIR  := build

BOOT_BIN   := $(BUILD_DIR)/boot.bin
KERNEL_BIN := $(BUILD_DIR)/kernel.bin
IMG        := $(BUILD_DIR)/llmos.img

KERNEL_SECTORS   := 32
MAX_KERNEL_BYTES := $(shell expr $(KERNEL_SECTORS) \* 512)

# For `make run` the serial console is on stdio, and we silence VGA output
# so the terminal only shows the wire protocol (VGA mirror is still on the
# QEMU window if you remove -display none).
QEMU_ARGS  := -drive format=raw,file=$(IMG) -serial stdio -display none

.PHONY: all run run-gui debug clean

all: $(IMG)

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(BOOT_BIN): $(SRC_DIR)/boot.asm | $(BUILD_DIR)
	$(AS) -f bin $< -o $@
	@sz=$$(wc -c < $@); \
	  if [ $$sz -ne 512 ]; then \
	    echo "error: boot.bin must be exactly 512 bytes (got $$sz)"; exit 1; \
	  fi

$(KERNEL_BIN): $(SRC_DIR)/kernel.asm | $(BUILD_DIR)
	$(AS) -f bin $< -o $@
	@sz=$$(wc -c < $@); \
	  max=$(MAX_KERNEL_BYTES); \
	  if [ $$sz -gt $$max ]; then \
	    echo "error: kernel.bin is $$sz bytes, exceeds $$max-byte budget"; \
	    exit 1; \
	  fi

$(IMG): $(BOOT_BIN) $(KERNEL_BIN)
	@dd if=/dev/zero of=$@ bs=512 count=2880 status=none
	@dd if=$(BOOT_BIN)   of=$@ conv=notrunc               status=none
	@dd if=$(KERNEL_BIN) of=$@ conv=notrunc bs=512 seek=1 status=none
	@printf "built %s  (boot: %s B, kernel: %s B / %s B budget)\n" \
	  "$@" \
	  "$$(wc -c < $(BOOT_BIN))" \
	  "$$(wc -c < $(KERNEL_BIN))" \
	  "$(MAX_KERNEL_BYTES)"

# Run with serial on stdio — what the bridge script will do.
run: $(IMG)
	$(QEMU) $(QEMU_ARGS)

# Run with VGA visible (separate window) + serial on stdio.
run-gui: $(IMG)
	$(QEMU) -drive format=raw,file=$(IMG) -serial stdio

debug: $(IMG)
	$(QEMU) $(QEMU_ARGS) -s -S

clean:
	rm -rf $(BUILD_DIR)
