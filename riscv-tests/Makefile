# Build RV32I riscv-tests into one image pair per test.
#
# Run in WSL from this directory:
#   make              # every name in TESTS
#   make addi         # just that test
#
# Each test writes:
#   build/<name>.imem.mem   word 0 is address 0x00000000
#   build/<name>.dmem.mem   word 0 is address 0x00003F60
#
# The names live in tests.mk. make builds every name. make addi builds one.

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
READELF := $(RISCV_PREFIX)readelf

BUILD := build
DMEM_BASE := 0x3F60

include tests.mk

CFLAGS := -march=rv32i -mabi=ilp32 -static -mcmodel=medany \
          -fvisibility=hidden -nostdlib -nostartfiles
INCLUDES := -Ienv/p -Iisa/macros/scalar
LDSCRIPT := env/p/link.ld

.PHONY: all clean $(TESTS)
# Keep the .elf and .bin files. Make would otherwise delete them as temporaries.
.SECONDARY:
all: $(foreach t,$(TESTS),$(BUILD)/$(t).imem.mem $(BUILD)/$(t).dmem.mem $(BUILD)/$(t).dump)

# `make addi` builds only that name. The % is the name from TESTS.
$(TESTS): %: $(BUILD)/%.imem.mem $(BUILD)/%.dmem.mem $(BUILD)/%.dump

$(BUILD):
	mkdir -p $(BUILD)

# isa/rv32ui/add.S includes isa/rv64ui/add.S. $< is the rv32ui file.
$(BUILD)/%.elf: isa/rv32ui/%.S isa/rv64ui/%.S env/p/riscv_test.h $(LDSCRIPT) isa/macros/scalar/test_macros.h | $(BUILD)
	$(CC) $(CFLAGS) $(INCLUDES) -T$(LDSCRIPT) $< -o $@

$(BUILD)/%.dump: $(BUILD)/%.elf
	$(OBJDUMP) -d $< > $@

$(BUILD)/%.text.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary -j .text.init -j .text $< $@

$(BUILD)/%.data.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary -j .tohost -j .data $< $@

$(BUILD)/%.imem.mem: $(BUILD)/%.text.bin
	od -An -tx4 -v -w4 $< | sed 's/ //g' > $@

# $* is the test name, so this reads build/addi.elf when the target is addi.
$(BUILD)/%.dmem.mem: $(BUILD)/%.data.bin $(BUILD)/%.elf
	addr=$$($(READELF) -S -W $(BUILD)/$*.elf | awk '/\.tohost/ {print $$5}'); \
	pad=$$((0x$$addr - $(DMEM_BASE))); \
	{ dd if=/dev/zero bs=1 count=$$pad status=none; cat $<; } \
	  | od -An -tx4 -v -w4 | sed 's/ //g' > $@

clean:
	rm -rf $(BUILD)
