# One program per RV32I instruction, except FENCE, ECALL, and EBREAK.
# Those three are the rest of the 40. FENCE is a nop on this pipeline.
# ECALL and EBREAK raise a trap; this core freezes instead of handling it.
TESTS := \
	add addi sub \
	and andi or ori xor xori \
	sll slli srl srli sra srai \
	slt slti sltu sltiu \
	lui auipc \
	beq bne blt bge bltu bgeu \
	jal jalr \
	lb lbu lh lhu lw \
	sb sh sw
