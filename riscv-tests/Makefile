# Build one RV32I test, add, into the two images CPU_TOP_tb loads.
#
# Run in WSL from this directory:
#   make
#
# build/imem.mem   word 0 is address 0x00000000  (IMEM)
# build/dmem.mem   word 0 is address 0x00003F60  (DMEM)
#
# ./configure would replace this file with the upstream suite Makefile.

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
READELF := $(RISCV_PREFIX)readelf

BUILD := build

# DMEM.sv indexes (address - 0x3F60) >> 2, so the hex file starts there.
DMEM_BASE := 0x3F60

# rv32i/ilp32: 32-bit integer instructions, 32-bit registers and pointers.
# nostdlib/nostartfiles: no C runtime. _start comes from riscv_test.h.
# medany: la is auipc+addi, so it still works with tohost up at 0x3F80.
CFLAGS := -march=rv32i -mabi=ilp32 -static -mcmodel=medany \
          -fvisibility=hidden -nostdlib -nostartfiles

INCLUDES := -Ienv/p -Iisa/macros/scalar
LDSCRIPT := env/p/link.ld

.PHONY: all clean
all: $(BUILD)/imem.mem $(BUILD)/dmem.mem $(BUILD)/add.dump

$(BUILD):
	mkdir -p $(BUILD)

# isa/rv32ui/add.S is a stub that includes isa/rv64ui/add.S.
$(BUILD)/add.elf: isa/rv32ui/add.S isa/rv64ui/add.S env/p/riscv_test.h $(LDSCRIPT) isa/macros/scalar/test_macros.h | $(BUILD)
	$(CC) $(CFLAGS) $(INCLUDES) -T$(LDSCRIPT) $< -o $@

# Disassembly, so the hex words can be checked against the source.
$(BUILD)/add.dump: $(BUILD)/add.elf
	$(OBJDUMP) -d $< > $@

# Instruction bytes only. The gap up to 0x3F80 is data, not fetched as code.
$(BUILD)/text.bin: $(BUILD)/add.elf
	$(OBJCOPY) -O binary -j .text.init -j .text $< $@

# objcopy starts this file at .tohost (0x3F80), not at the DMEM base.
$(BUILD)/data.bin: $(BUILD)/add.elf
	$(OBJCOPY) -O binary -j .tohost -j .data $< $@

# One 8-digit hex word per line. $readmemh treats line 0 as IMEM[0].
$(BUILD)/imem.mem: $(BUILD)/text.bin
	od -An -tx4 -v -w4 $< | sed 's/ //g' > $@

# Prepend zeros so line 0 is address 0x3F60. .tohost then lands on word 8.
$(BUILD)/dmem.mem: $(BUILD)/data.bin $(BUILD)/add.elf
	addr=$$($(READELF) -S -W $(BUILD)/add.elf | awk '/\.tohost/ {print $$5}'); \
	pad=$$((0x$$addr - $(DMEM_BASE))); \
	{ dd if=/dev/zero bs=1 count=$$pad status=none; cat $<; } \
	  | od -An -tx4 -v -w4 | sed 's/ //g' > $@

clean:
	rm -rf $(BUILD)
