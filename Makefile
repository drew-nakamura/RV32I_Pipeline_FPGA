# Cadence only. From the project root on nanoHUB:
#   make                 run every name in riscv-tests/tests.mk
#   make TEST=addi       run one
#   make gui TEST=addi   that one test in SimVision
#
# The last line is the score, for example "2/2 tests passed".
# A passing test prints "RISCV-TEST PASS" in logs/<name>.log.

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

include $(ROOT)/riscv-tests/tests.mk

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

TB := my-tests/tb/riscv_test_CPU_TOP_tb.sv

.PHONY: sim gui clean

sim:
	@mkdir -p $(ROOT)/logs
	@pass=0; total=0; \
	list="$(if $(TEST),$(TEST),$(TESTS))"; \
	for t in $$list; do \
		total=$$((total + 1)); \
		echo "===== $$t ====="; \
		cd $(ROOT) && xrun -64bit -sv -timescale 1ns/1ps -access +rwc \
			-top riscv_test_CPU_TOP_tb \
			-l logs/$$t.log \
			-defparam riscv_test_CPU_TOP_tb.dut.IMEM.MEM_FILE=\"riscv-tests/build/$$t.imem.mem\" \
			-defparam riscv_test_CPU_TOP_tb.data_memory.MEM_FILE=\"riscv-tests/build/$$t.dmem.mem\" \
			$(RTL) $(TB); \
		if grep -q "RISCV-TEST PASS" $(ROOT)/logs/$$t.log; then \
			echo "$$t PASS"; \
			pass=$$((pass + 1)); \
		else \
			echo "$$t FAIL  (see logs/$$t.log)"; \
		fi; \
	done; \
	echo "$$pass/$$total tests passed"; \
	test "$$pass" -eq "$$total"

gui:
	@test -n "$(TEST)" || (echo "usage: make gui TEST=addi" && exit 1)
	cd $(ROOT) && xrun -64bit -sv -timescale 1ns/1ps -access +rwc -gui \
		-top riscv_test_CPU_TOP_tb \
		-l logs/$(TEST).log \
		-defparam riscv_test_CPU_TOP_tb.dut.IMEM.MEM_FILE=\"riscv-tests/build/$(TEST).imem.mem\" \
		-defparam riscv_test_CPU_TOP_tb.data_memory.MEM_FILE=\"riscv-tests/build/$(TEST).dmem.mem\" \
		$(RTL) $(TB)

clean:
	cd $(ROOT) && rm -rf xcelium.d waves.shm xrun.history xrun.log logs
