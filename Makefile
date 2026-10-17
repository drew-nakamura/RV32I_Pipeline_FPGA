# Cadence only. From the project root on nanoHUB:
#   make        batch run, writes CPU_TOP_tb.log
#   make gui    same run with SimVision
#
# Pass for the add test is this line in the log:
#   tohost store = 0x00000001
# SELFTEST FAIL is the old x30 check. add does not write x30.

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

IMEM ?= riscv-tests/build/imem.mem
DMEM ?= riscv-tests/build/dmem.mem
LOG  ?= CPU_TOP_tb.log

RTL := \
	rtl/CPU_pkg.sv \
	rtl/TWO_TO_ONE_MUX.sv \
	rtl/FOUR_TO_ONE_MUX.sv \
	rtl/ALU.sv \
	rtl/Branch_Condition_Generator.sv \
	rtl/Program_Counter.sv \
	rtl/IMEM.sv \
	rtl/Reg_File.sv \
	rtl/Control_Unit_Decoder.sv \
	rtl/Immediate_Generator.sv \
	rtl/PC_Decoder.sv \
	rtl/Jump_Branch_Address_Generator.sv \
	rtl/Forwarding_Unit.sv \
	rtl/HazardUnit.sv \
	rtl/CPU_TOP.sv \
	rtl/DMEM.sv \
	rtl/Interconnect.sv

TB := my-tests/tb/CPU_TOP_tb.sv

XRUN := xrun -64bit -sv -timescale 1ns/1ps -access +rwc -l $(LOG) \
	-top CPU_TOP_tb \
	-defparam CPU_TOP_tb.dut.IMEM.MEM_FILE=\"$(IMEM)\" \
	-defparam CPU_TOP_tb.data_memory.MEM_FILE=\"$(DMEM)\" \
	$(RTL) $(TB)

.PHONY: sim gui clean

sim:
	cd $(ROOT) && $(XRUN)

gui:
	cd $(ROOT) && $(XRUN) -gui

clean:
	cd $(ROOT) && rm -rf xcelium.d waves.shm xrun.history xrun.log $(LOG)
