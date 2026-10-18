# Verilator elaboration check. Syntax and connections only; no simulate.
#
# Run from my-tests/:
#   make          # CPU_TOP, then MCU_WRAPPER
#   make lint-cpu # CPU_TOP only
#   make lint-mcu # MCU_WRAPPER (CPU + DMEM + I/O)

HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(HERE)/..)

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

VERILATOR := verilator --lint-only -Wall -Wno-fatal --timescale 1ns/1ps

.PHONY: lint lint-cpu lint-mcu
lint: lint-cpu lint-mcu

lint-cpu:
	$(VERILATOR) --top-module CPU_TOP $(CPU_RTL)

lint-mcu:
	$(VERILATOR) --top-module MCU_WRAPPER $(MCU_RTL)

.DEFAULT_GOAL := lint
