# Verilator elaboration check. Syntax and connections only; no simulate.
#
# From the repo root, in WSL:
#   make -C my-tests/sw          # MCU_WRAPPER + CPU + DMEM + I/O
#   make -C my-tests/sw lint-cpu # CPU_TOP only

# Makefile lives in my-tests/sw/. RTL stays at the repo root.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

CPU_RTL := \
	$(ROOT)/rtl/CPU_pkg.sv \
	$(ROOT)/rtl/TWO_TO_ONE_MUX.sv \
	$(ROOT)/rtl/FOUR_TO_ONE_MUX.sv \
	$(ROOT)/rtl/ALU.sv \
	$(ROOT)/rtl/Branch_Condition_Generator.sv \
	$(ROOT)/rtl/Program_Counter.sv \
	$(ROOT)/rtl/IMEM.sv \
	$(ROOT)/rtl/Reg_File.sv \
	$(ROOT)/rtl/Control_Unit_Decoder.sv \
	$(ROOT)/rtl/Immediate_Generator.sv \
	$(ROOT)/rtl/PC_Decoder.sv \
	$(ROOT)/rtl/Jump_Branch_Address_Generator.sv \
	$(ROOT)/rtl/Forwarding_Unit.sv \
	$(ROOT)/rtl/HazardUnit.sv \
	$(ROOT)/rtl/CPU_TOP.sv

MCU_RTL := \
	$(CPU_RTL) \
	$(ROOT)/rtl/DMEM.sv \
	$(ROOT)/rtl/Interconnect.sv \
	$(ROOT)/rtl/BCD.sv \
	$(ROOT)/rtl/CathodeDriver.sv \
	$(ROOT)/rtl/SevSegDisp.sv \
	$(ROOT)/rtl/MCU_WRAPPER.sv

.PHONY: lint lint-cpu lint-mcu
lint: lint-mcu

lint-cpu:
	verilator --lint-only -Wall -Wno-fatal --top-module CPU_TOP --timescale 1ns/1ps $(CPU_RTL)

lint-mcu:
	verilator --lint-only -Wall -Wno-fatal --top-module MCU_WRAPPER --timescale 1ns/1ps $(MCU_RTL)

.DEFAULT_GOAL := lint
