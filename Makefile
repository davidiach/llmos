# =============================================================================
# llmos Makefile
# =============================================================================

AS      := nasm
QEMU    := qemu-system-i386

SRC_DIR    := src
BUILD_DIR  := build

BOOT_BIN   := $(BUILD_DIR)/boot.bin
KERNEL_BIN := $(BUILD_DIR)/kernel.bin
KERNEL_LST := $(BUILD_DIR)/kernel.lst
IMG        := $(BUILD_DIR)/llmos.img
CHECKSUMS  := $(BUILD_DIR)/SHA256SUMS
SECTOR_CHECK := $(BUILD_DIR)/kernel-sectors.ok

KERNEL_SECTORS   := 32
MAX_KERNEL_BYTES := $(shell expr $(KERNEL_SECTORS) \* 512)

# For `make run` the serial console is on stdio, and we silence VGA output
# so the terminal only shows the wire protocol (VGA mirror is still on the
# QEMU window if you remove -display none).
QEMU_ARGS  := -drive format=raw,if=floppy,file=$(IMG) -serial stdio -display none

.PHONY: all run run-gui debug clean check ci-check image-checksums size size-report size-map smoke ci-smoke test-bridge

all: $(IMG)

check: all test-bridge smoke

ci-check: all test-bridge ci-smoke

image-checksums: $(CHECKSUMS)
	@cd $(BUILD_DIR) && sha256sum -c $(notdir $(CHECKSUMS))

size: size-report

size-report: $(BOOT_BIN) $(KERNEL_BIN)
	@boot_sz=$$(wc -c < $(BOOT_BIN)); \
	  kernel_sz=$$(wc -c < $(KERNEL_BIN)); \
	  free=$$(expr $(MAX_KERNEL_BYTES) - $$kernel_sz); \
	  printf "boot:   %s B / 512 B\n" "$$boot_sz"; \
	  printf "kernel: %s B / %s B budget (%s B free)\n" \
	    "$$kernel_sz" "$(MAX_KERNEL_BYTES)" "$$free"

size-map: $(KERNEL_BIN)
	python3 tools/kernel_size_map.py \
	  --listing $(KERNEL_LST) \
	  --binary $(KERNEL_BIN) \
	  --budget $(MAX_KERNEL_BYTES)

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(SECTOR_CHECK): Makefile $(SRC_DIR)/boot.asm | $(BUILD_DIR)
	@sectors=$$(sed -n 's/^KERNEL_SECTORS[[:space:]]*equ[[:space:]]*\([0-9][0-9]*\).*/\1/p' $(SRC_DIR)/boot.asm); \
	  if [ "$$sectors" != "$(KERNEL_SECTORS)" ]; then \
	    printf "error: boot.asm KERNEL_SECTORS (%s) must match Makefile (%s)\n" \
	      "$$sectors" "$(KERNEL_SECTORS)"; \
	    exit 1; \
	  fi
	@printf "%s\n" "$(KERNEL_SECTORS)" > $@

$(BOOT_BIN): $(SRC_DIR)/boot.asm $(SECTOR_CHECK) | $(BUILD_DIR)
	$(AS) -f bin $< -o $@
	@sz=$$(wc -c < $@); \
	  if [ $$sz -ne 512 ]; then \
	    echo "error: boot.bin must be exactly 512 bytes (got $$sz)"; exit 1; \
	  fi

$(KERNEL_BIN): $(SRC_DIR)/kernel.asm Makefile | $(BUILD_DIR)
	$(AS) -f bin -l $(KERNEL_LST) $< -o $@
	@sz=$$(wc -c < $@); \
	  max=$(MAX_KERNEL_BYTES); \
	  if [ $$sz -gt $$max ]; then \
	    echo "error: kernel.bin is $$sz bytes, exceeds $$max-byte budget"; \
	    exit 1; \
	  fi

$(IMG): $(BOOT_BIN) $(KERNEL_BIN) Makefile
	@dd if=/dev/zero of=$@ bs=512 count=2880 status=none
	@dd if=$(BOOT_BIN)   of=$@ conv=notrunc               status=none
	@dd if=$(KERNEL_BIN) of=$@ conv=notrunc bs=512 seek=1 status=none
	@printf "built %s  (boot: %s B, kernel: %s B / %s B budget)\n" \
	  "$@" \
	  "$$(wc -c < $(BOOT_BIN))" \
	  "$$(wc -c < $(KERNEL_BIN))" \
	  "$(MAX_KERNEL_BYTES)"

$(CHECKSUMS): $(IMG) | $(BUILD_DIR)
	@cd $(BUILD_DIR) && sha256sum $(notdir $(IMG)) > $(notdir $@)

# Run with serial on stdio - what the bridge script will do.
run: $(IMG)
	$(QEMU) $(QEMU_ARGS)

# Run with VGA visible (separate window) + serial on stdio.
run-gui: $(IMG)
	$(QEMU) -drive format=raw,if=floppy,file=$(IMG) -serial stdio

debug: $(IMG)
	$(QEMU) $(QEMU_ARGS) -s -S

test-bridge:
	python3 -m unittest demo.test_bridge

smoke: $(IMG)
	@set -e; \
	tmpdir=$$(mktemp -d "$${TMPDIR:-/tmp}/llmos-smoke.XXXXXX"); \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	for t in demo/transcripts/*.llmos; do \
	  name=$${t##*/}; name=$${name%.llmos}; \
	  out="$$tmpdir/$$name.out"; \
	  printf "smoke %s\n" "$$name"; \
	  timeout 30 python3 demo/bridge.py --image $(IMG) script "$$t" > "$$out"; \
	  grep -q '^# llmos v0\.1 proto=1 primitives=29' "$$out"; \
	done; \
	echo "smoke transcripts passed"

ci-smoke: $(IMG)
	bash demo/ci_smoke.sh

clean:
	rm -rf $(BUILD_DIR)
