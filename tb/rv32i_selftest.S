#=============================================================================
# rv32i_selftest.S -- self-checking RV32I verification program
#
# Target:  CPU_TOP.sv (student 5-stage RV32I pipeline, RV32I base only)
# Author:  written for Drew Nakamura's 5_Stage_Pipeline repo
# Date:    2026-09-18
#
# This program tests the CPU against the RISC-V Unprivileged ISA spec, not
# against the RTL.  Expected values were derived from the spec and then
# confirmed on an independent reference interpreter (see BUILD NOTES at the
# bottom of this file).  Where the RTL and the spec disagree, the spec wins
# and the test is expected to fail -- that is the point.
#
#=============================================================================
# STEP 1 FINDINGS -- read CPU_TOP.sv and every module it instantiates
#=============================================================================
#
# (1) PIPELINE DEPTH AND STAGE NAMES
#     Five stages, named in CPU_pkg::stage_e as
#         FETCH -> DECODE -> EXECUTE -> MEMORY -> WRITE_BACK
#     Pipeline registers: if_id_q, id_ex_q, ex_mem_q, mem_wb_q.
#
#     NON-OBVIOUS: per the 9/2/2026 decision comment in IMEM.sv, the IMEM
#     output register `ir` *is* the real IF/ID instruction register.  The
#     DECODE stage reads `ir` directly (REG_FILE.adr1 = ir[19:15],
#     Control_Unit_Decoder.opcode = ir[6:0], Immediate_Generator.imm =
#     ir[31:7]).  The explicit `if_id_q` register is written every cycle but
#     only `if_id_q.PC` is ever consumed -- it feeds Program_Counter's
#     PC_PLUS_FOUR input.  Consequence: FORW_STALL_IF_ID and
#     Hazard_FLUSH_IF_ID act on the PC, NOT on the instruction in DECODE.
#
# (2) WHERE CONTROL TRANSFERS RESOLVE, AND HOW BIG THE SHADOW IS
#     PC_Decoder is driven from id_ex_q.{branch_i,jal_i,jalr_i} and from
#     Branch_Condition_Generator, which reads id_ex_q.rs1/rs2.  So branches,
#     JAL and JALR all resolve in EXECUTE.
#
#     PC is purely combinational off PC_SEL, and IMEM is synchronous.  In the
#     cycle the branch sits in EX, the redirected address is already the one
#     IMEM latches.  Only the single instruction sitting in DECODE enters the
#     shadow; the instruction after that is never fetched.  Hence:
#         BR_SHADOW = 1
#     There is no branch predictor and no branch delay slot: the machine is
#     statically not-taken (it keeps fetching sequentially) and squashes the
#     one shadow instruction via Hazard_FLUSH_ID_EX.
#
# (3) FORWARDING PATHS (Forwarding_Unit.sv)
#     Exactly two sources, both landing in EXECUTE:
#       EX/MEM -> EX   ex_mem_q.ALU_result, select 2'b01.
#                      Enabled by MEM_REG_WE && !MEM_DMEM_RDEN.
#       MEM/WB -> EX   mem_wb_q.REG_write_data, select 2'b10.
#                      Enabled by WB_REG_WE && WB_DMEM_RDEN -- note the
#                      RDEN term: this path fires for LOADS ONLY.
#     There is no forwarding into DECODE and no WB->ID register-file bypass.
#
#     Which operands each path feeds:
#       srcA_REAL (Forwarding_srcA_MUX) -> ALU srcA *and* the JALR base
#                  (Jump_Branch_Address_Generator.rs1 = srcA_REAL).
#       srcB_REAL (Forwarding_srcB_MUX) -> ALU srcB only.
#       branch comparator -- NOT forwarded (reads id_ex_q.rs1/rs2 raw).
#       store data        -- NOT forwarded (DATA_OUT = id_ex_q.rs2 raw).
#       store address     -- forwarded, because it is ALU_result.
#     Both forwarding muxes sit *after* the srcA/srcB select muxes, so a
#     forward can overwrite an immediate or a PC operand.  Level 8 tests 817
#     and 818 target exactly that.
#
# (4) REGISTER FILE READ/WRITE TIMING
#     Neither.  There is no half-cycle write-then-read and no WB->ID bypass.
#     REG_FILE's write port is driven from ex_mem_q (en = ex_mem_q.RF_WE,
#     w_adr = ex_mem_q.reg_write_addr, w_data = the MEM-stage result mux), so
#     a result is committed on the clock edge that ENDS the MEMORY stage.
#     Reads are combinational.  Working the stage occupancy out:
#         producer in MEM  ->  consumer at distance 2 is in DECODE that same
#         cycle and reads the OLD value; the consumer at distance 3 is the
#         first one to read the new value from the register file.
#     x0 is handled correctly inside REG_FILE (writes gated on w_adr != 0,
#     reads forced to 0).
#
# (5) WHAT THE HAZARD LOGIC DOES
#     Two separate units.
#       Forwarding_Unit  -- RAW hazards.  Forwards where it can.  For a
#         load-use pair (consumer in EX, load in MEM) it instead asserts
#         STALL_IF_ID + STALL_ID_EX + FLUSH_EX_MEM.  Intended cost: a
#         ONE-cycle load-use stall.  No other stall condition exists
#         anywhere in the design -- no multi-cycle ops, no memory wait
#         states, no structural hazards.
#       HazardUnit       -- control hazards.  Asserts Hazard_FLUSH_IF_ID and
#         Hazard_FLUSH_ID_EX to squash the branch/jump shadow.
#
# (6) MEMORY MAP
#     Reset PC            0x00000000   (Program_Counter forces PC='0 on RST)
#     Instruction memory  0x00000000.. , word addressed, separate from data
#                         memory (Harvard).  The array is 8192 words (32 KiB)
#                         and Interconnect.sv treats everything <= 0x7FFF as
#                         IMEM, so 32 KiB is the intended size.
#     Data memory         0x00008000..0x00009FFF per Interconnect.sv
#                         (`address > 0x7FFF` and not `> 0x9FFF`).
#     MMIO                0x11000000 SWITCHES (r), 0x11000020 LEDS (w),
#                         0x11000040 SSEG (w), 0x11000080 BUTTONS (r).
#                         These live in Interconnect/OTTER_Wrapper, NOT in
#                         CPU_TOP.
#     tohost              Does not exist.  See ASSUMPTION A4 below for the
#                         surrogate this program uses.
#
# (7) SUB-WORD ACCESS, SIGN EXTENSION, MISALIGNMENT
#     Byte enables are done in DMEM.sv by a case on {mem_size, byteOffset},
#     writing only the selected lane(s) of the addressed word.  mem_size is
#     ir[13:12] and mem_sign is ir[14], both carried down the pipe, so
#     00=byte, 01=half, 10=word.
#     Load sign extension happens in DMEM.sv, combinationally, in the
#     {mem_sign, mem_size, byteOffset} case -- LB/LH replicate the top bit,
#     LBU/LHU zero-fill.
#     Misalignment: there is no trap and no exception mechanism of any kind.
#     SW at offsets 1-3 and SH at offset 3 simply have no case item, so the
#     write is silently dropped and the load returns the `default: 0`.
#     This program therefore only ever issues naturally aligned accesses.
#
# (8) FENCE / ECALL / EBREAK
#     None of the three is decoded.  CPU_pkg::decode_instr_name returns
#     UNKNOWN and Control_Unit_Decoder falls into its `default:` branch,
#     which drives EVERY output to 'X -- including RF_WE, memWE, branch_i,
#     jal_i and jalr_i.  PC_Decoder's `unique case` then produces PC_SEL='X
#     and Program_Counter produces PC='X.
#     So they are not implemented, not NOPs, not trapped, and not a halt:
#     they poison the program counter and end the run.  Level 7 is therefore
#     OMITTED and guarded behind ENABLE_LEVEL7 = 0.  See Level 7 below.
#
# (9) ISOLATION CONSTANTS
#     SAFE_GAP  = 2   From (4): the first distance at which a consumer reads
#                     its producer's value out of the register file with no
#                     forwarding path and no stall involved is distance 3,
#                     i.e. 2 independent instructions in between.
#     BR_SHADOW = 1   From (2): exactly one instruction is fetched into the
#                     shadow of a taken branch, JAL or JALR.
#
# (10) HOW INSTRUCTION MEMORY IS INITIALIZED
#     IMEM.sv:  $readmemh("imem.mem", instruction_memory, 0, 8191)
#     So: a file literally named `imem.mem`, in the simulator's working
#     directory, WORD addressed -- one 32-bit big-endian hex word per line,
#     8 hex digits, no address tags, index 0 == PC 0x00000000.  The array is
#     8192 words, so pad the file to 8192 lines to keep unfetched words from
#     reading as X.  DMEM.sv likewise wants `ram.mem`, 2048 words.
#     The BUILD NOTES at the bottom of this file generate both.
#
#=============================================================================
# ASSUMPTIONS MADE (each is a .equ so it is one edit to change)
#=============================================================================
# A1  IMEM_BASE = 0.  Program_Counter clears PC on reset and nothing offsets
#     it, so the reset vector is 0x0 and the program is linked there.
# A2  DMEM_BASE = 0x8000, and this program confines itself to
#     0x8000..0x87FF.  Interconnect.sv decodes 0x8000..0x9FFF, but DMEM.sv's
#     `address` port is only [10:0] and it indexes with address[10:2], so
#     only 512 words are actually reachable and the map aliases every 2 KiB.
#     0x8000..0x87FF is the largest window that is unambiguous under BOTH
#     readings, so every data access here lives inside it.  If the port is
#     widened, raise DMEM_LIMIT.
# A3  The whole program is one .text section, assembled and linked flat with
#     no relaxation, so `la` is always exactly LUI+ADDI (2 instructions).
# A4  There is no tohost.  TOHOST_ADDR = 0x11000100 is an address that
#     Interconnect.sv decodes into the MMIO range but assigns to no device,
#     so a store there has no side effect while still being visible on
#     CPU_TOP's WE / DATA_ADDRESS / DATA_OUT pins.  A core-level testbench
#     can watch for `WE && DATA_ADDRESS == TOHOST_ADDR` to catch the pass
#     signature without needing to peek inside the register file.  Set
#     TOHOST_EN = 0 to drop it.
# A5  ENABLE_LEVEL7 = 0 because of finding (8).  Turning it on will hang the
#     machine, not fail a test.
#
#=============================================================================
# REGISTER CONVENTION
#=============================================================================
#   x0        zero (its hardwiring is itself under test, tests 5 / 303)
#   x1 - x27  free for tests.  x1/x2/x3 are the scratch registers used by the
#             TI / TR / TB* case macros, so a test that needs a value to
#             survive a macro call keeps it in x4..x27.
#   x28       expected value for the check in progress
#   x29       sub-check index within the current test (1, 2, 3, ...)
#   x30       fail code: 0 while running, the test number on failure, or the
#             PASS signature 0x600D0000 on success
#   x31       progress: the number of the test currently executing
#
#   x2 doubles as the stack pointer for the recursive test (1005) only, after
#   every test that uses x2 as scratch is done with it.
#
#=============================================================================
# HOW TO READ THE RESULT
#=============================================================================
#   Run until the PC stops changing, then look at three registers.
#
#   Parked in pass_loop:
#       x30 == 0x600D0000  and  x31 == TOTAL_TESTS
#       Every test passed.  If TOHOST_EN, the same signature was also stored
#       to TOHOST_ADDR, so `grep` the bus trace instead if you prefer.
#
#   Parked in fail_loop:
#       x30 == the number of the test that failed
#       x29 == which sub-check inside that test failed (1-based)
#       x31 == the same test number (it is set at the top of every test)
#       The leading digits of x30 name the area:
#         1..99  bootstrap      100s I-type/LUI/AUIPC   200s R-type
#         300s   register file  400s branches           500s jumps
#         600s   load/store     700s system (omitted)   800s forwarding
#         900s   hazards        1000s combined programs
#       x30 == 99 is special: it means control fell out of pass_loop, i.e.
#       both JAL and BEQ failed to loop, so nothing above can be trusted.
#
#   Parked anywhere else, or PC = X, or PC running away:
#       Control flow itself is broken.  Every fail stub ends in
#       `jal x0, fail_loop`, so a machine whose JAL does not work cannot
#       report a failure -- it wanders instead.  That is itself the
#       diagnosis.  Each loop is backed up by a `beq x0, x0, self` so that a
#       broken JAL alone still parks the machine.
#
#=============================================================================
# TEST INDEX
#=============================================================================
#  #     Name                                          Lvl  Depends on
#  ----  --------------------------------------------  ---  ----------------
#     1  ADDI small positive + checker bootstrap         0  --
#     2  NOP has no architectural effect                 0  1
#     3  ADDI negative immediate (sign extension)        0  1
#     4  ADDI zero immediate / register move             0  1
#     5  x0 is hardwired to zero                         0  1
#     6  BEQ taken, exact landing                        0  1,5
#     7  BEQ not taken                                   0  1,6
#     8  BNE taken, exact landing                        0  1,5
#     9  BNE not taken                                   0  1,8
#    10  JAL x0 forward transfer, exact landing          0  1,6,8
#   100  LUI shifts its immediate left by 12             1  1,3,8
#   101  LUI with 0xFFFFF                                1  3,100
#   102  LUI clears the low 12 bits of rd                1  100
#   103  ADDI at both immediate extremes                 1  1,3,100
#   104  ADDI wraparound at 32-bit boundaries            1  100,103
#   105  LUI+ADDI with a borrowing low part              1  100,103
#   106  SLTI signed comparison                          1  100,104
#   107  SLTIU unsigned comparison                       1  100,104
#   108  SLTI and SLTIU must disagree                    1  106,107
#   109  XORI with a sign-extended immediate             1  100,104
#   110  ORI with a sign-extended immediate              1  100,104
#   111  ANDI with a sign-extended immediate             1  100,104
#   112  SLLI by 0, 1 and 31                             1  100,104
#   113  SRLI by 0, 1 and 31                             1  100,104
#   114  SRAI by 0, 1, 4 and 31 on negatives             1  100,104
#   115  SRAI and SRLI must disagree on negatives        1  113,114
#   116  AUIPC with immediate 0 yields the PC            1  100,104
#   117  AUIPC with a nonzero immediate                  1  116
#   200  ADD of two registers                            2  1,100
#   201  ADD wraparound and negative operands            2  200
#   202  SUB of two registers                            2  200
#   203  SUB is not commutative                          2  202
#   204  SLL by a register amount, low 5 bits only       2  112,200
#   205  SRL by a register amount                        2  113,204
#   206  SRA by a register amount on negatives           2  114,204
#   207  SRA and SRL must disagree on negatives          2  205,206
#   208  SLT signed comparison                           2  106,200
#   209  SLTU unsigned comparison                        2  107,200
#   210  SLT and SLTU must disagree                      2  208,209
#   211  XOR of two registers                            2  109,200
#   212  OR of two registers                             2  110,200
#   213  AND of two registers                            2  111,200
#   214  ADD/SUB/AND with rd == rs1 == rs2               2  200,202,213
#   215  rd, rs1 and rs2 all the same register           2  200,202,211,214
#   216  the difference of two AUIPCs is their distance  2  116,202
#   300  every register x1..x27 holds a unique pattern   3  1,100
#   301  x28..x31 hold unique patterns                   3  300
#   302  one register read through both ports at once    3  300
#   303  x0 write-gating across every instruction form   3  5,300
#   400  BEQ taken and not taken on equal/unequal        4  6,7
#   401  BNE taken and not taken                         4  8,9
#   402  BLT signed, including across zero               4  106,400
#   403  BGE signed, including the equal case            4  402
#   404  BLTU unsigned, 0xFFFFFFFF is large              4  107,400
#   405  BGEU unsigned, including the equal case         4  404
#   406  BLT and BLTU must disagree                      4  402,404
#   407  BGE and BGEU must disagree                      4  403,405
#   408  backward branch closing a counted loop          4  400
#   409  branch over a long distance, both directions    4  400
#   410  a branch writes no register                     4  303,400
#   500  JAL writes PC+4 into rd                         5  10,116,117
#   501  JAL with rd = x0 discards the link              5  5,303,500
#   502  backward JAL                                    5  500
#   503  JALR with a positive offset                     5  104,500
#   504  JALR with a negative offset                     5  503
#   505  JALR clears bit 0 of the target                 5  503
#   506  JALR with rd == rs1                             5  503
#   507  call and return                                 5  500,503
#   508  nested call and return                          5  507
#   600  SW then LW round trip                           6  100,200
#   601  positive and negative displacements             6  600
#   602  adjacent words do not alias                     6  600
#   603  SB at all four byte offsets                     6  600
#   604  SB writes only the byte it names                6  603
#   605  SH at both aligned halfword offsets             6  603
#   606  LB sign extends, in every lane                  6  600
#   607  LBU zero extends, in every lane                 6  606
#   608  LH and LHU on 0x8000, in both halves            6  606,607
#   609  a load into x0 is discarded                     6  303,600
#   610  a store does not disturb its neighbour          6  603,604
#   700  FENCE is inert          (omitted, ENABLE_LEVEL7) 7  600
#   800  EX/MEM -> EX at distance 1, rs1                 8  200,600
#   801  EX/MEM -> EX at distance 1, rs2                 8  800
#   802  both operands from one producer                 8  800,801
#   803  two operands from two producers                 8  802
#   804  distance 2, rs1                                 8  800
#   805  distance 2, rs2                                 8  804
#   806  distance 3 needs no forwarding (SAFE_GAP)       8  200
#   807  with two writes in flight, newest wins          8  800,804
#   808  a discarded x0 write is never forwarded         8  5,303,800
#   809  forwarding into store data                      8  600,800
#   810  forwarding into a store address                 8  809
#   811  forwarding into the branch comparator           8  400,800
#   812  forwarding into the JALR base                   8  503,800
#   813  forwarding a LUI result                         8  100,800
#   814  forwarding an AUIPC result                      8  116,813
#   815  forwarding a JAL link value                     8  500,813
#   816  forwarding a JALR link value                    8  503,815
#   817  an immediate is not replaced by a forward       8  103,112,800
#   818  a U-type constant is not replaced               8  100,116,813
#   819  no forward from an instruction with no rd       8  600,800
#   820  no forward from a branch                        8  410,819
#   900  load-use at distance 1, rs1                     9  600,800
#   901  load-use at distance 1, rs2                     9  900
#   902  load-use at distance 1, both operands           9  900,901
#   903  load feeding store data                         9  809,900
#   904  load feeding a store address                    9  810,900
#   905  load feeding the branch comparator              9  811,900
#   906  load feeding the JALR base                      9  812,900
#   907  load feeding the next load's address            9  904
#   908  load-use at distance 2                          9  900
#   909  load-use at distance 3                          9  600,806
#   910  a load into x0, then an immediate use of x0     9  609,808
#   911  two loads into one register, then a use         9  807,900
#   912  register write in a taken branch's shadow       9  400
#   913  memory write in a taken branch's shadow         9  600,912
#   914  register write in a JAL's shadow                9  10,912
#   915  memory write in a JAL's shadow                  9  913,914
#   916  register and memory writes in a JALR shadow     9  503,914,915
#   917  a branch at the target of a branch              9  400,912
#   918  a JAL at the target of a JAL                    9  10,917
#   919  a taken branch behind a load-use stall          9  900,912
#   920  a not-taken branch with immediate dependents    9  800,912
#  1000  sum of 1..10 in a counted loop                 10  404,800,920
#  1001  fill an array, then sum it back                10  600,900,1000
#  1002  signed minimum and maximum of an array         10  402,403,1001
#  1003  byte-at-a-time copy between two buffers        10  603,607,1001
#  1004  length of a NUL-terminated string              10  607,905,1000
#  1005  bubble sort of six words                       10  1002,1003
#  1006  multiply by shift and add                      10  110,112,113,1000
#  1007  a subroutine called from inside a loop         10  508,1006
#=============================================================================

#-----------------------------------------------------------------------------
# Tunables (Step 1 findings and assumptions, in one place)
#-----------------------------------------------------------------------------
    .equ SAFE_GAP,      2               # finding (9)
    .equ BR_SHADOW,     1               # finding (9)

    .equ IMEM_BASE,     0x00000000      # A1
    .equ DMEM_BASE,     0x00008000      # A2
    .equ DMEM_LIMIT,    0x000087FF      # A2

    .equ TOHOST_EN,     1               # A4
    .equ TOHOST_ADDR,   0x11000100      # A4
    .equ ENABLE_LEVEL7, 0               # A5

    .equ PASS_SIG,      0x600D0000

# The count the pass sequence leaves in x31.  Tracks ENABLE_LEVEL7 so that
# turning level 7 on does not silently invalidate the sentinel.
    .equ TOTAL_TESTS,   130+ENABLE_LEVEL7

# Data-memory scratch map.  Every region is inside A2's safe window and none
# of them overlap; levels 8, 9 and 10 each get their own so that a stray
# address in one level cannot corrupt the setup of another.
    .equ M6,            DMEM_BASE+0x000 # level 6 scratch,  16 words
    .equ M8,            DMEM_BASE+0x040 # level 8 scratch,   8 words
    .equ M9,            DMEM_BASE+0x060 # level 9 scratch,  16 words
    .equ M10,           DMEM_BASE+0x0A0 # level 10 scratch, 16 words
    .equ M10B,          DMEM_BASE+0x0E0 # level 10 copy destination, 8 words
    .equ STACK_TOP,     DMEM_BASE+0x7F0 # level 10 recursion stack, grows down

#-----------------------------------------------------------------------------
# Macros
#
# Everything in levels 0-7 goes through these, so the isolation discipline is
# enforced structurally instead of by hand: there is no way to write a
# producer/consumer pair in those levels without PAD landing in between.
#
# NOTE on argument style: GNU as splits macro arguments on whitespace as well
# as commas, so every expression passed as an argument is written with no
# spaces in it (`0x100+\r*0x11`, not `0x100 + \r * 0x11`).
#-----------------------------------------------------------------------------
    .macro PAD
    .rept SAFE_GAP
    nop
    .endr
    .endm

    .macro PAD_BR
    .rept BR_SHADOW
    nop
    .endr
    .endm

    .macro TEST_START n
    li   x31, \n
    li   x29, 0
    PAD
    .endm

# Fail if reg != expected.  x28 is loaded BEFORE x29 on purpose: that puts an
# instruction the checker does not care about between the expected value and
# the compare, and it keeps the ADDI that materialises x28 from ever sitting
# one slot behind a write to a register whose number could collide with the
# low 5 bits of its own immediate.
    .macro CHECK reg, expected, sub, faillabel
    li   x28, \expected
    li   x29, \sub
    PAD
    bne  \reg, x28, \faillabel
    PAD_BR
    .endm

# Fail if reg == notexpected.  This is the cross-check half of every test: it
# is what stops a "the instruction never wrote anything" bug from passing,
# because two registers that were both never written compare equal.
    .macro CHECK_NE reg, notexpected, sub, faillabel
    li   x28, \notexpected
    li   x29, \sub
    PAD
    beq  \reg, x28, \faillabel
    PAD_BR
    .endm

# Fail if reg != the absolute address of addrexpr.  Used wherever the value
# under test is a PC: AUIPC results and JAL/JALR link values are compared
# against an address the assembler computed, never against another copy of
# the same instruction.
    .macro CHECK_A reg, addrexpr, sub, faillabel
    la   x28, \addrexpr
    li   x29, \sub
    PAD
    bne  \reg, x28, \faillabel
    PAD_BR
    .endm

# Fail if reg == the absolute address of addrexpr.  The cross-check half of
# CHECK_A: a link register holding the jump's own address, or the target
# address, instead of the return address is the classic off-by-one here, and
# only an explicit "must not be that either" catches it.
    .macro CHECK_A_NE reg, addrexpr, sub, faillabel
    la   x28, \addrexpr
    li   x29, \sub
    PAD
    beq  \reg, x28, \faillabel
    PAD_BR
    .endm

    .macro FAIL_STUB n
fail_\n:
    li   x30, \n
    jal  x0, fail_loop
    .endm

# One isolated I-type case: x2 = op(val, imm), compared against exp.
    .macro TI op, val, imm, exp, sub, faillabel
    li   x1, \val
    PAD
    \op  x2, x1, \imm
    PAD
    CHECK x2, \exp, \sub, \faillabel
    .endm

# One isolated R-type case: x3 = op(a, b), compared against exp.
    .macro TR op, a, b, exp, sub, faillabel
    li   x1, \a
    li   x2, \b
    PAD
    \op  x3, x1, x2
    PAD
    CHECK x3, \exp, \sub, \faillabel
    .endm

# Taken-branch case.  Fail-by-default: the branch has to be taken to step
# over the `jal x0, fail`, and that jal sits immediately before the target so
# that landing one instruction early is also caught.
    .macro TBT op, a, b, sub, faillabel, tgt
    li   x1, \a
    li   x2, \b
    li   x29, \sub
    PAD
    \op  x1, x2, \tgt
    PAD_BR
    jal  x0, \faillabel
\tgt\():
    .endm

# Not-taken-branch case: the branch under test points straight at the fail
# stub, so taking it at all is the failure.
    .macro TBN op, a, b, sub, faillabel
    li   x1, \a
    li   x2, \b
    li   x29, \sub
    PAD
    \op  x1, x2, \faillabel
    PAD_BR
    .endm

    .text
    .globl _start

#=============================================================================
_start:
    addi x30, x0, 0                     # fail code: 0 means "still running"
    addi x31, x0, 0                     # progress: no test started yet
    PAD

#=============================================================================
# LEVEL 0 -- BOOTSTRAP
#
# Nothing is trusted here.  Only ADDI, NOP, BEQ, BNE and JAL appear, with
# immediates small enough that every `li` in the macros is a single ADDI.
#=============================================================================

# ============================================================
# TEST 1: ADDI small positive immediate, and the checker itself
# Purpose:     Establish the two facts every later test is built on: ADDI can
#              put a known constant into a named register, and a conditional
#              branch can observe a mismatch between two registers.  Written
#              out longhand rather than via the macros so that the bootstrap
#              is auditable.
# Instructions: ADDI, BEQ, BNE, NOP
# Registers:   out x1; expected in x28; checks x1 (sub 1, sub 2)
# Expected:    x1 = 7
# Depends on:  nothing
# If it fails: the register-file write path, the I-type immediate field, or
#              the write-address field ir[11:7]
#
# Why this cannot pass falsely:
#   sub 1 compares x1 against 7 built a different way -- 3 then +4 -- so a
#   miscoded immediate has to be wrong twice, consistently, in two different
#   encodings to agree.
#   sub 1 alone would still pass on a CPU where ADDI never writes at all,
#   because REG_FILE's initial block zeroes the array and 0 == 0.  sub 2
#   closes that: x1 must also differ from x0.
#   What is left uncovered is a machine where NEITHER BEQ nor BNE ever
#   branches; tests 6 and 8 close that hole by requiring a taken branch to
#   skip over a fail stub.
# ============================================================
test_1:
    addi x31, x0, 1                     # progress, and the first ADDI executed
    addi x29, x0, 1
    nop
    nop
    addi x1, x0, 7                      # the value under test
    nop
    nop
    addi x28, x0, 3                     # 7 built independently, as 3 + 4
    nop
    nop
    addi x28, x28, 4
    nop
    nop
    bne  x1, x28, fail_1
    nop
    addi x29, x0, 2
    nop
    nop
    beq  x1, x0, fail_1                 # ... and it must not still be 0
    nop

# ============================================================
# TEST 2: NOP has no architectural effect
# Purpose:     NOP is the padding this entire program is built out of, so it
#              has to be proven inert before anything relies on it.  A run of
#              NOPs must not disturb a live register or x0.
# Instructions: ADDI, NOP, BEQ, BNE
# Registers:   in/out x4; checks x4 (sub 1, sub 2), x0 (sub 3)
# Expected:    x4 = 0x5A, x0 = 0
# Depends on:  1
# If it fails: NOP is decoding as something other than ADDI x0,x0,0 -- check
#              that opcode 0010011 with rd=0 really is gated by w_adr != 0
# ============================================================
test_2:
    TEST_START 2
    li   x4, 0x5A
    nop
    nop
    nop
    nop                                 # four NOPs over a live register
    CHECK x4, 0x5A, 1, fail_2
    CHECK_NE x4, 0, 2, fail_2
    CHECK x0, 0, 3, fail_2

# ============================================================
# TEST 3: ADDI with a negative immediate
# Purpose:     The I-type immediate is sign extended from 12 bits.  A DUT
#              that zero-extends produces a large positive number instead.
# Instructions: ADDI, BEQ, BNE
# Registers:   out x5; checks x5 (sub 1, 2, 3)
# Expected:    x5 = -3 = 0xFFFFFFFD
# Depends on:  1, 2
# If it fails: Immediate_Generator's I_TYPE sign replication, or ir[31] not
#              reaching it
# ============================================================
test_3:
    TEST_START 3
    li   x5, -3
    PAD
    CHECK x5, -3, 1, fail_3
    CHECK_NE x5, 3, 2, fail_3           # a zero-extending DUT gives 0x00000FFD
    CHECK_NE x5, 0, 3, fail_3
    li   x6, -1
    PAD
    CHECK x6, -1, 4, fail_3

# ============================================================
# TEST 4: ADDI with a zero immediate is a register move
# Purpose:     ADDI rd, rs, 0 must copy rs, which means rs1 is really being
#              read and routed to srcA rather than the immediate path.
# Instructions: ADDI, BEQ, BNE
# Registers:   in x7 -> out x8; checks x8 (sub 1, 2), x9 (sub 3)
# Expected:    x8 = 0x2C, x9 = 0
# Depends on:  1, 2
# If it fails: the srcA select mux, or rs1 not being read from ir[19:15]
# ============================================================
test_4:
    TEST_START 4
    li   x7, 0x2C
    PAD
    addi x8, x7, 0                      # move
    PAD
    CHECK x8, 0x2C, 1, fail_4
    CHECK_NE x8, 0, 2, fail_4
    addi x9, x0, 0                      # zero immediate from x0 -> exactly 0
    PAD
    CHECK x9, 0, 3, fail_4

# ============================================================
# TEST 5: x0 is hardwired to zero
# Purpose:     A write to x0 must be discarded, and x0 must read as 0 no
#              matter what.  PAD before the read matters here: Forwarding_Unit
#              matches on register number without excluding x0, so without
#              the gap a discarded write can still be forwarded.
# Instructions: ADDI, BEQ, BNE
# Registers:   writes x0; checks x0 (sub 1, sub 3), x10 (sub 2)
# Expected:    x0 = 0, x10 = 5
# Depends on:  1, 2
# If it fails: REG_FILE's `w_adr != 5'd0` write gate, or the read-side force
#              to zero
#
# sub 2 is the cross-check: it proves an immediate of 5 does reach a normal
# register on this path, so sub 1 is not passing merely because ADDI is dead.
# ============================================================
test_5:
    TEST_START 5
    addi x0, x0, 5                      # must be discarded entirely
    PAD
    CHECK x0, 0, 1, fail_5
    li   x10, 5
    PAD
    CHECK x10, 5, 2, fail_5
    CHECK_NE x0, 5, 3, fail_5

# ============================================================
# TEST 6: BEQ taken, landing exactly on the target
# Purpose:     First fail-by-default test.  The branch must be taken to step
#              over a `jal x0, fail_6`, so "the branch never fires" is a
#              failure rather than a silent pass.  The jal also sits directly
#              before the target, so landing one instruction short is caught.
# Instructions: ADDI, BEQ, JAL, NOP
# Registers:   out x11; checks x11 (sub 2, 3)
# Expected:    x11 = 0x33
# Depends on:  1, 5
# If it fails: Branch_Condition_Generator's br_eq, PC_Decoder's func3=000
#              arm, or Jump_Branch_Address_Generator's PC + B_Type
# ============================================================
test_6:
    TEST_START 6
    li   x11, 0
    li   x29, 1
    PAD
    beq  x0, x0, t6_ok                  # equal by construction: must be taken
    PAD_BR
    jal  x0, fail_6                     # only reached if the branch did not fire
t6_ok:
    addi x11, x0, 0x33                  # must execute, at exactly this address
    PAD
    CHECK x11, 0x33, 2, fail_6
    CHECK_NE x11, 0, 3, fail_6

# ============================================================
# TEST 7: BEQ not taken
# Purpose:     Unequal operands must leave the branch alone.  Pointing the
#              branch at its own fail stub makes a spuriously taken branch
#              the failure.
# Instructions: ADDI, BEQ, NOP
# Registers:   in x12, x13 -> out x14; checks x14 (sub 2)
# Expected:    x14 = 0x44
# Depends on:  1, 6
# If it fails: br_eq is stuck high, or PC_Decoder inverts the BEQ condition
# ============================================================
test_7:
    TEST_START 7
    li   x12, 1
    li   x13, 2
    li   x29, 1
    PAD
    beq  x12, x13, fail_7               # 1 != 2, so this must not be taken
    PAD_BR
    addi x14, x0, 0x44                  # must execute in line
    PAD
    CHECK x14, 0x44, 2, fail_7

# ============================================================
# TEST 8: BNE taken, landing exactly on the target
# Purpose:     Same fail-by-default shape as test 6, for the opposite
#              condition.  Between tests 6 and 8 a machine that never
#              branches on either condition can no longer reach pass_loop.
# Instructions: ADDI, BNE, JAL, NOP
# Registers:   in x15 -> out x16; checks x16 (sub 2, 3)
# Expected:    x16 = 0x55
# Depends on:  1, 5
# If it fails: PC_Decoder's func3=001 arm, or br_eq inverted
# ============================================================
test_8:
    TEST_START 8
    li   x15, 1
    li   x16, 0
    li   x29, 1
    PAD
    bne  x15, x0, t8_ok                 # 1 != 0, so this must be taken
    PAD_BR
    jal  x0, fail_8
t8_ok:
    addi x16, x0, 0x55
    PAD
    CHECK x16, 0x55, 2, fail_8
    CHECK_NE x16, 0, 3, fail_8

# ============================================================
# TEST 9: BNE not taken
# Purpose:     Equal operands must leave BNE alone.
# Instructions: ADDI, BNE, NOP
# Registers:   in x17 -> out x18; checks x18 (sub 2)
# Expected:    x18 = 0x66
# Depends on:  1, 8
# If it fails: br_eq is stuck low, or the BNE arm inverts it twice
# ============================================================
test_9:
    TEST_START 9
    li   x17, 0x21
    li   x29, 1
    PAD
    bne  x17, x17, fail_9               # a register is always equal to itself
    PAD_BR
    addi x18, x0, 0x66
    PAD
    CHECK x18, 0x66, 2, fail_9

# ============================================================
# TEST 10: JAL x0 transfers control to a forward label
# Purpose:     Every fail stub in this program ends in `jal x0, fail_loop`,
#              and every level skips its fail-stub cluster with a `jal x0`.
#              So JAL with rd = x0 is load-bearing from test 1 onward and has
#              to be proven as part of the bootstrap.  Fail-by-default again.
# Instructions: ADDI, JAL, BEQ, BNE, NOP
# Registers:   out x19; checks x19 (sub 1, 2)
# Expected:    x19 = 0x2A
# Depends on:  1, 6, 8
# If it fails: PC_Decoder's jal arm, Immediate_Generator's J_TYPE bit
#              scramble, or Jump_Branch_Address_Generator's PC + J_Type
#
# This test is unavoidably circular -- a broken JAL cannot report its own
# failure, because reporting goes through JAL.  What you see instead is the
# machine wandering off or parking in the wrong place.  That is why both
# park loops carry a `beq x0, x0, self` backstop.
# ============================================================
test_10:
    TEST_START 10
    li   x19, 0
    PAD
    jal  x0, t10_ok
    PAD_BR
    jal  x0, fail_10                    # only reached if JAL did not transfer
t10_ok:
    addi x19, x0, 0x2A
    PAD
    CHECK x19, 0x2A, 1, fail_10
    CHECK_NE x19, 0, 2, fail_10

    jal  x0, lvl1_start                 # step over this level's fail stubs

#-----------------------------------------------------------------------------
# Level 0 fail stubs.  Each loads its code from an immediate, so the report is
# correct even if every other register in the machine is garbage.  Nothing
# falls into this block: the jal above skips it and each stub leaves via
# fail_loop.
#-----------------------------------------------------------------------------
    FAIL_STUB 1
    FAIL_STUB 2
    FAIL_STUB 3
    FAIL_STUB 4
    FAIL_STUB 5
    FAIL_STUB 6
    FAIL_STUB 7
    FAIL_STUB 8
    FAIL_STUB 9
    FAIL_STUB 10

#=============================================================================
# LEVEL 1 -- I-TYPE ALU, LUI, AUIPC
#
# LUI comes first in this level on purpose.  Until LUI is proven, every
# expected value has to fit in a 12-bit ADDI immediate; once it is proven,
# `li` can materialise any 32-bit constant and the rest of the level can use
# real corner values.  Tests 100 and 101 therefore build their expected
# values out of ADDI alone.
#=============================================================================
lvl1_start:

# ============================================================
# TEST 100: LUI shifts its immediate left by 12
# Purpose:     LUI's whole job is the 12-bit shift, and it is the one part a
#              DUT can get wrong while still looking plausible.  The expected
#              value is built from ADDI only, so LUI is not being checked
#              against another copy of itself.
# Instructions: LUI, ADDI, BEQ, BNE
# Registers:   out x1; expected in x28; checks x1 (sub 1, 2, 3)
# Expected:    x1 = 0x00001000 = 4096
# Depends on:  1, 3, 8
# If it fails: Immediate_Generator's U_TYPE (must be {ir[31:12], 12'b0}) or
#              the ALU's alu_LUI_COPY re-shifting an already-shifted value
#
# sub 2 is the specific trap: a DUT that routes the raw immediate without
# shifting yields 1 instead of 4096.
# ============================================================
test_100:
    TEST_START 100
    lui  x1, 0x00001
    PAD
    addi x28, x0, 2047                  # 4096 out of ADDI immediates only:
    PAD
    addi x28, x28, 2047                 #   2047 + 2047 + 2
    PAD
    addi x28, x28, 2
    li   x29, 1
    PAD
    bne  x1, x28, fail_100
    PAD_BR
    CHECK_NE x1, 1, 2, fail_100         # unshifted immediate
    CHECK_NE x1, 0, 3, fail_100

# ============================================================
# TEST 101: LUI with an all-ones immediate
# Purpose:     0xFFFFF is the immediate that tells a sign-extension bug from
#              a shift bug: the correct answer is 0xFFFFF000, which is also
#              exactly -4096, and that is reachable with two ADDIs.
# Instructions: LUI, ADDI, BEQ, BNE
# Registers:   out x2; checks x2 (sub 1, 2, 3)
# Expected:    x2 = 0xFFFFF000
# Depends on:  3, 100
# If it fails: U_TYPE is sign extending past bit 31, or the low 12 bits are
#              not being zero filled
# ============================================================
test_101:
    TEST_START 101
    lui  x2, 0xFFFFF
    PAD
    addi x28, x0, -2048                 # -4096 == 0xFFFFF000, from ADDI only
    PAD
    addi x28, x28, -2048
    li   x29, 1
    PAD
    bne  x2, x28, fail_101
    PAD_BR
    CHECK_NE x2, -1, 2, fail_101        # a DUT that filled the low bits with 1s
    CHECK_NE x2, 0, 3, fail_101

# ============================================================
# TEST 102: LUI overwrites rd completely
# Purpose:     LUI does not read rs1 and must not merge with whatever rd
#              already held.  Seeding rd with nonzero low bits first makes a
#              merge visible.
# Instructions: LUI, ADDI, BEQ, BNE
# Registers:   in/out x3; checks x3 (sub 1, 2)
# Expected:    x3 = 0x00002000
# Depends on:  100
# If it fails: srcA is coming from rs1 instead of U_TYPE, or the ALU is ORing
#              rather than copying
# ============================================================
test_102:
    TEST_START 102
    li   x3, 0x7FF                      # low bits that must be destroyed
    PAD
    lui  x3, 0x00002
    PAD
    CHECK x3, 0x2000, 1, fail_102
    CHECK_NE x3, 0x27FF, 2, fail_102    # the merge failure mode

# ============================================================
# TEST 103: ADDI at both immediate extremes
# Purpose:     +2047 and -2048 are the largest and smallest 12-bit signed
#              immediates.  Off-by-one field extraction shows up here and
#              nowhere else.
# Instructions: ADDI, LUI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..4)
# Expected:    2047, -2048, 4094, -4096
# Depends on:  1, 3, 100
# If it fails: the I_TYPE field width, or the sign bit position
# ============================================================
test_103:
    TEST_START 103
    TI addi, 0, 2047, 2047, 1, fail_103
    TI addi, 0, -2048, -2048, 2, fail_103
    TI addi, 2047, 2047, 4094, 3, fail_103
    TI addi, -2048, -2048, -4096, 4, fail_103

# ============================================================
# TEST 104: ADDI wraparound at the 32-bit boundaries
# Purpose:     RV32I addition is modulo 2^32 with no overflow trap, so every
#              one of these has a defined answer.
# Instructions: ADDI, LUI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..4)
# Expected:    0x80000000, 0x7FFFFFFF, 0xFFFFFFFF, 0x00000000
# Depends on:  100, 103
# If it fails: a saturating or width-extended adder in the ALU
# ============================================================
test_104:
    TEST_START 104
    TI addi, 0x7FFFFFFF, 1, 0x80000000, 1, fail_104
    TI addi, 0x80000000, -1, 0x7FFFFFFF, 2, fail_104
    TI addi, 0, -1, 0xFFFFFFFF, 3, fail_104
    TI addi, 0xFFFFFFFF, 1, 0, 4, fail_104

# ============================================================
# TEST 105: LUI + ADDI where the low half borrows
# Purpose:     This is the sequence every 32-bit constant load turns into.
#              When the low 12 bits have their top bit set, ADDI's
#              sign-extended immediate is negative and the LUI half has to be
#              pre-incremented to compensate.  Getting it wrong costs exactly
#              0x1000.
# Instructions: LUI, ADDI, BEQ, BNE
# Registers:   out x1; expected in x28; checks x1 (sub 1, 2)
# Expected:    x1 = 0x12345FFF
# Depends on:  100, 103
# If it fails: nothing in the DUT -- this one is really checking that your
#              understanding of LUI and ADDI composes, so a failure here
#              after 100-104 pass means ADDI's rs1 path is dropping the LUI
#              result
#
# The expected value is built the long way round, 0x12345000 + 0x7FF + 0x7FF
# + 1, so no borrow is involved on that side.
# ============================================================
test_105:
    TEST_START 105
    lui  x1, 0x12346                    # pre-incremented high half
    PAD
    addi x1, x1, -1                     # ... and a negative low half
    PAD
    lui  x28, 0x12345
    PAD
    addi x28, x28, 0x7FF
    PAD
    addi x28, x28, 0x7FF
    PAD
    addi x28, x28, 1
    li   x29, 1
    PAD
    bne  x1, x28, fail_105
    PAD_BR
    CHECK_NE x1, 0x12346FFF, 2, fail_105  # the un-compensated answer

# ============================================================
# TEST 106: SLTI compares as signed
# Purpose:     Sweep the signed boundary from both sides, including the most
#              negative value.  Result must be exactly 1 or 0.
# Instructions: SLTI, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..6)
# Expected:    1, 0, 1, 0, 1, 0
# Depends on:  100, 104
# If it fails: the ALU's alu_SLT is comparing unsigned, or returning a
#              sign-extended -1 instead of 1
# ============================================================
test_106:
    TEST_START 106
    TI slti, -1, 0, 1, 1, fail_106
    TI slti, 0, -1, 0, 2, fail_106
    TI slti, 0x80000000, -1, 1, 3, fail_106
    TI slti, 0x7FFFFFFF, 2047, 0, 4, fail_106
    TI slti, -5, -4, 1, 5, fail_106
    TI slti, 5, 5, 0, 6, fail_106

# ============================================================
# TEST 107: SLTIU compares as unsigned
# Purpose:     The immediate is still sign extended to 32 bits and only then
#              treated as unsigned, so an immediate of -1 compares as
#              0xFFFFFFFF.  sub 3 and sub 4 are the `sltiu rd, rs, 1`
#              set-if-zero idiom.
# Instructions: SLTIU, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..6)
# Expected:    0, 1, 1, 0, 0, 1
# Depends on:  100, 104
# If it fails: the immediate is being zero extended before the comparison, or
#              alu_SLTU is comparing signed
# ============================================================
test_107:
    TEST_START 107
    TI sltiu, 0xFFFFFFFF, -1, 0, 1, fail_107
    TI sltiu, 0, -1, 1, 2, fail_107
    TI sltiu, 0, 1, 1, 3, fail_107
    TI sltiu, 5, 1, 0, 4, fail_107
    TI sltiu, 0x80000000, 1, 0, 5, fail_107
    TI sltiu, 0x7FFFFFFF, -1, 1, 6, fail_107

# ============================================================
# TEST 108: SLTI and SLTIU must disagree
# Purpose:     Each of 106 and 107 could pass with the two operations swapped
#              if the test values happened to agree.  These pairs are chosen
#              so the correct answers differ, which pins the two apart.
# Instructions: SLTI, SLTIU, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..4)
# Expected:    1, 0, 1, 0
# Depends on:  106, 107
# If it fails: Control_Unit_Decoder is mapping func3 010 and 011 to the same
#              ALU function
# ============================================================
test_108:
    TEST_START 108
    TI slti, 0x80000000, 1, 1, 1, fail_108
    TI sltiu, 0x80000000, 1, 0, 2, fail_108
    TI slti, -1, 1, 1, 3, fail_108
    TI sltiu, -1, 1, 0, 4, fail_108

# ============================================================
# TEST 109: XORI with a sign-extended immediate
# Purpose:     An immediate of -1 turns XORI into a bitwise NOT of the whole
#              register, which only works if the immediate reached all 32
#              bits.
# Instructions: XORI, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..4)
# Expected:    0xF0F0F0F0, 0xAAAAAFFF, 0x12345678, 0
# Depends on:  100, 104
# If it fails: the immediate is zero extended, so only the low 12 bits invert
# ============================================================
test_109:
    TEST_START 109
    TI xori, 0x0F0F0F0F, -1, 0xF0F0F0F0, 1, fail_109
    TI xori, 0xAAAAAAAA, 0x555, 0xAAAAAFFF, 2, fail_109
    TI xori, 0x12345678, 0, 0x12345678, 3, fail_109
    TI xori, 0xFFFFFFFF, -1, 0, 4, fail_109

# ============================================================
# TEST 110: ORI with a sign-extended immediate
# Purpose:     -2048 is 0xFFFFF800, so ORI with it must set the whole top of
#              the register, not just bit 11.
# Instructions: ORI, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..4)
# Expected:    0xFFFFFFFF, 0xFFFFFE78, 0x123456F8, 0x12345678
# Depends on:  100, 104
# If it fails: immediate sign extension on the OR path
# ============================================================
test_110:
    TEST_START 110
    TI ori, 0, -1, 0xFFFFFFFF, 1, fail_110
    TI ori, 0x12345678, -2048, 0xFFFFFE78, 2, fail_110
    TI ori, 0x12345678, 0x0F0, 0x123456F8, 3, fail_110
    TI ori, 0x12345678, 0, 0x12345678, 4, fail_110

# ============================================================
# TEST 111: ANDI with a sign-extended immediate
# Purpose:     The mirror of 110.  ANDI with -2048 must preserve the top 21
#              bits; a zero-extended immediate would clear them instead,
#              which is the loudest possible version of this bug.
# Instructions: ANDI, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..4)
# Expected:    0xFFFFF800, 0x12345678, 0x00000078, 0
# Depends on:  100, 104
# If it fails: immediate sign extension on the AND path
# ============================================================
test_111:
    TEST_START 111
    TI andi, 0xFFFFFFFF, -2048, 0xFFFFF800, 1, fail_111
    TI andi, 0x12345678, -1, 0x12345678, 2, fail_111
    TI andi, 0x12345678, 0x0FF, 0x00000078, 3, fail_111
    TI andi, 0x12345678, 0, 0, 4, fail_111

# ============================================================
# TEST 112: SLLI by 0, 1 and 31
# Purpose:     Shift by 0 must be a copy, and shift by 31 must leave only the
#              old bit 0 at the top.  Both ends of the shift-amount field.
# Instructions: SLLI, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..4)
# Expected:    0x12345678, 0x2468ACF0, 0x80000000, 0x80000000
# Depends on:  100, 104
# If it fails: the shamt field ir[24:20], or a barrel shifter that treats 0
#              as 32
# ============================================================
test_112:
    TEST_START 112
    TI slli, 0x12345678, 0, 0x12345678, 1, fail_112
    TI slli, 0x12345678, 1, 0x2468ACF0, 2, fail_112
    TI slli, 1, 31, 0x80000000, 3, fail_112
    TI slli, 0xFFFFFFFF, 31, 0x80000000, 4, fail_112

# ============================================================
# TEST 113: SRLI by 0, 1 and 31
# Purpose:     SRLI must zero fill, so shifting a negative value right by 31
#              leaves exactly 1 -- the single cleanest way to tell SRLI from
#              SRAI.
# Instructions: SRLI, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..4)
# Expected:    0x12345678, 0x091A2B3C, 1, 1
# Depends on:  100, 104
# If it fails: ir30 is selecting alu_SRA for func7 = 0000000
# ============================================================
test_113:
    TEST_START 113
    TI srli, 0x12345678, 0, 0x12345678, 1, fail_113
    TI srli, 0x12345678, 1, 0x091A2B3C, 2, fail_113
    TI srli, 0x80000000, 31, 1, 3, fail_113
    TI srli, 0xFFFFFFFF, 31, 1, 4, fail_113

# ============================================================
# TEST 114: SRAI on negative values
# Purpose:     SRAI replicates the sign bit.  Shifting the most negative
#              value right by 31 must give -1, not 1.
# Instructions: SRAI, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1..5)
# Expected:    0x80000000, 0xFFFFFFFF, 0xF8000000, 0xFFFFFFFF, 0
# Depends on:  100, 104
# If it fails: the ALU is using >> rather than >>> with a $signed operand, or
#              ir30 is not reaching Control_Unit_Decoder
# ============================================================
test_114:
    TEST_START 114
    TI srai, 0x80000000, 0, 0x80000000, 1, fail_114
    TI srai, 0x80000000, 31, 0xFFFFFFFF, 2, fail_114
    TI srai, 0x80000000, 4, 0xF8000000, 3, fail_114
    TI srai, 0xFFFFFFFF, 31, 0xFFFFFFFF, 4, fail_114
    TI srai, 0x7FFFFFFF, 31, 0, 5, fail_114

# ============================================================
# TEST 115: SRAI and SRLI must disagree on a negative value
# Purpose:     113 and 114 would both pass if func7 were ignored and both
#              encodings did the same thing, as long as that one thing were
#              self-consistent.  Same operand, same shift, both encodings,
#              answers that must differ.
# Instructions: SRAI, SRLI, LUI, ADDI, BEQ, BNE
# Registers:   x1 -> x2; checks x2 (sub 1, 2)
# Expected:    0xFFFF0000 then 0x00FF0000
# Depends on:  113, 114
# If it fails: ir[30] is not reaching the func3 = 101 decode arm
# ============================================================
test_115:
    TEST_START 115
    TI srai, 0xFF000000, 8, 0xFFFF0000, 1, fail_115
    TI srli, 0xFF000000, 8, 0x00FF0000, 2, fail_115

# ============================================================
# TEST 116: AUIPC with immediate 0 yields the PC
# Purpose:     AUIPC is the only instruction that exposes the PC as data
#              before jumps are tested, so it is checked against an address
#              the assembler computed rather than against another AUIPC.
# Instructions: AUIPC, LUI, ADDI, BEQ, BNE
# Registers:   out x1; checks x1 (sub 1, 2)
# Expected:    x1 = address of p116
# Depends on:  100, 104
# If it fails: id_ex_q.PC is not carrying the instruction's own address, or
#              srcB_SEL is not selecting srcb_PC
#
# NOTE: on the RTL as it stands, `auipc rd, 0` has ir[19:15] = 0, so
# Forwarding_Unit sees rs1_addr == 0 matching any x0-writing instruction in
# MEM and overwrites srcA with that instruction's ALU result.  For immediate
# 0 the forwarded value happens to be the right one; test 117 is where it
# stops being harmless, and test 818 is where it is tested head on.
# ============================================================
test_116:
    TEST_START 116
p116:
    auipc x1, 0
    PAD
    CHECK_A x1, p116, 1, fail_116
    CHECK_NE x1, 0, 2, fail_116

# ============================================================
# TEST 117: AUIPC with a nonzero immediate
# Purpose:     The U-type immediate is added to the PC already shifted left
#              by 12, in both directions.  0xFFFFF is -0x1000.
# Instructions: AUIPC, LUI, ADDI, BEQ, BNE
# Registers:   out x1, x2; checks x1 (sub 1), x2 (sub 2)
# Expected:    x1 = p117a + 0x1000, x2 = p117b - 0x1000
# Depends on:  116
# If it fails: the U-type immediate is not being shifted before the add, or
#              is being sign extended past bit 31
#
# sub 2's expected value is built by subtracting 2048 twice rather than with
# `la x28, p117b-0x1000`, so that the assembler is never asked to relocate a
# negative absolute address.
# ============================================================
test_117:
    TEST_START 117
p117a:
    auipc x1, 1
    PAD
p117b:
    auipc x2, 0xFFFFF
    PAD
    CHECK_A x1, p117a+0x1000, 1, fail_117
    la   x28, p117b
    PAD
    addi x28, x28, -2048
    PAD
    addi x28, x28, -2048
    li   x29, 2
    PAD
    bne  x2, x28, fail_117
    PAD_BR

    jal  x0, lvl1_done                  # step over this level's fail stubs

#-----------------------------------------------------------------------------
# Level 1 fail stubs
#-----------------------------------------------------------------------------
    FAIL_STUB 100
    FAIL_STUB 101
    FAIL_STUB 102
    FAIL_STUB 103
    FAIL_STUB 104
    FAIL_STUB 105
    FAIL_STUB 106
    FAIL_STUB 107
    FAIL_STUB 108
    FAIL_STUB 109
    FAIL_STUB 110
    FAIL_STUB 111
    FAIL_STUB 112
    FAIL_STUB 113
    FAIL_STUB 114
    FAIL_STUB 115
    FAIL_STUB 116
    FAIL_STUB 117
lvl1_done:

#=============================================================================
# LEVEL 2 -- R-TYPE ALU
#
# Same operations as level 1 but with both operands coming out of the
# register file, so these tests add the rs2 read port and the srcB select to
# what is already proven.  Every case is a full-width corner value, which
# level 1 could not use until LUI was established.
#=============================================================================

# ============================================================
# TEST 200: ADD, including wraparound
# Purpose:     Register-to-register addition, modulo 2^32.  The three corner
#              cases are the ones an adder built too wide gets wrong.
# Instructions: ADD, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..4)
# Expected:    0x23456789, 0x80000000, 0x00000000, 0x00000000
# Depends on:  100, 104
# If it fails: the rs2 read port, srcB_SEL selecting the immediate instead of
#              rs2, or a carry out being kept
# ============================================================
test_200:
    TEST_START 200
    TR add, 0x12345678, 0x11111111, 0x23456789, 1, fail_200
    TR add, 0x7FFFFFFF, 1, 0x80000000, 2, fail_200
    TR add, 0xFFFFFFFF, 1, 0, 3, fail_200
    TR add, 0x80000000, 0x80000000, 0, 4, fail_200

# ============================================================
# TEST 201: ADD with negatives and with x0
# Purpose:     Two's complement addition needs no special handling, and
#              adding x0 must be an exact copy through either operand port.
# Instructions: ADD, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2, x4 -> out x3, x5, x6; checks sub 1..4
# Expected:    -2, -8, 0x0BADF00D, 0x0BADF00D
# Depends on:  200
# If it fails: if only sub 3 or only sub 4 fails, one of the two read ports
#              is not honouring the x0 force-to-zero
# ============================================================
test_201:
    TEST_START 201
    TR add, -5, 3, -2, 1, fail_201
    TR add, -5, -3, -8, 2, fail_201
    li   x4, 0x0BADF00D
    PAD
    add  x5, x4, x0                     # x0 as rs2
    PAD
    CHECK x5, 0x0BADF00D, 3, fail_201
    add  x6, x0, x4                     # x0 as rs1
    PAD
    CHECK x6, 0x0BADF00D, 4, fail_201

# ============================================================
# TEST 202: SUB, including borrow
# Purpose:     SUB shares func3 with ADD and is selected only by ir[30], so
#              this is as much a decode test as an arithmetic one.
# Instructions: SUB, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..5)
# Expected:    0x12345678, 0x7FFFFFFF, 0xFFFFFFFF, 0x80000000, 0
# Depends on:  200
# If it fails: ir30 not reaching Control_Unit_Decoder's func3=000 arm, so SUB
#              is decoding as ADD -- sub 1 would then give 0x3456789A
# ============================================================
test_202:
    TEST_START 202
    TR sub, 0x23456789, 0x11111111, 0x12345678, 1, fail_202
    TR sub, 0x80000000, 1, 0x7FFFFFFF, 2, fail_202
    TR sub, 0, 1, 0xFFFFFFFF, 3, fail_202
    TR sub, 0, 0x80000000, 0x80000000, 4, fail_202
    TR sub, 5, 5, 0, 5, fail_202

# ============================================================
# TEST 203: SUB is not commutative
# Purpose:     A DUT that swapped srcA and srcB passes every symmetric test
#              in 202.  These two cases are the same pair in both orders.
# Instructions: SUB, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1, 2)
# Expected:    7 then -7
# Depends on:  202
# If it fails: srcA and srcB are swapped at the ALU
# ============================================================
test_203:
    TEST_START 203
    TR sub, 10, 3, 7, 1, fail_203
    TR sub, 3, 10, -7, 2, fail_203

# ============================================================
# TEST 204: SLL by a register amount
# Purpose:     The shift amount now comes from rs2 rather than the shamt
#              field, which is a different path through srcB.
# Instructions: SLL, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..4)
# Expected:    2, 0x80000000, 0x23456780, 0x12345678
# Depends on:  112, 200
# If it fails: the shift amount is being taken from the immediate path
# ============================================================
test_204:
    TEST_START 204
    TR sll, 1, 1, 2, 1, fail_204
    TR sll, 1, 31, 0x80000000, 2, fail_204
    TR sll, 0x12345678, 4, 0x23456780, 3, fail_204
    TR sll, 0x12345678, 0, 0x12345678, 4, fail_204

# ============================================================
# TEST 205: SLL uses only rs2[4:0]
# Purpose:     A DUT that forgot to mask the shift amount passes every shift
#              under 32 and fails only here.  Shift by 32 must behave as
#              shift by 0, and 33 as 1.
# Instructions: SLL, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..3)
# Expected:    0x12345678, 0x2468ACF0, 0x23456780
# Depends on:  204
# If it fails: the ALU is indexing with the full srcB rather than srcB[4:0]
# ============================================================
test_205:
    TEST_START 205
    TR sll, 0x12345678, 32, 0x12345678, 1, fail_205
    TR sll, 0x12345678, 33, 0x2468ACF0, 2, fail_205
    TR sll, 0x12345678, 0xFFFFFFE4, 0x23456780, 3, fail_205

# ============================================================
# TEST 206: SRL by a register amount
# Purpose:     Logical right shift zero fills, so a negative operand shifted
#              right by 31 must leave exactly 1.
# Instructions: SRL, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..4)
# Expected:    0x40000000, 1, 0x01234567, 0xFFFFFFFF
# Depends on:  113, 200
# If it fails: ir30 is selecting SRA for func7 = 0000000
# ============================================================
test_206:
    TEST_START 206
    TR srl, 0x80000000, 1, 0x40000000, 1, fail_206
    TR srl, 0x80000000, 31, 1, 2, fail_206
    TR srl, 0x12345678, 4, 0x01234567, 3, fail_206
    TR srl, 0xFFFFFFFF, 0, 0xFFFFFFFF, 4, fail_206

# ============================================================
# TEST 207: SRL uses only rs2[4:0]
# Purpose:     The SRL half of the shift-amount masking requirement.
# Instructions: SRL, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1, 2)
# Expected:    0x12345678, 0x091A2B3C
# Depends on:  206
# If it fails: shift amount masking on the right-shift path
# ============================================================
test_207:
    TEST_START 207
    TR srl, 0x12345678, 32, 0x12345678, 1, fail_207
    TR srl, 0x12345678, 33, 0x091A2B3C, 2, fail_207

# ============================================================
# TEST 208: SRA on negative values
# Purpose:     Arithmetic right shift replicates bit 31.  sub 4 uses a
#              positive operand, where SRA and SRL must agree -- so a DUT
#              that gets only sub 4 right has the sign logic inverted.
# Instructions: SRA, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..4)
# Expected:    0xC0000000, 0xFFFFFFFF, 0xFFFFFFFF, 0x3FFFFFFF
# Depends on:  114, 200
# If it fails: the ALU is not applying $signed to srcA before >>>
# ============================================================
test_208:
    TEST_START 208
    TR sra, 0x80000000, 1, 0xC0000000, 1, fail_208
    TR sra, 0x80000000, 31, 0xFFFFFFFF, 2, fail_208
    TR sra, 0xFFFFFFFF, 1, 0xFFFFFFFF, 3, fail_208
    TR sra, 0x7FFFFFFF, 1, 0x3FFFFFFF, 4, fail_208

# ============================================================
# TEST 209: SRA uses only rs2[4:0]
# Purpose:     The SRA half of the shift-amount masking requirement.  A DUT
#              that sign-extends the shift amount instead of masking it
#              produces 0xFFFFFFFF here.
# Instructions: SRA, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1, 2)
# Expected:    0x80000000, 0xC0000000
# Depends on:  208
# If it fails: shift amount masking on the arithmetic-shift path
# ============================================================
test_209:
    TEST_START 209
    TR sra, 0x80000000, 32, 0x80000000, 1, fail_209
    TR sra, 0x80000000, 33, 0xC0000000, 2, fail_209

# ============================================================
# TEST 210: SRA and SRL must disagree on a negative value
# Purpose:     Same operand, same shift amount, the two encodings, answers
#              that cannot both be right.  This is what pins func7 apart on
#              the register-shift path.
# Instructions: SRA, SRL, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1, 2)
# Expected:    0xFFFF0000 then 0x00FF0000
# Depends on:  206, 208
# If it fails: ir[30] is ignored on opcode 0110011 func3 101
# ============================================================
test_210:
    TEST_START 210
    TR sra, 0xFF000000, 8, 0xFFFF0000, 1, fail_210
    TR srl, 0xFF000000, 8, 0x00FF0000, 2, fail_210

# ============================================================
# TEST 211: SLT compares as signed
# Purpose:     Sweep the signed boundary with both operand orders, including
#              the most negative and most positive values against each other.
# Instructions: SLT, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..6)
# Expected:    1, 1, 0, 0, 1, 0
# Depends on:  106, 200
# If it fails: alu_SLT is comparing unsigned
# ============================================================
test_211:
    TEST_START 211
    TR slt, 0x80000000, 1, 1, 1, fail_211
    TR slt, -1, 1, 1, 2, fail_211
    TR slt, 1, -1, 0, 3, fail_211
    TR slt, 5, 5, 0, 4, fail_211
    TR slt, -5, -4, 1, 5, fail_211
    TR slt, 0x7FFFFFFF, 0x80000000, 0, 6, fail_211

# ============================================================
# TEST 212: SLTU compares as unsigned
# Purpose:     The same operands as 211 read as magnitudes instead of signed
#              values, so 0xFFFFFFFF is the largest number rather than -1.
# Instructions: SLTU, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..5)
# Expected:    0, 0, 1, 0, 1
# Depends on:  107, 200
# If it fails: alu_SLTU is comparing signed
# ============================================================
test_212:
    TEST_START 212
    TR sltu, 0x80000000, 1, 0, 1, fail_212
    TR sltu, 0xFFFFFFFF, 1, 0, 2, fail_212
    TR sltu, 1, 0xFFFFFFFF, 1, 3, fail_212
    TR sltu, 5, 5, 0, 4, fail_212
    TR sltu, 0, 1, 1, 5, fail_212

# ============================================================
# TEST 213: SLT and SLTU must disagree
# Purpose:     0x80000000 against 0x7FFFFFFF is the pair where signed and
#              unsigned give opposite answers, so the two operations cannot
#              be aliased to each other.
# Instructions: SLT, SLTU, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..4)
# Expected:    1, 0, 1, 0
# Depends on:  211, 212
# If it fails: func3 010 and 011 map to the same ALU function
# ============================================================
test_213:
    TEST_START 213
    TR slt, 0x80000000, 0x7FFFFFFF, 1, 1, fail_213
    TR sltu, 0x80000000, 0x7FFFFFFF, 0, 2, fail_213
    TR slt, -1, 1, 1, 3, fail_213
    TR sltu, -1, 1, 0, 4, fail_213

# ============================================================
# TEST 214: XOR, OR and AND
# Purpose:     Plain 32-bit bitwise operations.  sub 1 and sub 2 deliberately
#              use complementary operands, where XOR and OR give the same
#              answer, and sub 4..6 then separate the three.
# Instructions: XOR, OR, AND, LUI, ADDI, BEQ, BNE
# Registers:   in x1, x2 -> out x3; checks x3 (sub 1..6)
# Expected:    0xFFFFFFFF, 0xFFFFFFFF, 0xF0F00000, 0, 0, 0xDEADBEEF
# Depends on:  109, 110, 111, 200
# If it fails: the func3 to ALU function map for 100 / 110 / 111
# ============================================================
test_214:
    TEST_START 214
    TR xor, 0xF0F0F0F0, 0x0F0F0F0F, 0xFFFFFFFF, 1, fail_214
    TR or, 0xF0F0F0F0, 0x0F0F0F0F, 0xFFFFFFFF, 2, fail_214
    TR and, 0xF0F0F0F0, 0xFFFF0000, 0xF0F00000, 3, fail_214
    TR xor, 0xDEADBEEF, 0xDEADBEEF, 0, 4, fail_214
    TR and, 0xDEADBEEF, 0, 0, 5, fail_214
    TR or, 0xDEADBEEF, 0, 0xDEADBEEF, 6, fail_214

# ============================================================
# TEST 215: rd, rs1 and rs2 all the same register
# Purpose:     Both read ports and the write port aimed at one register at
#              once.  This is where a register file that latches a read after
#              the write, or forwards its own result, shows up.
# Instructions: ADD, SUB, AND, XOR, SLT, LUI, ADDI, BEQ, BNE
# Registers:   in/out x5 -> x6..x9; checks sub 1..6
# Expected:    0x22222222, 0, 0x22222222, 0, 0, 0
# Depends on:  200, 202, 211, 214
# If it fails: a read/write collision inside REG_FILE on the same address
# ============================================================
test_215:
    TEST_START 215
    li   x5, 0x11111111
    PAD
    add  x5, x5, x5                     # rd = rs1 = rs2
    PAD
    CHECK x5, 0x22222222, 1, fail_215
    sub  x6, x5, x5
    PAD
    CHECK x6, 0, 2, fail_215
    and  x7, x5, x5
    PAD
    CHECK x7, 0x22222222, 3, fail_215
    xor  x8, x5, x5
    PAD
    CHECK x8, 0, 4, fail_215
    slt  x9, x5, x5
    PAD
    CHECK x9, 0, 5, fail_215
    sub  x5, x5, x5
    PAD
    CHECK x5, 0, 6, fail_215

# ============================================================
# TEST 216: the difference between two AUIPCs
# Purpose:     Level 1 checked each AUIPC against an assembler-computed
#              address.  This checks the relationship between two of them,
#              which is the property AUIPC actually exists for, and it needs
#              SUB -- hence its place here rather than in level 1.
# Instructions: AUIPC, SUB, LUI, ADDI, BEQ, BNE
# Registers:   out x4, x5 -> x6; checks x6 (sub 1, 2)
# Expected:    x6 = 4*(1+SAFE_GAP) = 12
# Depends on:  116, 202
# If it fails: id_ex_q.PC is a constant rather than per-instruction, which
#              makes every AUIPC agree and the difference zero -- that is
#              exactly what sub 2 catches
# ============================================================
test_216:
    TEST_START 216
p216a:
    auipc x4, 0
    PAD
p216b:
    auipc x5, 0
    PAD
    sub  x6, x5, x4
    PAD
    CHECK x6, 4*(1+SAFE_GAP), 1, fail_216
    CHECK_NE x6, 0, 2, fail_216

    jal  x0, lvl2_done

#-----------------------------------------------------------------------------
# Level 2 fail stubs
#-----------------------------------------------------------------------------
    FAIL_STUB 200
    FAIL_STUB 201
    FAIL_STUB 202
    FAIL_STUB 203
    FAIL_STUB 204
    FAIL_STUB 205
    FAIL_STUB 206
    FAIL_STUB 207
    FAIL_STUB 208
    FAIL_STUB 209
    FAIL_STUB 210
    FAIL_STUB 211
    FAIL_STUB 212
    FAIL_STUB 213
    FAIL_STUB 214
    FAIL_STUB 215
    FAIL_STUB 216
lvl2_done:

#=============================================================================
# LEVEL 3 -- REGISTER FILE
#
# Levels 1 and 2 only ever used a handful of registers, so an address-decode
# fault in the register file could have survived both.  This level writes a
# distinct value into every architectural register and reads them all back.
#=============================================================================

# ============================================================
# TEST 300: all of x1..x27 hold distinct values simultaneously
# Purpose:     Catch address-decode aliasing.  Each register gets a unique
#              value, and only after all 27 are written does anything get
#              read back -- so two registers that share a decode line
#              overwrite each other and the second read fails.
# Instructions: ADDI, BEQ, BNE
# Registers:   x1..x27; sub-check index == the register number that failed
# Expected:    x<r> = 0x100 + r*0x11, for r = 1..27
# Depends on:  1, 2, 104
# If it fails: x29 names the register, which is the whole point -- compare it
#              against the value actually in that register to see which other
#              register it aliased with
#
# The values stay inside 12 bits so that every `li` here is a single ADDI and
# the level does not depend on LUI.  x28..x31 are covered by test 301 because
# the checker itself needs x28 and x29.  Each write is PAD-separated even
# though the writes are independent of each other: that keeps this level
# inside the isolation discipline, so a failure here cannot be blamed on
# forwarding.
# ============================================================
test_300:
    TEST_START 300
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27
    li   x\r, 0x100+\r*0x11
    PAD
    .endr
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27
    CHECK x\r, 0x100+\r*0x11, \r, fail_300
    .endr

# ============================================================
# TEST 301: x28..x31 are real storage too
# Purpose:     The four reporting registers are ordinary registers and have
#              to be proven as such, but the checker macros use x28 and x29,
#              so this test compares by hand against x1..x4 instead.
# Instructions: LUI, ADDI, BEQ, BNE
# Registers:   x28..x31 under test, x1..x4 as the comparison values
# Expected:    0x1C1C1C1C, 0x1D1D1D1D, 0x1E1E1E1E, 0x1F1F1F1F
# Depends on:  300
# If it fails: the top of the register address space is not decoded
#
# x29 does NOT carry a sub-check index in this test -- it is under test.  The
# fail stub loads its code from an immediate, so the report survives having
# all four of these registers full of patterns.  The convention is
# re-established at the end.
# ============================================================
test_301:
    li   x31, 301
    PAD
    li   x28, 0x1C1C1C1C
    li   x29, 0x1D1D1D1D
    li   x30, 0x1E1E1E1E
    li   x31, 0x1F1F1F1F
    PAD
    li   x1, 0x1C1C1C1C
    PAD
    bne  x28, x1, fail_301
    PAD_BR
    li   x2, 0x1D1D1D1D
    PAD
    bne  x29, x2, fail_301
    PAD_BR
    li   x3, 0x1E1E1E1E
    PAD
    bne  x30, x3, fail_301
    PAD_BR
    li   x4, 0x1F1F1F1F
    PAD
    bne  x31, x4, fail_301
    PAD_BR
    li   x30, 0                         # restore the reporting convention
    li   x31, 301
    li   x29, 0
    PAD

# ============================================================
# TEST 302: the same register read through both ports
# Purpose:     The two read ports are independent address decoders.  Reading
#              one register through both at once must give the same value on
#              each, and reading two different registers must not cross over.
# Instructions: SUB, AND, XOR, LUI, ADDI, BEQ, BNE
# Registers:   in x5, x8 -> out x6, x7, x9; checks sub 1..3
# Expected:    0, 0x5A5A5A5A, 0x55555555
# Depends on:  300, 202, 214
# If it fails: sub 1 nonzero means the two ports disagree on one address;
#              sub 3 wrong means one port is reading the other's address
# ============================================================
test_302:
    TEST_START 302
    li   x5, 0x5A5A5A5A
    PAD
    sub  x6, x5, x5                     # both ports, one address
    PAD
    CHECK x6, 0, 1, fail_302
    and  x7, x5, x5
    PAD
    CHECK x7, 0x5A5A5A5A, 2, fail_302
    li   x8, 0x0F0F0F0F
    PAD
    xor  x9, x5, x8                     # two ports, two addresses
    PAD
    CHECK x9, 0x55555555, 3, fail_302

# ============================================================
# TEST 303: writes to x0 are discarded on every write path
# Purpose:     Test 5 covered the I-type path during bootstrap.  Each
#              instruction class reaches the register file write port with a
#              different RF_SEL, so each one needs its own case.  Load and
#              JAL writes to x0 are covered in their own levels (611, 501).
# Instructions: ADD, ADDI, SUB, LUI, AUIPC, BEQ, BNE
# Registers:   writes x0 five ways; checks x0 (sub 1..5), x12 (sub 6)
# Expected:    x0 = 0 throughout, x12 = 0
# Depends on:  5, 100, 116, 200, 202
# If it fails: the write gate is downstream of the result mux rather than on
#              the write address, so some RF_SEL values bypass it
# ============================================================
test_303:
    TEST_START 303
    li   x10, 0x1234
    li   x11, 0x5678
    PAD
    add  x0, x10, x11                   # R-type
    PAD
    CHECK x0, 0, 1, fail_303
    addi x0, x10, 0x7FF                 # I-type
    PAD
    CHECK x0, 0, 2, fail_303
    lui  x0, 0xABCDE                    # U-type
    PAD
    CHECK x0, 0, 3, fail_303
    auipc x0, 0x00010                   # AUIPC
    PAD
    CHECK x0, 0, 4, fail_303
    sub  x0, x0, x11                    # x0 as rs1 as well as rd
    PAD
    CHECK x0, 0, 5, fail_303
    add  x12, x0, x0                    # x0 on both read ports
    PAD
    CHECK x12, 0, 6, fail_303

    jal  x0, lvl3_done

#-----------------------------------------------------------------------------
# Level 3 fail stubs
#-----------------------------------------------------------------------------
    FAIL_STUB 300
    FAIL_STUB 301
    FAIL_STUB 302
    FAIL_STUB 303
lvl3_done:

#=============================================================================
# LEVEL 4 -- BRANCHES
#
# All six conditions, both directions, through the TBT / TBN macros so that
# every taken case is fail-by-default: the branch has to fire to step over a
# `jal x0, fail_N`, and that jal sits immediately before the target so a
# one-instruction undershoot is caught too.
#=============================================================================

# ============================================================
# TEST 400: BEQ taken and not taken
# Purpose:     Level 0 proved BEQ works on x0 against x0.  This repeats it
#              with full-width operands that differ in only one bit, which is
#              what a comparator built too narrow gets wrong.
# Instructions: BEQ, JAL, LUI, ADDI, NOP
# Registers:   in x1, x2 -> out x4; checks x4 (sub 2)
# Expected:    x4 = 0x11
# Depends on:  6, 7, 100
# If it fails: br_eq is comparing fewer than 32 bits
# ============================================================
test_400:
    TEST_START 400
    TBT beq, 0x12345678, 0x12345678, 1, fail_400, t400a
    addi x4, x0, 0x11                   # must execute at the target
    PAD
    CHECK x4, 0x11, 2, fail_400
    TBN beq, 0x12345678, 0x12345679, 3, fail_400

# ============================================================
# TEST 401: BNE taken and not taken
# Purpose:     The one-bit difference case for the inverted condition.
# Instructions: BNE, JAL, LUI, ADDI, NOP
# Registers:   in x1, x2 -> out x4; checks x4 (sub 2)
# Expected:    x4 = 0x12
# Depends on:  8, 9, 100
# If it fails: br_eq is comparing fewer than 32 bits
# ============================================================
test_401:
    TEST_START 401
    TBT bne, 0x12345678, 0x12345679, 1, fail_401, t401a
    addi x4, x0, 0x12
    PAD
    CHECK x4, 0x12, 2, fail_401
    TBN bne, 0x12345678, 0x12345678, 3, fail_401

# ============================================================
# TEST 402: BLT across less, equal and greater
# Purpose:     BLT is strict, so equal must NOT branch.  All three orderings
#              are needed because a comparator that computed <= would pass
#              the less and greater cases.
# Instructions: BLT, JAL, LUI, ADDI, NOP
# Registers:   in x1, x2 -> out x4; checks x4 (sub 2)
# Expected:    x4 = 0x13
# Depends on:  211, 400
# If it fails: br_lt is really a signed <=, or PC_Decoder's func3=100 arm
# ============================================================
test_402:
    TEST_START 402
    TBT blt, -5, 3, 1, fail_402, t402a
    addi x4, x0, 0x13
    PAD
    CHECK x4, 0x13, 2, fail_402
    TBN blt, 7, 7, 3, fail_402
    TBN blt, 3, -5, 4, fail_402

# ============================================================
# TEST 403: BGE across greater, equal and less
# Purpose:     BGE is the inclusive one, so equal MUST branch -- that is the
#              case that separates it from a negated BLT done wrong.
# Instructions: BGE, JAL, LUI, ADDI, NOP
# Registers:   in x1, x2 -> out x4; checks x4 (sub 2)
# Expected:    x4 = 0x14
# Depends on:  402
# If it fails: PC_Decoder's func3=101 arm is using ~br_lt where br_lt was
#              computed as <=, which collapses the equal case
# ============================================================
test_403:
    TEST_START 403
    TBT bge, 3, -5, 1, fail_403, t403a
    addi x4, x0, 0x14
    PAD
    CHECK x4, 0x14, 2, fail_403
    TBT bge, 7, 7, 3, fail_403, t403b
    TBN bge, -5, 3, 4, fail_403

# ============================================================
# TEST 404: BLTU across less, equal and greater
# Purpose:     The unsigned comparator, with 0xFFFFFFFF as the large value
#              rather than -1.
# Instructions: BLTU, JAL, LUI, ADDI, NOP
# Registers:   in x1, x2 -> out x4; checks x4 (sub 2)
# Expected:    x4 = 0x15
# Depends on:  212, 400
# If it fails: br_ltu is signed, or func3=110 maps to br_lt
# ============================================================
test_404:
    TEST_START 404
    TBT bltu, 1, 0xFFFFFFFF, 1, fail_404, t404a
    addi x4, x0, 0x15
    PAD
    CHECK x4, 0x15, 2, fail_404
    TBN bltu, 7, 7, 3, fail_404
    TBN bltu, 0xFFFFFFFF, 1, 4, fail_404

# ============================================================
# TEST 405: BGEU across greater, equal and less
# Purpose:     The inclusive unsigned condition, including the equal case.
# Instructions: BGEU, JAL, LUI, ADDI, NOP
# Registers:   in x1, x2 -> out x4; checks x4 (sub 2)
# Expected:    x4 = 0x16
# Depends on:  404
# If it fails: func3=111 is using the signed comparator
# ============================================================
test_405:
    TEST_START 405
    TBT bgeu, 0xFFFFFFFF, 1, 1, fail_405, t405a
    addi x4, x0, 0x16
    PAD
    CHECK x4, 0x16, 2, fail_405
    TBT bgeu, 7, 7, 3, fail_405, t405b
    TBN bgeu, 1, 0xFFFFFFFF, 4, fail_405

# ============================================================
# TEST 406: signed boundaries for BLT and BGE
# Purpose:     -1 against 1, and 0x80000000 against 0x7FFFFFFF.  The second
#              pair is the one where the signed and unsigned answers are
#              opposite, so it is the pair test 407 reuses.
# Instructions: BLT, BGE, JAL, LUI, ADDI, NOP
# Registers:   in x1, x2; checks by control flow only
# Expected:    branches 1, 2, 3 taken; branch 4 not taken
# Depends on:  402, 403
# If it fails: the branch comparator is unsigned
# ============================================================
test_406:
    TEST_START 406
    TBT blt, -1, 1, 1, fail_406, t406a
    TBT blt, 0x80000000, 0x7FFFFFFF, 2, fail_406, t406b
    TBT bge, 0x7FFFFFFF, 0x80000000, 3, fail_406, t406c
    TBN blt, 0x7FFFFFFF, 0x80000000, 4, fail_406

# ============================================================
# TEST 407: the same boundaries read as unsigned
# Purpose:     Every operand pair here also appears in test 406, with the
#              opposite expected outcome.  A machine with one comparator
#              wired to all six conditions cannot pass both tests.
# Instructions: BLTU, BGEU, JAL, LUI, ADDI, NOP
# Registers:   in x1, x2; checks by control flow only
# Expected:    branches 1, 2 not taken; branches 3, 4 taken
# Depends on:  404, 405, 406
# If it fails: br_ltu and br_lt are the same signal
# ============================================================
test_407:
    TEST_START 407
    TBN bltu, -1, 1, 1, fail_407
    TBN bltu, 0x80000000, 0x7FFFFFFF, 2, fail_407
    TBT bgeu, 0x80000000, 0x7FFFFFFF, 3, fail_407, t407a
    TBT bltu, 0x7FFFFFFF, 0x80000000, 4, fail_407, t407b

# ============================================================
# TEST 408: backward branch, taken then not taken
# Purpose:     A negative B-type immediate exercises the sign bit of the
#              scrambled branch offset, and closing the loop proves the
#              branch both fires and stops firing.  The accumulator makes the
#              trip count observable, so a loop that ran the wrong number of
#              times is caught rather than just hanging.
# Instructions: BNE, LUI, ADDI, NOP
# Registers:   in/out x4, x5; checks x5 (sub 2), x4 (sub 3)
# Expected:    x5 = 0x20 (two iterations), x4 = 0
# Depends on:  401
# If it fails: B_TYPE sign extension, or PC + B_Type not wrapping downward
# ============================================================
test_408:
    TEST_START 408
    li   x4, 2                          # iterations remaining
    li   x5, 0                          # accumulator
    PAD
t408_top:
    addi x5, x5, 0x10
    PAD
    addi x4, x4, -1
    PAD
    li   x29, 1
    PAD
    bne  x4, x0, t408_top
    PAD_BR
    CHECK x5, 0x20, 2, fail_408
    CHECK x4, 0, 3, fail_408

# ============================================================
# TEST 409: long-range forward and backward branches
# Purpose:     Everything above uses offsets of a few dozen bytes, which only
#              exercises the low bits of the branch immediate.  This branches
#              forward to a target parked in level 5's fail-stub region and
#              straight back, so both directions run at an offset of over a
#              kilobyte -- see BUILD NOTES for the exact figures.
# Instructions: BEQ, JAL, LUI, ADDI, NOP
# Registers:   out x4; checks x4 (sub 2)
# Expected:    x4 = 0x7E
# Depends on:  400, 408
# If it fails: the upper bits of B_TYPE (imm[11] at ir[7], imm[10:5] at
#              ir[30:25]) are misplaced
#
# The full +/-4 KiB extreme is deliberately not exercised: reaching it would
# need roughly a thousand filler instructions in each direction, which is a
# fifth of the instruction budget spent on NOPs.  The offset used is the
# largest one available for free from the program's own layout.
# ============================================================
test_409:
    TEST_START 409
    li   x4, 0
    li   x29, 1
    PAD
    beq  x0, x0, t409_far               # forward, out of this level entirely
    PAD_BR
    jal  x0, fail_409
t409_back:
    PAD
    CHECK x4, 0x7E, 2, fail_409
    CHECK_NE x4, 0, 3, fail_409

# ============================================================
# TEST 410: a taken branch writes no register
# Purpose:     A B-type instruction has no rd -- ir[11:7] holds immediate
#              bits instead.  If RF_WE leaks on branches, the register named
#              by those bits gets clobbered with the ALU result.
#              For the branch below the target is exactly 12 bytes ahead, so
#              imm[4:1] = 6 and imm[11] = 0, which puts 0b01100 = 12 in
#              ir[11:7].  x12 is therefore the register a leaking write
#              would land on, and it is the one checked.
# Instructions: BEQ, JAL, LUI, ADDI, NOP
# Registers:   in/out x12; checks x12 (sub 2)
# Expected:    x12 = 0x5A5A, unchanged
# Depends on:  400
# If it fails: Control_Unit_Decoder's B-type arm is not clearing RF_WE
# ============================================================
test_410:
    TEST_START 410
    li   x12, 0x5A5A                    # witness on the phantom-rd register
    li   x29, 1
    PAD
    beq  x0, x0, t410a                  # +12: ir[11:7] decodes as x12
    PAD_BR
    jal  x0, fail_410
t410a:
    PAD
    CHECK x12, 0x5A5A, 2, fail_410

    jal  x0, lvl4_done

#-----------------------------------------------------------------------------
# Level 4 fail stubs
#-----------------------------------------------------------------------------
    FAIL_STUB 400
    FAIL_STUB 401
    FAIL_STUB 402
    FAIL_STUB 403
    FAIL_STUB 404
    FAIL_STUB 405
    FAIL_STUB 406
    FAIL_STUB 407
    FAIL_STUB 408
    FAIL_STUB 409
    FAIL_STUB 410
lvl4_done:

#=============================================================================
# LEVEL 5 -- JUMPS
#
# JAL with rd = x0 was proven during bootstrap because the reporting path
# needs it.  This level adds the link value, JALR, and the call/return idiom.
# Every link value is checked against an address the assembler computed, not
# against another PC-producing instruction.
#=============================================================================

# ============================================================
# TEST 500: JAL writes PC+4 into rd
# Purpose:     The link value must be the address of the instruction after
#              the JAL -- not the target, not the JAL's own address.  All
#              three are plausible wrong answers and all three are checked.
# Instructions: JAL, LUI, ADDI, BEQ, BNE, NOP
# Registers:   out x5, x6; checks x5 (sub 1, 2, 3), x6 (sub 4)
# Expected:    x5 = p500 + 4, x6 = 0x5A
# Depends on:  10, 116, 117
# If it fails: reg_MUX port A is not ex_mem_q.PC + 4, or RF_SEL is not
#              WB_PC4 for opcode 1101111
# ============================================================
test_500:
    TEST_START 500
    li   x5, 0
    PAD
p500:
    jal  x5, t500_ok
    PAD_BR
    jal  x0, fail_500
t500_ok:
    addi x6, x0, 0x5A
    PAD
    CHECK_A x5, p500+4, 1, fail_500
    CHECK_A_NE x5, p500, 2, fail_500     # must NOT be the JAL's own address
    CHECK_A_NE x5, t500_ok, 3, fail_500  # must NOT be the branch target
    CHECK x6, 0x5A, 4, fail_500

# ============================================================
# TEST 501: JAL with rd = x0 discards the link
# Purpose:     `jal x0, label` is the unconditional jump idiom this whole
#              program is built on.  It still computes a link value, and that
#              value must be thrown away rather than landing in x0.
# Instructions: JAL, LUI, ADDI, BEQ, BNE, NOP
# Registers:   checks x0 (sub 1, 2), x7 (sub 3)
# Expected:    x0 = 0, x7 = 0x5B
# Depends on:  5, 303, 500
# If it fails: the register-file write gate is bypassed when RF_SEL = WB_PC4
# ============================================================
test_501:
    TEST_START 501
p501:
    jal  x0, t501_ok
    PAD_BR
    jal  x0, fail_501
t501_ok:
    addi x7, x0, 0x5B
    PAD
    CHECK x0, 0, 1, fail_501
    CHECK_A_NE x0, p501+4, 2, fail_501  # the discarded link must not land in x0
    CHECK x7, 0x5B, 3, fail_501

# ============================================================
# TEST 502: backward JAL
# Purpose:     A negative J-type immediate, which exercises the sign bit of
#              the scrambled jump offset.  The counter makes the number of
#              passes observable, so a jump that looped twice fails rather
#              than passing quietly.
# Instructions: JAL, LUI, ADDI, BEQ, BNE, NOP
# Registers:   in/out x8, x9; checks x8 (sub 1), x9 (sub 2)
# Expected:    x8 = 1, x9 = p502b + 4
# Depends on:  500
# If it fails: J_TYPE sign extension, or PC + J_Type not wrapping downward
# ============================================================
test_502:
    TEST_START 502
    li   x8, 0
    PAD
    jal  x0, t502_fwd                   # skip over the backward target
    PAD_BR
t502_back:
    addi x8, x8, 1                      # must run exactly once
    PAD
    jal  x0, t502_done
    PAD_BR
    jal  x0, fail_502
t502_fwd:
p502b:
    jal  x9, t502_back                  # the backward jump under test
    PAD_BR
    jal  x0, fail_502
t502_done:
    PAD
    CHECK x8, 1, 1, fail_502
    CHECK_A x9, p502b+4, 2, fail_502

# ============================================================
# TEST 503: JALR with a positive offset
# Purpose:     JALR builds its target from a register plus a 12-bit signed
#              immediate, which is a different adder and a different
#              immediate format from JAL.  The base is deliberately short of
#              the target so the offset has to be added.
# Instructions: JALR, LUI, ADDI, BEQ, BNE, NOP
# Registers:   in x10 -> out x11, x12; checks x11 (sub 1), x12 (sub 2)
# Expected:    x11 = p503 + 4, x12 = 0x5C
# Depends on:  500, 104
# If it fails: Jump_Branch_Address_Generator's I_Type + rs1, or PC_Decoder's
#              jalr arm
# ============================================================
test_503:
    TEST_START 503
    la   x10, t503_ok-0x40              # base 0x40 short of the target
    PAD
p503:
    jalr x11, x10, 0x40
    PAD_BR
    jal  x0, fail_503
t503_ok:
    addi x12, x0, 0x5C
    PAD
    CHECK_A x11, p503+4, 1, fail_503
    CHECK x12, 0x5C, 2, fail_503

# ============================================================
# TEST 504: JALR with a negative offset
# Purpose:     The JALR immediate is I-type and sign extended.  A DUT that
#              zero-extends it lands 4 KiB past the target.
# Instructions: JALR, LUI, ADDI, BEQ, BNE, NOP
# Registers:   in x13 -> out x14; checks x14 (sub 1)
# Expected:    x14 = 0x5D
# Depends on:  503
# If it fails: I_TYPE sign extension on the JALR path specifically
# ============================================================
test_504:
    TEST_START 504
    la   x13, t504_ok+0x40              # base 0x40 past the target
    PAD
    jalr x0, x13, -0x40
    PAD_BR
    jal  x0, fail_504
t504_ok:
    addi x14, x0, 0x5D
    PAD
    CHECK x14, 0x5D, 1, fail_504

# ============================================================
# TEST 505: JALR clears bit 0 of the computed target
# Purpose:     The ISA requires the low bit of rs1 + imm to be cleared, so
#              that the low bit of a function pointer can carry a tag.  The
#              base here is the target plus 1.
# Instructions: JALR, LUI, ADDI, BEQ, BNE, NOP
# Registers:   in x15 -> out x16; checks x16 (sub 1)
# Expected:    x16 = 0x5E
# Depends on:  503
# If it fails: the & ~1 mask in Jump_Branch_Address_Generator.  Without it
#              the target is misaligned; on this machine IMEM ignores PC[1:0]
#              so it would still land on the right word, which means this
#              test can pass on hardware that has no mask at all -- sub 2
#              below is what actually pins it down
# ============================================================
test_505:
    TEST_START 505
    la   x15, t505_ok
    PAD
    addi x15, x15, 1                    # tag the pointer
    PAD
p505:
    jalr x17, x15, 0
    PAD_BR
    jal  x0, fail_505
t505_ok:
    addi x16, x0, 0x5E
    PAD
    CHECK x16, 0x5E, 1, fail_505
    CHECK_A x17, p505+4, 2, fail_505    # the link is untagged PC+4 regardless

# ============================================================
# TEST 506: JALR where rd and rs1 are the same register
# Purpose:     The target must be computed from the OLD rs1, even though the
#              link value overwrites that same register.  A DUT that writes
#              rd before reading rs1 jumps to the link value instead.
# Instructions: JALR, LUI, ADDI, BEQ, BNE, NOP
# Registers:   in/out x18 -> out x19; checks x18 (sub 1), x19 (sub 2)
# Expected:    x18 = p506 + 4, x19 = 0x5F
# Depends on:  503
# If it fails: the register file write is happening before the operand read,
#              or the JALR base is taken from the writeback mux
# ============================================================
test_506:
    TEST_START 506
    la   x18, t506_ok
    PAD
p506:
    jalr x18, x18, 0                    # rd == rs1
    PAD_BR
    jal  x0, fail_506
t506_ok:
    addi x19, x0, 0x5F
    PAD
    CHECK_A x18, p506+4, 1, fail_506
    CHECK x19, 0x5F, 2, fail_506

# ============================================================
# TEST 507: call and return
# Purpose:     The whole point of the link register.  The subroutine is
#              parked outside the straight-line path, and the return lands
#              back in the caller's shadow slot -- which is why the PAD_BR
#              nop after the call is also the instruction the return arrives
#              at.
# Instructions: JAL, JALR, LUI, ADDI, BEQ, BNE, NOP
# Registers:   x1 as link; out x20, x21; checks sub 1..3
# Expected:    x20 = 0x61 (set by the callee), x21 = 0x62 (set after return),
#              x1 = p507 + 4
# Depends on:  500, 503
# If it fails: if x20 is right but x21 is wrong the return did not come back;
#              if x20 is wrong the call never arrived
# ============================================================
test_507:
    TEST_START 507
    li   x20, 0
    li   x21, 0
    PAD
p507:
    jal  x1, sub507
    PAD_BR                              # shadow slot, and the return target
    addi x21, x0, 0x62                  # runs only after the return
    PAD
    CHECK x20, 0x61, 1, fail_507
    CHECK x21, 0x62, 2, fail_507
    CHECK_A x1, p507+4, 3, fail_507

# ============================================================
# TEST 508: nested call and return
# Purpose:     Two live link registers at once.  The inner call must not
#              disturb the outer one, which is the property that makes a
#              calling convention possible at all.
# Instructions: JAL, JALR, LUI, ADDI, BEQ, BNE, NOP
# Registers:   x1 outer link, x6 inner link; out x22, x23; checks sub 1..4
# Expected:    x22 = 0x63, x23 = 0x64, links intact
# Depends on:  507
# If it fails: both calls are landing in the same link register
# ============================================================
test_508:
    TEST_START 508
    li   x22, 0
    li   x23, 0
    PAD
p508:
    jal  x1, sub508_outer
    PAD_BR
    addi x23, x0, 0x64
    PAD
    CHECK x22, 0x63, 1, fail_508
    CHECK x23, 0x64, 2, fail_508
    CHECK_A x1, p508+4, 3, fail_508

    jal  x0, lvl5_done

#-----------------------------------------------------------------------------
# Level 5 fail stubs, plus the subroutines the level calls into.  Neither the
# stubs nor the subroutines are ever reached by falling through: the jal above
# steps over the whole block.
#-----------------------------------------------------------------------------
    FAIL_STUB 500
    FAIL_STUB 501
    FAIL_STUB 502
    FAIL_STUB 503
    FAIL_STUB 504
    FAIL_STUB 505
    FAIL_STUB 506
    FAIL_STUB 507
    FAIL_STUB 508

sub507:
    addi x20, x0, 0x61
    PAD
    jalr x0, x1, 0                      # return
    PAD_BR
    jal  x0, fail_507                   # the return must not fall through

sub508_outer:
    addi x6, x0, 0                      # inner link register, cleared first
    PAD
p508i:
    jal  x6, sub508_inner
    PAD_BR
    la   x28, p508i+4                   # the inner link, checked in the callee
    PAD
    bne  x6, x28, fail_508
    PAD_BR
    jalr x0, x1, 0                      # return to the outer caller
    PAD_BR
    jal  x0, fail_508

sub508_inner:
    addi x22, x0, 0x63
    PAD
    jalr x0, x6, 0
    PAD_BR
    jal  x0, fail_508

#-----------------------------------------------------------------------------
# Parked target for test 409's long-range branch pair.
#
# It lives here, at the far end of level 5's skipped region, purely for the
# distance: the forward branch from test 409 into this block and the backward
# branch out of it both end up at an offset of roughly two kilobytes instead
# of the few dozen bytes every other branch in this program uses, and that
# costs no filler instructions at all.  Nothing falls into it -- the whole
# region is stepped over by `jal x0, lvl5_done`.
#-----------------------------------------------------------------------------
t409_far:
    addi x4, x0, 0x7E                   # proves control really arrived here
    PAD
    beq  x0, x0, t409_back              # ... and straight back again
    PAD_BR
    jal  x0, fail_409                   # the return branch must not fall through
lvl5_done:

#=============================================================================
# LEVEL 6 -- LOADS AND STORES
#
# Every address here is inside DMEM_BASE .. DMEM_LIMIT (assumption A2) and
# every access is naturally aligned, because finding (7) says misalignment is
# silently dropped rather than trapped and there is nothing to check against.
#
# Each store is separated from the load that reads it back by PAD, so nothing
# in this level depends on the load-use stall -- that is level 9's job.
#=============================================================================

# ============================================================
# TEST 600: SW then LW round trip
# Purpose:     The most basic memory operation, and the foundation of every
#              test below it.  Two different patterns at the same address, so
#              a memory that returns a constant cannot pass.
# Instructions: SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base, x4 stored, x5 loaded; checks x5 (sub 1, 2, 3)
# Expected:    0xA5A5F00D then 0x5A5A0FF0
# Depends on:  100, 200
# If it fails: DMEM's word write case, the ALU address path, or RF_SEL not
#              selecting the memory result for opcode 0000011
# ============================================================
test_600:
    TEST_START 600
    li   x20, M6
    li   x4, 0xA5A5F00D
    PAD
    sw   x4, 0(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0xA5A5F00D, 1, fail_600
    li   x4, 0x5A5A0FF0                 # a second pattern to the same address
    PAD
    sw   x4, 0(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0x5A5A0FF0, 2, fail_600
    CHECK_NE x5, 0xA5A5F00D, 3, fail_600  # the old value must be gone

# ============================================================
# TEST 601: positive and negative displacements
# Purpose:     The store immediate is S-type and the load immediate is
#              I-type -- two different field layouts for the same arithmetic.
#              Using a base in the middle of the scratch area lets both signs
#              be exercised against the same addresses.
# Instructions: SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x5 (sub 1), x6 (sub 2)
# Expected:    0x11112222 at base+0x10, 0x33334444 at base-0x10
# Depends on:  600
# If it fails: S_TYPE field assembly (ir[31:25] and ir[11:7]) or its sign
#              extension
# ============================================================
test_601:
    TEST_START 601
    li   x20, M6+0x20
    li   x4, 0x11112222
    PAD
    sw   x4, 0x10(x20)
    PAD
    li   x4, 0x33334444
    PAD
    sw   x4, -0x10(x20)
    PAD
    lw   x5, 0x10(x20)
    PAD
    CHECK x5, 0x11112222, 1, fail_601
    lw   x6, -0x10(x20)
    PAD
    CHECK x6, 0x33334444, 2, fail_601

# ============================================================
# TEST 602: adjacent words do not alias
# Purpose:     Address-decode arithmetic errors are quiet -- they show up
#              only when two addresses that should be distinct turn out to be
#              the same location.  Four consecutive words, four distinct
#              values, all written before any is read back.
# Instructions: SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x5 (sub 1..4)
# Expected:    0x0000AAA0, 0x0000BBB1, 0x0000CCC2, 0x0000DDD3
# Depends on:  600
# If it fails: the word index is being computed from the wrong address bits,
#              so some pair of these four addresses landed on one word
# ============================================================
test_602:
    TEST_START 602
    li   x20, M6
    li   x4, 0x0000AAA0
    PAD
    sw   x4, 0(x20)
    PAD
    li   x4, 0x0000BBB1
    PAD
    sw   x4, 4(x20)
    PAD
    li   x4, 0x0000CCC2
    PAD
    sw   x4, 8(x20)
    PAD
    li   x4, 0x0000DDD3
    PAD
    sw   x4, 12(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0x0000AAA0, 1, fail_602
    lw   x5, 4(x20)
    PAD
    CHECK x5, 0x0000BBB1, 2, fail_602
    lw   x5, 8(x20)
    PAD
    CHECK x5, 0x0000CCC2, 3, fail_602
    lw   x5, 12(x20)
    PAD
    CHECK x5, 0x0000DDD3, 4, fail_602

# ============================================================
# TEST 603: SB at all four byte offsets
# Purpose:     Byte enables.  Starting from a known word, each byte is
#              rewritten one at a time and the whole word is read back after
#              each step, so a store that hit the wrong lane or splattered
#              across neighbouring lanes is caught immediately rather than
#              being masked by the next store.
# Instructions: SB, SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base, x4 data; checks x5 (sub 1..4)
# Expected:    0x00000011, 0x00002211, 0x00332211, 0x44332211
# Depends on:  600
# If it fails: the {mem_size, byteOffset} write case in DMEM -- x29 names
#              which lane, and the value in x5 shows where the byte went
# ============================================================
test_603:
    TEST_START 603
    li   x20, M6
    PAD
    sw   x0, 0(x20)                     # start from a known-zero word
    PAD
    li   x4, 0x11
    PAD
    sb   x4, 0(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0x00000011, 1, fail_603
    li   x4, 0x22
    PAD
    sb   x4, 1(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0x00002211, 2, fail_603
    li   x4, 0x33
    PAD
    sb   x4, 2(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0x00332211, 3, fail_603
    li   x4, 0x44
    PAD
    sb   x4, 3(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0x44332211, 4, fail_603

# ============================================================
# TEST 604: SB writes only the byte it names
# Purpose:     603 built a word up from zero, so a store that wrote too wide
#              with zeros would have gone unnoticed.  Here the word starts as
#              all-ones and a single byte is overwritten, so any collateral
#              damage to the other three lanes is visible.
# Instructions: SB, SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x5 (sub 1, 2)
# Expected:    0xFFFF7FFF then 0xFF7FFFFF
# Depends on:  603
# If it fails: the byte lane mask is too wide, or the read-modify-write is
#              writing back a stale copy of the other lanes
# ============================================================
test_604:
    TEST_START 604
    li   x20, M6
    li   x4, 0xFFFFFFFF
    PAD
    sw   x4, 0(x20)
    PAD
    li   x4, 0x7F
    PAD
    sb   x4, 2(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0xFF7FFFFF, 1, fail_604
    li   x4, 0xFFFFFFFF
    PAD
    sw   x4, 0(x20)
    PAD
    li   x4, 0x7F
    PAD
    sb   x4, 1(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0xFFFF7FFF, 2, fail_604

# ============================================================
# TEST 605: SH at both aligned halfword offsets
# Purpose:     The halfword lane select, and that a halfword store does not
#              disturb the other half.  Offset 1 is deliberately not used:
#              finding (7) says the RTL does implement it, but the ISA calls
#              it misaligned, so exercising it would be testing a
#              non-standard extension.
# Instructions: SH, SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x5 (sub 1, 2)
# Expected:    0xFFFF1234 then 0x5678FFFF
# Depends on:  603
# If it fails: the {mem_size=01, byteOffset} write cases in DMEM
# ============================================================
test_605:
    TEST_START 605
    li   x20, M6
    li   x4, 0xFFFFFFFF
    PAD
    sw   x4, 0(x20)
    PAD
    li   x4, 0x1234
    PAD
    sh   x4, 0(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0xFFFF1234, 1, fail_605
    li   x4, 0xFFFFFFFF
    PAD
    sw   x4, 0(x20)
    PAD
    li   x4, 0x5678
    PAD
    sh   x4, 2(x20)
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0x5678FFFF, 2, fail_605

# ============================================================
# TEST 606: LB sign extends, in every lane
# Purpose:     0x80 is the byte value whose sign bit is set, so LB must
#              return 0xFFFFFF80 from whichever lane it came out of.  The
#              word is arranged so that each lane holds a different value and
#              only one of them is 0x80, which also proves the lane select is
#              right.
# Instructions: LB, SW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x5 (sub 1..4)
# Expected:    0xFFFFFF80, 0x7F, 1, 0xFFFFFFFF  from lanes 0..3
# Depends on:  600
# If it fails: the {mem_sign=0, mem_size=00, byteOffset} extension cases
# ============================================================
test_606:
    TEST_START 606
    li   x20, M6
    li   x4, 0xFF017F80                 # lane 0 = 0x80, 1 = 0x7F, 2 = 1, 3 = 0xFF
    PAD
    sw   x4, 0(x20)
    PAD
    lb   x5, 0(x20)
    PAD
    CHECK x5, 0xFFFFFF80, 1, fail_606
    lb   x5, 1(x20)
    PAD
    CHECK x5, 0x0000007F, 2, fail_606
    lb   x5, 2(x20)
    PAD
    CHECK x5, 0x00000001, 3, fail_606
    lb   x5, 3(x20)
    PAD
    CHECK x5, 0xFFFFFFFF, 4, fail_606

# ============================================================
# TEST 607: LBU zero extends, in every lane
# Purpose:     The same word as 606 read with the unsigned form.  Every
#              answer must now be in 0..255, so a DUT that ignores ir[14]
#              fails lanes 0 and 3 while still passing 1 and 2.
# Instructions: LBU, SW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x5 (sub 1..4)
# Expected:    0x80, 0x7F, 1, 0xFF
# Depends on:  606
# If it fails: mem_sign is not reaching DMEM, or is inverted
# ============================================================
test_607:
    TEST_START 607
    li   x20, M6
    li   x4, 0xFF017F80
    PAD
    sw   x4, 0(x20)
    PAD
    lbu  x5, 0(x20)
    PAD
    CHECK x5, 0x00000080, 1, fail_607
    lbu  x5, 1(x20)
    PAD
    CHECK x5, 0x0000007F, 2, fail_607
    lbu  x5, 2(x20)
    PAD
    CHECK x5, 0x00000001, 3, fail_607
    lbu  x5, 3(x20)
    PAD
    CHECK x5, 0x000000FF, 4, fail_607

# ============================================================
# TEST 608: LH and LHU on 0x8000, in both halves
# Purpose:     0x8000 is the halfword whose sign bit is set.  Signed and
#              unsigned forms must differ on it, in both halfword positions.
# Instructions: LH, LHU, SW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x5 (sub 1..4)
# Expected:    0xFFFF8000, 0x00008000, 0x00007FFF, 0x00007FFF
# Depends on:  606, 607
# If it fails: the {mem_sign, mem_size=01, byteOffset} extension cases
# ============================================================
test_608:
    TEST_START 608
    li   x20, M6
    li   x4, 0x7FFF8000                 # low half 0x8000, high half 0x7FFF
    PAD
    sw   x4, 0(x20)
    PAD
    lh   x5, 0(x20)
    PAD
    CHECK x5, 0xFFFF8000, 1, fail_608
    lhu  x5, 0(x20)
    PAD
    CHECK x5, 0x00008000, 2, fail_608
    lh   x5, 2(x20)
    PAD
    CHECK x5, 0x00007FFF, 3, fail_608
    lhu  x5, 2(x20)
    PAD
    CHECK x5, 0x00007FFF, 4, fail_608

# ============================================================
# TEST 609: a load into x0 is discarded
# Purpose:     The last of the write paths into x0 (test 303 covered the
#              rest).  Loads reach the register file through a different
#              RF_SEL than everything else, so the write gate has to hold on
#              this path too.
# Instructions: LW, SW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x0 (sub 1, 2), x5 (sub 3)
# Expected:    x0 = 0, and the same address still loads correctly afterwards
# Depends on:  303, 600
# If it fails: the write-enable gate is not applied when RF_SEL = WB_DATA_IN
#
# sub 3 is the cross-check: it proves the address really did hold a nonzero
# value, so sub 1 is not passing because the load returned zero anyway.
# ============================================================
test_609:
    TEST_START 609
    li   x20, M6
    li   x4, 0xDEADBEEF
    PAD
    sw   x4, 0(x20)
    PAD
    lw   x0, 0(x20)                     # must be discarded
    PAD
    CHECK x0, 0, 1, fail_609
    CHECK_NE x0, 0xDEADBEEF, 2, fail_609
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0xDEADBEEF, 3, fail_609

# ============================================================
# TEST 610: a store does not disturb the neighbouring word
# Purpose:     602 checked that distinct addresses stay distinct on write.
#              This checks the other direction: a byte store near a word
#              boundary must not bleed into the next word.
# Instructions: SB, SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x5 (sub 1), x6 (sub 2)
# Expected:    0x99887766 untouched at base+4, byte landed at base+3
# Depends on:  603, 604
# If it fails: the write lane decode is carrying into the next word index
# ============================================================
test_610:
    TEST_START 610
    li   x20, M6
    li   x4, 0x99887766
    PAD
    sw   x0, 0(x20)
    PAD
    sw   x4, 4(x20)                     # the neighbour to protect
    PAD
    li   x4, 0xEE
    PAD
    sb   x4, 3(x20)                     # top byte of the first word
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0xEE000000, 1, fail_610
    lw   x6, 4(x20)
    PAD
    CHECK x6, 0x99887766, 2, fail_610

    jal  x0, lvl6_done

#-----------------------------------------------------------------------------
# Level 6 fail stubs
#-----------------------------------------------------------------------------
    FAIL_STUB 600
    FAIL_STUB 601
    FAIL_STUB 602
    FAIL_STUB 603
    FAIL_STUB 604
    FAIL_STUB 605
    FAIL_STUB 606
    FAIL_STUB 607
    FAIL_STUB 608
    FAIL_STUB 609
    FAIL_STUB 610
lvl6_done:

#=============================================================================
# LEVEL 7 -- SYSTEM INSTRUCTIONS: DELIBERATELY OMITTED
#
# FENCE, ECALL and EBREAK are all left out, and the reasoning is finding (8)
# above.  In short: none of the three is decoded anywhere in this design.
# CPU_pkg::decode_instr_name maps them to UNKNOWN and
# Control_Unit_Decoder.sv's `default:` arm drives every one of its outputs to
# 'X -- RF_WE, memWE, branch_i, jal_i and jalr_i included.  PC_Decoder's
# `unique case({branch_i, jal_i, jalr_i})` cannot match an X, so PC_SEL goes
# to 'X, and Program_Counter's own default turns that into PC = 'X.
#
# So the behaviour is not "implemented", not "NOP", not "trap" and not
# "halt the simulation": executing any of the three destroys the program
# counter and ends the run with no diagnosis.  A test cannot report a failure
# it cannot survive, so there is nothing useful to write here.
#
# The FENCE test below is written out anyway, because FENCE is the one of the
# three that has a defined ISA meaning this pipeline could satisfy trivially
# (it has no store buffer and no caches, so FENCE is legitimately a NOP).
# Flip ENABLE_LEVEL7 to 1 once opcode 0001111 decodes to something that
# leaves the pipeline alone -- and note that doing so before that point will
# hang the machine rather than fail test 700.
#=============================================================================
    .if ENABLE_LEVEL7

# ============================================================
# TEST 700: FENCE does not disturb the instruction stream
# Purpose:     With no caches and no store buffer in this design, FENCE has
#              nothing to order and must behave as a NOP: registers and the
#              instruction stream both carry on unchanged across it.
# Instructions: FENCE, SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   in/out x4, x20; checks x4 (sub 1), x5 (sub 2)
# Expected:    x4 = 0x1357, memory round trip still works after the fence
# Depends on:  600
# If it fails: opcode 0001111 is falling into the decoder's 'X default
# ============================================================
test_700:
    TEST_START 700
    li   x20, M6
    li   x4, 0x1357
    PAD
    fence
    PAD
    CHECK x4, 0x1357, 1, fail_700
    sw   x4, 0(x20)
    PAD
    fence
    PAD
    lw   x5, 0(x20)
    PAD
    CHECK x5, 0x1357, 2, fail_700

    jal  x0, lvl7_done
    FAIL_STUB 700
lvl7_done:
    .endif

#=============================================================================
# LEVEL 8 -- FORWARDING
#
# From here on the padding comes off, but ONLY at the point under test.
# Everything else -- setting up operands, loading expected values, the
# compare itself -- stays PAD-separated, so a failure in this level is
# attributable to the one unpadded producer/consumer pair in the test.
#
# Finding (3) says there are exactly two forwarding sources, both landing in
# EXECUTE: ex_mem_q.ALU_result at distance 1, and mem_wb_q.REG_write_data at
# distance 2 (gated on the producer being a load).  Finding (4) says distance
# 3 needs no forwarding at all.  So distances 1, 2 and 3 are three genuinely
# different mechanisms and each gets its own test.
#
# Tests 817 through 820 are the ones aimed at Forwarding_Unit's match
# condition rather than its data path.  It compares register numbers without
# asking whether the consumer reads that operand at all, and the forwarding
# muxes sit downstream of the srcA/srcB select muxes -- so an immediate, a
# shift amount or a U-type constant can be replaced by a forwarded value that
# was never requested.  Those four tests are built to make that visible.
#=============================================================================

# ============================================================
# TEST 800: EX/MEM -> EX at distance 1, rs1 operand
# Purpose:     The shortest possible dependency: an ALU result consumed by
#              the very next instruction as rs1.  The register file cannot
#              supply this -- the producer has not written yet -- so it can
#              only come from the forwarding path.
# Instructions: ADD, LUI, ADDI, BEQ, BNE
# Registers:   in x4, x5 -> out x6, x7; checks x6 (sub 1), x7 (sub 2)
# Expected:    x6 = 0x120, x7 = 0x140
# Depends on:  200, 600
# If it fails: srcA_FORWARD_SEL is not reaching 2'b01, or the mux B input is
#              not ex_mem_q.ALU_result
#
# sub 1 is the control: it confirms the producer itself was right, so a sub 2
# failure is about forwarding and not about ADD.
# ============================================================
test_800:
    TEST_START 800
    li   x4, 0x100
    li   x5, 0x020
    PAD
    add  x6, x4, x5                     # producer
    add  x7, x6, x5                     # consumer, distance 1, x6 as rs1
    PAD
    CHECK x6, 0x120, 1, fail_800
    CHECK x7, 0x140, 2, fail_800

# ============================================================
# TEST 801: EX/MEM -> EX at distance 1, rs2 operand
# Purpose:     The same dependency through the other operand port.  The two
#              forwarding muxes are separate hardware and a design can very
#              easily have one and not the other.
# Instructions: ADD, LUI, ADDI, BEQ, BNE
# Registers:   in x4, x5 -> out x6, x7; checks x7 (sub 1)
# Expected:    x7 = 0x140
# Depends on:  800
# If it fails: srcB_FORWARD_SEL, or the rs2 comparison in Forwarding_Unit
# ============================================================
test_801:
    TEST_START 801
    li   x4, 0x100
    li   x5, 0x020
    PAD
    add  x6, x4, x5
    add  x7, x5, x6                     # x6 as rs2 this time
    PAD
    CHECK x7, 0x140, 1, fail_801

# ============================================================
# TEST 802: both operands forwarded from one producer
# Purpose:     rs1 and rs2 both matching the same in-flight result.  A
#              forwarding unit written as a priority chain rather than two
#              independent comparators tends to serve only the first match
#              and leave the other operand stale.
# Instructions: ADD, LUI, ADDI, BEQ, BNE
# Registers:   in x4, x5 -> out x6, x7; checks x7 (sub 1)
# Expected:    x7 = 0x240
# Depends on:  800, 801
# If it fails: if x7 reads 0x120 then only one of the two operands was
#              forwarded and the other came from the stale register file
# ============================================================
test_802:
    TEST_START 802
    li   x4, 0x100
    li   x5, 0x020
    PAD
    add  x6, x4, x5                     # x6 = 0x120
    add  x7, x6, x6                     # both operands are x6
    PAD
    CHECK x7, 0x240, 1, fail_802

# ============================================================
# TEST 803: two operands from two different producers
# Purpose:     rs1 needs the result from distance 2 and rs2 the one from
#              distance 1, at the same time.  This needs both forwarding
#              sources active simultaneously and selecting independently.
# Instructions: ADD, SUB, LUI, ADDI, BEQ, BNE
# Registers:   in x4, x5 -> out x6, x8, x9; checks x9 (sub 1)
# Expected:    x9 = 0x120 - 0x200 = 0xFFFFFF20
# Depends on:  802
# If it fails: a priority chain that forces the other operand's select back
#              to "no forwarding" once it has serviced the first match
# ============================================================
test_803:
    TEST_START 803
    li   x4, 0x100
    li   x5, 0x020
    PAD
    add  x6, x4, x5                     # x6 = 0x120, consumed at distance 2
    add  x8, x4, x4                     # x8 = 0x200, consumed at distance 1
    sub  x9, x6, x8
    PAD
    CHECK x9, 0xFFFFFF20, 1, fail_803

# ============================================================
# TEST 804: distance 2, rs1 operand
# Purpose:     Finding (4) says the register file write lands at the end of
#              MEMORY, so a consumer two instructions later still reads the
#              old value and needs the MEM/WB source.  This is a different
#              mux input from test 800, not just a longer version of it.
# Instructions: ADD, NOP, LUI, ADDI, BEQ, BNE
# Registers:   in x4, x5 -> out x6, x7; checks x7 (sub 1)
# Expected:    x7 = 0x140
# Depends on:  800
# If it fails: the MEM/WB -> EX path.  Note that Forwarding_Unit gates that
#              path on WB_DMEM_RDEN, so it only ever fires for loads -- an
#              ALU producer at this distance has no path at all and this test
#              reads the stale register value
# ============================================================
test_804:
    TEST_START 804
    li   x4, 0x100
    li   x5, 0x020
    PAD
    add  x6, x4, x5
    nop                                 # exactly one filler: distance 2
    add  x7, x6, x5
    PAD
    CHECK x7, 0x140, 1, fail_804

# ============================================================
# TEST 805: distance 2, rs2 operand
# Purpose:     The rs2 half of test 804.
# Instructions: ADD, NOP, LUI, ADDI, BEQ, BNE
# Registers:   in x4, x5 -> out x6, x7; checks x7 (sub 1)
# Expected:    x7 = 0x140
# Depends on:  804
# If it fails: the rs2 comparison against WB_REG_WRITE_ADDR
# ============================================================
test_805:
    TEST_START 805
    li   x4, 0x100
    li   x5, 0x020
    PAD
    add  x6, x4, x5
    nop
    add  x7, x5, x6
    PAD
    CHECK x7, 0x140, 1, fail_805

# ============================================================
# TEST 806: distance 3 needs no forwarding at all
# Purpose:     The baseline SAFE_GAP claim that every level below this one
#              depends on.  At distance 3 the producer has committed and the
#              consumer reads it straight out of the register file.  If this
#              fails, the isolation discipline in levels 0-7 was built on
#              sand and their results mean nothing.
# Instructions: ADD, NOP, LUI, ADDI, BEQ, BNE
# Registers:   in x4, x5 -> out x6, x7; checks x7 (sub 1)
# Expected:    x7 = 0x140
# Depends on:  200
# If it fails: fix this before reading any other result in this file
# ============================================================
test_806:
    TEST_START 806
    li   x4, 0x100
    li   x5, 0x020
    PAD
    add  x6, x4, x5
    nop
    nop                                 # SAFE_GAP fillers: distance 3
    add  x7, x6, x5
    PAD
    CHECK x7, 0x140, 1, fail_806

# ============================================================
# TEST 807: with two writes in flight, the newest must win
# Purpose:     Two instructions targeting one register are in the pipeline at
#              once when the consumer reads it.  The forwarding unit has to
#              pick the younger one; a unit that checks the MEM/WB stage
#              before the EX/MEM stage picks the older and delivers a value
#              that was already superseded.
# Instructions: ADDI, ADD, LUI, BEQ, BNE
# Registers:   in/out x10 -> x11; checks x11 (sub 1), x10 (sub 2)
# Expected:    x11 = 0x33, x10 = 0x33
# Depends on:  800, 804
# If it fails: x11 == 0x22 means the stale write won the priority contest
# ============================================================
test_807:
    TEST_START 807
    li   x10, 0x11
    PAD
    addi x10, x0, 0x22                  # older write, distance 2
    addi x10, x0, 0x33                  # newer write, distance 1
    add  x11, x10, x0
    PAD
    CHECK x11, 0x33, 1, fail_807
    CHECK_NE x11, 0x22, 2, fail_807
    CHECK x10, 0x33, 3, fail_807

# ============================================================
# TEST 808: a discarded write to x0 must never be forwarded
# Purpose:     `addi x0, x0, 0x7FF` produces a nonzero ALU result that the
#              register file correctly throws away.  If the forwarding unit
#              matches on register number without excluding x0, that thrown
#              away result gets handed to the next instruction anyway and x0
#              stops reading as zero for exactly one cycle.
# Instructions: ADDI, ADD, BEQ, BNE
# Registers:   out x12, x13; checks x12 (sub 1, 2), x13 (sub 3)
# Expected:    x12 = 0, x13 = 5
# Depends on:  5, 303, 800
# If it fails: Forwarding_Unit needs an `!= 0` term on the write address.
#              This is a quiet bug: every NOP is also a write to x0, so once
#              it exists, any instruction reading x0 with a NOP in flight
#              picks up the NOP's result -- which is 0, so it hides until
#              something writes x0 with a nonzero value
# ============================================================
test_808:
    TEST_START 808
    addi x0, x0, 0x7FF                  # discarded, but the ALU still computed
    add  x12, x0, x0                    # distance 1, x0 on both ports
    PAD
    CHECK x12, 0, 1, fail_808
    CHECK_NE x12, 0x7FF, 2, fail_808
    addi x0, x0, 0x7FF
    addi x13, x0, 5                     # distance 1, x0 as rs1
    PAD
    CHECK x13, 5, 3, fail_808

# ============================================================
# TEST 809: forwarding into store data
# Purpose:     A store's rs2 is its data, and it is read at a different point
#              in the pipeline from the ALU operands.  In this design
#              DATA_OUT is wired to id_ex_q.rs2 directly, which is upstream
#              of the forwarding mux, so this is the test that says whether
#              store data participates in forwarding at all.
# Instructions: ADD, SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base, x14 data; checks x15 (sub 1, 2)
# Expected:    x15 = 0x120
# Depends on:  600, 800
# If it fails: the value stored is whatever x14 held BEFORE the producer --
#              sub 2 checks for exactly that, since x14 was seeded with a
#              recognisable value first
# ============================================================
test_809:
    TEST_START 809
    li   x20, M8
    li   x14, 0x0BAD                    # seed: this must NOT be what lands
    li   x4, 0x100
    li   x5, 0x020
    PAD
    add  x14, x4, x5                    # producer of the store data
    sw   x14, 0(x20)                    # distance 1
    PAD
    lw   x15, 0(x20)
    PAD
    CHECK x15, 0x120, 1, fail_809
    CHECK_NE x15, 0x0BAD, 2, fail_809

# ============================================================
# TEST 810: forwarding into the store address
# Purpose:     The address side of a store goes through the ALU, so unlike
#              the data side it should be forwarded by the ordinary srcA
#              path.  Storing to a forwarded address and reading it back from
#              a separately computed one proves the address was right.
# Instructions: ADDI, SW, LW, LUI, BEQ, BNE
# Registers:   x20 base -> x21 address; checks x17 (sub 1)
# Expected:    x17 = 0x5A5A at M8+8
# Depends on:  809
# If it fails: the store went to the pre-update address, so the value turns
#              up at M8 instead of M8+8 -- sub 2 checks that neighbour
# ============================================================
test_810:
    TEST_START 810
    li   x20, M8
    li   x16, 0x5A5A
    PAD
    sw   x0, 8(x20)                     # clear the destination first
    PAD
    addi x21, x20, 8                    # producer of the address
    sw   x16, 0(x21)                    # distance 1
    PAD
    lw   x17, 8(x20)
    PAD
    CHECK x17, 0x5A5A, 1, fail_810

# ============================================================
# TEST 811: forwarding into the branch comparator
# Purpose:     Branch_Condition_Generator reads id_ex_q.rs1 and id_ex_q.rs2,
#              which are the values latched out of the register file -- not
#              the forwarded operands the ALU sees.  So a branch that depends
#              on the instruction immediately before it compares stale data.
#              Both operand positions are checked.
# Instructions: ADDI, BEQ, BNE, JAL, LUI, NOP
# Registers:   in x18 -> x19, x22; checks by control flow
# Expected:    branch 1 taken, branch 2 not taken
# Depends on:  400, 800
# If it fails: the comparator needs to be fed from srcA_REAL / srcB_REAL
#              rather than from the raw pipeline register
# ============================================================
test_811:
    TEST_START 811
    li   x18, 0x77
    li   x29, 1
    PAD
    addi x19, x0, 0x77                  # producer
    beq  x19, x18, t811a                # distance 1, forwarded into rs1
    PAD_BR
    jal  x0, fail_811
t811a:
    li   x29, 2
    PAD
    addi x22, x0, 0x78                  # producer, deliberately unequal
    beq  x18, x22, fail_811             # distance 1, forwarded into rs2
    PAD_BR

# ============================================================
# TEST 812: forwarding into the JALR base
# Purpose:     Jump_Branch_Address_Generator takes srcA_REAL as its rs1, so
#              the JALR base should be forwarded.  It is the one control-flow
#              operand in this design that is on the forwarded side.
# Instructions: ADDI, JALR, JAL, LA, LUI, BEQ, BNE, NOP
# Registers:   in x23 -> x24; out x25; checks x25 (sub 2)
# Expected:    x25 = 0x68
# Depends on:  503, 800
# If it fails: control lands on the pre-update base, 0x20 short of the target
# ============================================================
test_812:
    TEST_START 812
    la   x23, t812a-0x20
    li   x29, 1
    PAD
    addi x24, x23, 0x20                 # producer of the jump base
    jalr x0, x24, 0                     # distance 1
    PAD_BR
    jal  x0, fail_812
t812a:
    addi x25, x0, 0x68
    PAD
    CHECK x25, 0x68, 2, fail_812

# ============================================================
# TEST 813: forwarding a LUI result
# Purpose:     LUI reaches the ALU through srcA_SEL = srca_U_TYPE rather than
#              through rs1, but its result still goes into ex_mem_q like any
#              other, so it must forward like any other.
# Instructions: LUI, ADDI, BEQ, BNE
# Registers:   out x9 -> x10; checks x10 (sub 1)
# Expected:    x10 = 0x00021010
# Depends on:  100, 800
# If it fails: the forwarding source is being taken from the rs1 read rather
#              than from the EX result
# ============================================================
test_813:
    TEST_START 813
    lui  x9, 0x00021
    addi x10, x9, 0x10                  # distance 1
    PAD
    CHECK x10, 0x00021010, 1, fail_813

# ============================================================
# TEST 814: forwarding an AUIPC result
# Purpose:     Same as 813 for the PC-relative form.
# Instructions: AUIPC, ADDI, LUI, BEQ, BNE
# Registers:   out x11 -> x12; checks x12 (sub 1)
# Expected:    x12 = address of p814
# Depends on:  116, 813
# If it fails: the AUIPC result is not reaching ex_mem_q.ALU_result
# ============================================================
test_814:
    TEST_START 814
p814:
    auipc x11, 0
    addi x12, x11, 0                    # distance 1
    PAD
    CHECK_A x12, p814, 1, fail_814

# ============================================================
# TEST 815: forwarding a JAL link value
# Purpose:     JAL's writeback comes from the PC+4 path, NOT from the ALU
#              result -- reg_MUX selects port A for RF_SEL = WB_PC4 while the
#              ALU was busy computing something meaningless.  If the
#              forwarding network taps ALU_result rather than the writeback
#              mux output, a JAL link consumed early delivers that garbage.
# Instructions: JAL, ADDI, LA, LUI, BEQ, BNE, NOP
# Registers:   out x13 -> x14; checks x14 (sub 1)
# Expected:    x14 = p815 + 4
# Depends on:  500, 813
# If it fails: the EX/MEM forwarding source needs to be the writeback value,
#              not ex_mem_q.ALU_result
#
# The consumer here is the first instruction at the jump target.  That is two
# pipeline slots behind the JAL rather than one, because the squashed shadow
# slot sits in between -- so this exercises the MEM/WB source, not EX/MEM.
# ============================================================
test_815:
    TEST_START 815
p815:
    jal  x13, t815a
    PAD_BR
    jal  x0, fail_815
t815a:
    addi x14, x13, 0                    # first instruction at the target
    PAD
    CHECK_A x14, p815+4, 1, fail_815

# ============================================================
# TEST 816: forwarding a JALR link value
# Purpose:     The JALR half of test 815.  JALR's ALU result is rs1 + rs2 --
#              srcB_SEL is left at its default for this opcode -- so the
#              garbage on the ALU path is different garbage, and a forwarding
#              network tapping the wrong signal fails differently.
# Instructions: JALR, ADDI, LA, LUI, BEQ, BNE, NOP
# Registers:   in x15 -> out x16, x17; checks x17 (sub 1)
# Expected:    x17 = p816 + 4
# Depends on:  503, 815
# If it fails: same root cause as 815
# ============================================================
test_816:
    TEST_START 816
    la   x15, t816a
    PAD
p816:
    jalr x16, x15, 0
    PAD_BR
    jal  x0, fail_816
t816a:
    addi x17, x16, 0
    PAD
    CHECK_A x17, p816+4, 1, fail_816

# ============================================================
# TEST 817: an immediate must not be replaced by a forwarded value
# Purpose:     For an I-type instruction, ir[24:20] is not a register number
#              -- it is imm[4:0].  A forwarding unit that compares it against
#              the in-flight write address anyway will sometimes decide the
#              immediate "matches" and substitute a register value for it.
#              Whether that happens depends on the low 5 bits of the
#              immediate, which makes it look like random data corruption.
#
#              sub 1 uses immediate 0x27, whose low 5 bits are 7, one
#              instruction after a write to x7.
#              sub 3 uses a shift of 4, one instruction after a write to x4,
#              so the corrupted shift amount is 0x3C0 & 0x1F = 0 and the
#              value comes back unshifted.
# Instructions: ADDI, SLLI, LUI, BEQ, BNE
# Registers:   in x8 -> out x9, x11; checks x9 (sub 1, 2), x11 (sub 3)
# Expected:    x9 = 0x1027, x11 = 0x10000
# Depends on:  103, 112, 800
# If it fails: Forwarding_Unit must qualify its rs2 match with "this opcode
#              actually reads rs2"
# ============================================================
test_817:
    TEST_START 817
    li   x8, 0x1000
    PAD
    addi x7, x0, 0x555                  # writes x7
    addi x9, x8, 0x27                   # imm[4:0] = 7: phantom rs2 == x7
    PAD
    CHECK x9, 0x1027, 1, fail_817
    CHECK_NE x9, 0x1555, 2, fail_817    # x8 + x7, the corrupted answer
    addi x4, x0, 0x3C0                  # writes x4
    slli x11, x8, 4                     # shamt 4: phantom rs2 == x4
    PAD
    CHECK x11, 0x10000, 3, fail_817

# ============================================================
# TEST 818: a U-type constant must not be replaced by a forwarded value
# Purpose:     The rs1 counterpart of test 817.  LUI and AUIPC have no rs1 --
#              ir[19:15] holds imm20[7:3].  The immediate below is 0x000A8,
#              whose bits [7:3] are 0b10101 = 21, so a forwarding unit that
#              does not check whether the opcode reads rs1 will splice x21's
#              value in where the shifted constant belongs.
# Instructions: LUI, AUIPC, ADDI, BEQ, BNE
# Registers:   in x21 -> out x12, x13; checks x12 (sub 1, 2), x13 (sub 3)
# Expected:    x12 = 0x000A8000, x13 = p818 + 0xA8000
# Depends on:  100, 116, 813
# If it fails: Forwarding_Unit must qualify its rs1 match with "this opcode
#              actually reads rs1".  This one bites harder than 817 because
#              every NOP writes x0 and every `lui` with a small immediate has
#              ir[19:15] = 0, so the two match constantly
# ============================================================
test_818:
    TEST_START 818
    addi x21, x0, 0x2AA                 # writes x21
    lui  x12, 0x000A8                   # ir[19:15] = 21: phantom rs1 == x21
    PAD
    CHECK x12, 0x000A8000, 1, fail_818
    CHECK_NE x12, 0x2AA, 2, fail_818
    addi x21, x0, 0x2AA
p818:
    auipc x13, 0x000A8                  # same trap on the PC-relative form
    PAD
    CHECK_A x13, p818+0xA8000, 3, fail_818

# ============================================================
# TEST 819: no forwarding from an instruction that writes no register
# Purpose:     A store has no rd -- ir[11:7] holds imm[4:0].  For the store
#              below that field reads as 8, so a forwarding unit that ignores
#              RF_WE would hand the store's ALU result (its ADDRESS, since
#              that is what the ALU computed) to the next instruction reading
#              x8.
# Instructions: SW, ADD, LUI, ADDI, BEQ, BNE
# Registers:   in x8, x14 -> out x15; checks x15 (sub 1, 2, 3)
# Expected:    x15 = 0x1234, the real contents of x8
# Depends on:  600, 800
# If it fails: the MEM_REG_WE term is missing from the match condition.
#              sub 2 checks for the store's address specifically, which is
#              what a leak would actually deliver
# ============================================================
test_819:
    TEST_START 819
    li   x20, M8
    li   x8, 0x1234                     # witness on the phantom-rd register
    li   x14, 0x9
    PAD
    sw   x14, 8(x20)                    # ir[11:7] = 8, but RF_WE is 0
    add  x15, x8, x0                    # distance 1, reads x8
    PAD
    CHECK x15, 0x1234, 1, fail_819
    CHECK_NE x15, M8+8, 2, fail_819     # the store address, if it leaked
    CHECK_NE x15, 0x9, 3, fail_819      # the store data, if that leaked

# ============================================================
# TEST 820: no forwarding from a branch
# Purpose:     The same check as 819 for the other instruction class with no
#              rd.  For a B-type, ir[11:7] is {imm[4:1], imm[11]}; the branch
#              below jumps 24 bytes forward, which puts 0b11000 = 24 in that
#              field.  x24 is therefore the register a leak would clobber.
# Instructions: BEQ, ADD, NOP, LUI, ADDI, BNE
# Registers:   in x24 -> out x18; checks x18 (sub 1), x24 (sub 2)
# Expected:    x18 = 0x4321, x24 = 0x4321
# Depends on:  410, 819
# If it fails: Control_Unit_Decoder's B-type arm leaves RF_WE set, or the
#              forwarding match ignores it
# ============================================================
test_820:
    TEST_START 820
    li   x24, 0x4321                    # witness on the phantom-rd register
    li   x16, 1
    li   x17, 2
    PAD
    beq  x16, x17, t820a                # not taken; +24 puts 24 in ir[11:7]
    add  x18, x24, x0                   # distance 1, reads x24
    nop
    nop
    nop
    nop
t820a:
    PAD
    CHECK x18, 0x4321, 1, fail_820
    CHECK x24, 0x4321, 2, fail_820

    jal  x0, lvl8_done

#-----------------------------------------------------------------------------
# Level 8 fail stubs
#-----------------------------------------------------------------------------
    FAIL_STUB 800
    FAIL_STUB 801
    FAIL_STUB 802
    FAIL_STUB 803
    FAIL_STUB 804
    FAIL_STUB 805
    FAIL_STUB 806
    FAIL_STUB 807
    FAIL_STUB 808
    FAIL_STUB 809
    FAIL_STUB 810
    FAIL_STUB 811
    FAIL_STUB 812
    FAIL_STUB 813
    FAIL_STUB 814
    FAIL_STUB 815
    FAIL_STUB 816
    FAIL_STUB 817
    FAIL_STUB 818
    FAIL_STUB 819
    FAIL_STUB 820
lvl8_done:

#=============================================================================
# LEVEL 9 -- HAZARDS
#
# Two families.  Tests 900-911 are load-use: a load's result consumed before
# the memory read has committed, which is the one case in this design that
# cannot be solved by forwarding alone and needs the pipeline to stall.
# Tests 912-920 are control: whatever is sitting in the shadow of a taken
# branch or a jump must leave no trace.
#
# Finding (5) says the intended load-use cost is a single stall cycle, and
# finding (2) says the shadow is exactly one instruction.  Both are asserted
# here by observing architectural state, never by counting cycles -- a test
# that counted cycles would fail for performance reasons rather than
# correctness ones.
#=============================================================================

# ============================================================
# TEST 900: load-use at distance 1, rs1
# Purpose:     The canonical load-use hazard.  The load's data is not
#              available until the end of MEMORY, so the consumer in EXECUTE
#              behind it has to be held for a cycle.
# Instructions: LW, SW, ADDI, LUI, BEQ, BNE
# Registers:   x20 base -> x5 loaded -> x6; checks x5 (sub 1), x6 (sub 2)
# Expected:    x5 = 0x1234, x6 = 0x1235
# Depends on:  600, 800
# If it fails: sub 1 failing means the load itself did not commit -- check
#              whether FLUSH_EX_MEM is clearing the very load the stall was
#              raised for.  sub 1 passing with sub 2 failing means the stall
#              is not happening and the consumer read a stale register
# ============================================================
test_900:
    TEST_START 900
    li   x20, M9
    li   x4, 0x1234
    PAD
    sw   x4, 0(x20)
    PAD
    lw   x5, 0(x20)
    addi x6, x5, 1                      # distance 1, x5 as rs1
    PAD
    CHECK x5, 0x1234, 1, fail_900
    CHECK x6, 0x1235, 2, fail_900

# ============================================================
# TEST 901: load-use at distance 1, rs2
# Purpose:     The other operand port.  SUB is used rather than ADD so that
#              an operand swap cannot hide inside a symmetric result.
# Instructions: LW, SUB, LUI, ADDI, BEQ, BNE
# Registers:   in x7 -> out x6; checks x6 (sub 1)
# Expected:    x6 = 0x2000 - 0x1234 = 0x0DCC
# Depends on:  900
# If it fails: the rs2 comparison in the load-use detection
# ============================================================
test_901:
    TEST_START 901
    li   x20, M9
    li   x7, 0x2000
    li   x4, 0x1234
    PAD
    sw   x4, 0(x20)
    PAD
    lw   x5, 0(x20)
    sub  x6, x7, x5                     # distance 1, x5 as rs2
    PAD
    CHECK x6, 0x0DCC, 1, fail_901

# ============================================================
# TEST 902: load-use at distance 1, both operands
# Purpose:     One load feeding both operand ports of the next instruction.
# Instructions: LW, ADD, LUI, ADDI, BEQ, BNE
# Registers:   out x6; checks x6 (sub 1)
# Expected:    x6 = 0x2468
# Depends on:  900, 901
# If it fails: only one of the two operand comparisons raises the stall
# ============================================================
test_902:
    TEST_START 902
    li   x20, M9
    li   x4, 0x1234
    PAD
    sw   x4, 0(x20)
    PAD
    lw   x5, 0(x20)
    add  x6, x5, x5
    PAD
    CHECK x6, 0x2468, 1, fail_902

# ============================================================
# TEST 903: load feeding store data at distance 1
# Purpose:     A load immediately followed by a store of what it loaded --
#              the inner loop of every memcpy.  Store data is read from a
#              different pipeline register than the ALU operands, so it needs
#              its own stall term.
# Instructions: LW, SW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base; checks x6 (sub 1, 2)
# Expected:    x6 = 0x1234 read back from base+4
# Depends on:  809, 900
# If it fails: sub 2 checks for zero specifically, which is what lands if the
#              store wrote before the load delivered
# ============================================================
test_903:
    TEST_START 903
    li   x20, M9
    PAD
    sw   x0, 4(x20)                     # clear the destination
    PAD
    lw   x5, 0(x20)
    sw   x5, 4(x20)                     # distance 1, load result as store data
    PAD
    lw   x6, 4(x20)
    PAD
    CHECK x6, 0x1234, 1, fail_903
    CHECK_NE x6, 0, 2, fail_903

# ============================================================
# TEST 904: load feeding a store address at distance 1
# Purpose:     A loaded pointer used immediately as a destination address.
# Instructions: LW, SW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base, x10 loaded pointer; checks x11 (sub 1)
# Expected:    0xABC lands at M9+8
# Depends on:  810, 900
# If it fails: the stall is qualified on the consumer being an ALU op rather
#              than on it reading the register at all
# ============================================================
test_904:
    TEST_START 904
    li   x20, M9
    li   x8, M9+8
    li   x9, 0xABC
    PAD
    sw   x8, 0x0C(x20)                  # plant a pointer to M9+8
    PAD
    sw   x0, 8(x20)
    PAD
    lw   x10, 0x0C(x20)
    sw   x9, 0(x10)                     # distance 1, loaded value as address
    PAD
    lw   x11, 8(x20)
    PAD
    CHECK x11, 0xABC, 1, fail_904

# ============================================================
# TEST 905: load feeding the branch comparator at distance 1
# Purpose:     A branch on a just-loaded value.  This combines the two
#              weakest paths in the design: the comparator reads the
#              unforwarded pipeline register, and the load has not committed.
# Instructions: LW, SW, BEQ, JAL, LUI, ADDI, NOP
# Registers:   in x12; checks by control flow
# Expected:    the branch is taken
# Depends on:  811, 900
# If it fails: the branch resolves on a stale operand, so it falls through to
#              the fail stub
# ============================================================
test_905:
    TEST_START 905
    li   x20, M9
    li   x12, 0x1234
    PAD
    sw   x12, 0(x20)
    PAD
    li   x29, 1
    PAD
    lw   x5, 0(x20)
    beq  x5, x12, t905a                 # distance 1 into the comparator
    PAD_BR
    jal  x0, fail_905
t905a:

# ============================================================
# TEST 906: load feeding the JALR base at distance 1
# Purpose:     An indirect jump through a just-loaded function pointer --
#              the shape every vtable and jump table produces.
# Instructions: LW, SW, JALR, JAL, LA, LUI, ADDI, NOP
# Registers:   x14 loaded pointer -> out x15; checks x15 (sub 2)
# Expected:    x15 = 0x71
# Depends on:  812, 900
# If it fails: control goes to whatever x14 held before the load
# ============================================================
test_906:
    TEST_START 906
    li   x20, M9
    la   x13, t906a
    PAD
    sw   x13, 0x10(x20)
    PAD
    li   x29, 1
    PAD
    lw   x14, 0x10(x20)
    jalr x0, x14, 0                     # distance 1 into the jump base
    PAD_BR
    jal  x0, fail_906
t906a:
    addi x15, x0, 0x71
    PAD
    CHECK x15, 0x71, 2, fail_906

# ============================================================
# TEST 907: a load whose address comes from the previous load
# Purpose:     Pointer chasing.  Two load-use stalls back to back, with the
#              second load's address depending on the first load's data.
# Instructions: LW, SW, LUI, ADDI, BEQ, BNE
# Registers:   x10 pointer -> x11 value; checks x11 (sub 1)
# Expected:    x11 = 0x00C0FFEE
# Depends on:  904
# If it fails: the second stall is being suppressed because the first one is
#              still in progress
# ============================================================
test_907:
    TEST_START 907
    li   x20, M9
    li   x8, M9+8
    li   x9, 0x00C0FFEE
    PAD
    sw   x8, 0x0C(x20)
    PAD
    sw   x9, 8(x20)
    PAD
    lw   x10, 0x0C(x20)
    lw   x11, 0(x10)                    # address from the load in front of it
    PAD
    CHECK x11, 0x00C0FFEE, 1, fail_907

# ============================================================
# TEST 908: load-use at distance 2
# Purpose:     One instruction of slack.  By finding (4) the load's data is
#              in MEM/WB by now and Forwarding_Unit's WB path -- the one
#              gated on WB_DMEM_RDEN -- is exactly the case built for this.
#              No stall should be needed.
# Instructions: LW, NOP, ADDI, LUI, BEQ, BNE
# Registers:   out x6; checks x6 (sub 1)
# Expected:    x6 = 0x1235
# Depends on:  900
# If it fails: the WB_DMEM_RDEN-gated forwarding path
# ============================================================
test_908:
    TEST_START 908
    li   x20, M9
    li   x4, 0x1234
    PAD
    sw   x4, 0(x20)
    PAD
    lw   x5, 0(x20)
    nop
    addi x6, x5, 1
    PAD
    CHECK x6, 0x1235, 1, fail_908

# ============================================================
# TEST 909: load-use at distance 3
# Purpose:     Full SAFE_GAP separation: the load has committed to the
#              register file and no hazard logic should be involved at all.
#              If 908 fails and this passes, the problem is specifically the
#              forwarding path rather than the load.
# Instructions: LW, NOP, ADDI, LUI, BEQ, BNE
# Registers:   out x6; checks x6 (sub 1)
# Expected:    x6 = 0x1235
# Depends on:  600, 806
# If it fails: loads are not reaching the register file at all
# ============================================================
test_909:
    TEST_START 909
    li   x20, M9
    li   x4, 0x1234
    PAD
    sw   x4, 0(x20)
    PAD
    lw   x5, 0(x20)
    nop
    nop
    addi x6, x5, 1
    PAD
    CHECK x6, 0x1235, 1, fail_909

# ============================================================
# TEST 910: a load into x0, then an immediate use of x0
# Purpose:     A load targeting x0 still occupies the pipeline as a write to
#              register 0.  Hazard logic that matches on the address without
#              excluding x0 will raise a stall for it and, worse, forward the
#              loaded data as if x0 had changed.
# Instructions: LW, ADD, ADDI, LUI, BEQ, BNE
# Registers:   out x16, x17; checks x16 (sub 1, 2), x17 (sub 3)
# Expected:    x16 = 0, x17 = 3
# Depends on:  609, 808
# If it fails: the load-use detection needs the same `!= 0` term as the
#              forwarding match
# ============================================================
test_910:
    TEST_START 910
    li   x20, M9
    li   x4, 0x1234
    PAD
    sw   x4, 0(x20)
    PAD
    lw   x0, 0(x20)                     # discarded, but still in flight
    add  x16, x0, x0                    # distance 1
    PAD
    CHECK x16, 0, 1, fail_910
    CHECK_NE x16, 0x1234, 2, fail_910
    lw   x0, 0(x20)
    addi x17, x0, 3
    PAD
    CHECK x17, 3, 3, fail_910

# ============================================================
# TEST 911: two loads into the same register, then a use
# Purpose:     Both loads are in flight at once and both name the same
#              destination.  The consumer must see the second one.
# Instructions: LW, SW, ADD, LUI, ADDI, BEQ, BNE
# Registers:   out x10, x11; checks x10 (sub 1), x11 (sub 2, 3)
# Expected:    x10 = 0x2222, x11 = 0x2222
# Depends on:  807, 900
# If it fails: x11 == 0x1111 means the older load won
# ============================================================
test_911:
    TEST_START 911
    li   x20, M9
    li   x8, 0x1111
    li   x9, 0x2222
    PAD
    sw   x8, 0x14(x20)
    PAD
    sw   x9, 0x18(x20)
    PAD
    lw   x10, 0x14(x20)
    lw   x10, 0x18(x20)                 # same destination, one behind
    add  x11, x10, x0
    PAD
    CHECK x10, 0x2222, 1, fail_911
    CHECK x11, 0x2222, 2, fail_911
    CHECK_NE x11, 0x1111, 3, fail_911

# ============================================================
# TEST 912: a register write in the shadow of a taken branch
# Purpose:     BR_SHADOW is 1, so exactly one instruction is fetched behind a
#              taken branch and it must leave no trace.  An ADDI to a witness
#              register is the most visible thing to put there.
# Instructions: BEQ, ADDI, LUI, BNE
# Registers:   in/out x17; checks x17 (sub 1, 2)
# Expected:    x17 = 0 -- the shadow instruction did not execute
# Depends on:  400
# If it fails: Hazard_FLUSH_ID_EX is not squashing the shadow.  Note the
#              HazardUnit derives its branch_i from the DECODE-stage decoder
#              but its PC_SEL from EXECUTE, so the flush only fires when the
#              shadow instruction happens to itself be a branch -- an ADDI in
#              the shadow, as here, would survive
# ============================================================
test_912:
    TEST_START 912
    li   x17, 0
    li   x29, 1
    PAD
    beq  x0, x0, t912a
    addi x17, x0, 0x5A                  # SHADOW: must be squashed
t912a:
    PAD
    CHECK x17, 0, 1, fail_912
    CHECK_NE x17, 0x5A, 2, fail_912

# ============================================================
# TEST 913: a memory write in the shadow of a taken branch
# Purpose:     The same squash requirement for the side effect that cannot be
#              undone.  A store that executes in a shadow corrupts memory
#              permanently, which is strictly worse than a stray register
#              write.
# Instructions: BEQ, SW, LW, LUI, ADDI, BNE
# Registers:   x20 base, x18 data; checks x19 (sub 1, 2)
# Expected:    memory at base+0x1C still 0
# Depends on:  600, 912
# If it fails: the store in the shadow reached the memory write enable
# ============================================================
test_913:
    TEST_START 913
    li   x20, M9
    li   x18, 0x1357
    PAD
    sw   x0, 0x1C(x20)                  # known-zero destination
    PAD
    li   x29, 1
    PAD
    beq  x0, x0, t913a
    sw   x18, 0x1C(x20)                 # SHADOW: must be squashed
t913a:
    PAD
    lw   x19, 0x1C(x20)
    PAD
    CHECK x19, 0, 1, fail_913
    CHECK_NE x19, 0x1357, 2, fail_913

# ============================================================
# TEST 914: a register write in the shadow of a JAL
# Purpose:     JAL resolves in the same stage as a branch but through a
#              different arm of the hazard logic, so it needs its own case.
# Instructions: JAL, ADDI, LUI, BEQ, BNE
# Registers:   in/out x21; checks x21 (sub 1)
# Expected:    x21 = 0
# Depends on:  10, 912
# If it fails: the jal arm of HazardUnit.  Watch for the opposite failure
#              too: that arm keys off the DECODE-stage jal_i, which squashes
#              the JAL itself rather than its shadow
# ============================================================
test_914:
    TEST_START 914
    li   x21, 0
    li   x29, 1
    PAD
    jal  x0, t914a
    addi x21, x0, 0x5B                  # SHADOW: must be squashed
t914a:
    PAD
    CHECK x21, 0, 1, fail_914

# ============================================================
# TEST 915: a memory write in the shadow of a JAL
# Purpose:     The store version of 914.
# Instructions: JAL, SW, LW, LUI, ADDI, BEQ, BNE
# Registers:   x20 base, x22 data; checks x23 (sub 1)
# Expected:    memory at base+0x20 still 0
# Depends on:  913, 914
# If it fails: the shadow store reached memory
# ============================================================
test_915:
    TEST_START 915
    li   x20, M9
    li   x22, 0x2468
    PAD
    sw   x0, 0x20(x20)
    PAD
    li   x29, 1
    PAD
    jal  x0, t915a
    sw   x22, 0x20(x20)                 # SHADOW: must be squashed
t915a:
    PAD
    lw   x23, 0x20(x20)
    PAD
    CHECK x23, 0, 1, fail_915

# ============================================================
# TEST 916: register and memory writes in the shadow of a JALR
# Purpose:     The indirect-jump arm of the hazard logic.  Only one
#              instruction fits in the shadow, so the two side effects are
#              checked with two separate jumps.
# Instructions: JALR, SW, LW, ADDI, LA, LUI, BEQ, BNE
# Registers:   in/out x25; x20 base, x26 data; checks x25 (sub 1), x27 (sub 2)
# Expected:    x25 = 0, memory at base+0x24 still 0
# Depends on:  503, 914, 915
# If it fails: the jalr arm of HazardUnit
# ============================================================
test_916:
    TEST_START 916
    li   x20, M9
    li   x25, 0
    li   x26, 0x9999
    PAD
    sw   x0, 0x24(x20)
    PAD
    la   x24, t916a
    li   x29, 1
    PAD
    jalr x0, x24, 0
    addi x25, x0, 0x5C                  # SHADOW: must be squashed
t916a:
    PAD
    CHECK x25, 0, 1, fail_916
    la   x24, t916b
    PAD
    jalr x0, x24, 0
    sw   x26, 0x24(x20)                 # SHADOW: must be squashed
t916b:
    PAD
    lw   x27, 0x24(x20)
    PAD
    CHECK x27, 0, 2, fail_916

# ============================================================
# TEST 917: a branch sitting at the target of a branch
# Purpose:     Back to back redirects, with the second branch as the first
#              instruction at the first branch's target.  The second branch
#              has to resolve correctly even though it entered the pipeline
#              through a redirect rather than sequentially.
# Instructions: BEQ, JAL, LUI, ADDI, BNE, NOP
# Registers:   out x4; checks x4 (sub 2)
# Expected:    x4 = 0x81
# Depends on:  400, 912
# If it fails: the redirect is not being applied to the instruction fetched
#              immediately after a redirect
# ============================================================
test_917:
    TEST_START 917
    li   x29, 1
    PAD
    beq  x0, x0, t917a
    PAD_BR
    jal  x0, fail_917
t917a:
    beq  x0, x0, t917b                  # a branch at a branch target
    PAD_BR
    jal  x0, fail_917
t917b:
    addi x4, x0, 0x81
    PAD
    CHECK x4, 0x81, 2, fail_917

# ============================================================
# TEST 918: a JAL sitting at the target of a JAL
# Purpose:     The jump version of 917.
# Instructions: JAL, LUI, ADDI, BEQ, BNE, NOP
# Registers:   out x5; checks x5 (sub 2)
# Expected:    x5 = 0x82
# Depends on:  10, 917
# If it fails: same shape as 917 but through the jal arm
# ============================================================
test_918:
    TEST_START 918
    li   x29, 1
    PAD
    jal  x0, t918a
    PAD_BR
    jal  x0, fail_918
t918a:
    jal  x0, t918b                      # a jump at a jump target
    PAD_BR
    jal  x0, fail_918
t918b:
    addi x5, x0, 0x82
    PAD
    CHECK x5, 0x82, 2, fail_918

# ============================================================
# TEST 919: a taken branch immediately behind a load-use stall
# Purpose:     The stall and the flush want opposite things from the same
#              pipeline registers in the same cycle -- the stall wants to
#              hold ID/EX, the flush wants to clear it.  This is where a
#              design that handles each correctly in isolation comes apart.
#              The load-use pair sits directly in front of the branch so the
#              two events overlap.
# Instructions: LW, SW, ADDI, BEQ, LUI, BNE
# Registers:   x8 loaded -> x9; witness x6; checks x9 (sub 1), x6 (sub 2)
# Expected:    x9 = 0x34, x6 = 0 (the shadow was squashed)
# Depends on:  900, 912
# If it fails: sub 1 wrong means the stall lost to the flush; sub 2 wrong
#              means the flush lost to the stall
# ============================================================
test_919:
    TEST_START 919
    li   x20, M9
    li   x6, 0
    li   x7, 0x33
    PAD
    sw   x7, 0x28(x20)
    PAD
    li   x29, 1
    PAD
    lw   x8, 0x28(x20)
    addi x9, x8, 1                      # load-use pair: this stalls
    beq  x0, x0, t919a                  # ... and this redirects behind it
    addi x6, x0, 0x5D                   # SHADOW: must be squashed
t919a:
    PAD
    CHECK x9, 0x34, 1, fail_919
    CHECK x6, 0, 2, fail_919

# ============================================================
# TEST 920: a not-taken branch followed immediately by dependents
# Purpose:     The common case, and the one a too-eager flush breaks.  When a
#              branch is not taken, the instructions behind it are not a
#              shadow -- they are ordinary code and must execute, including
#              their own back-to-back forwarding.
# Instructions: BEQ, ADDI, ADD, LUI, BNE
# Registers:   in x10, x11 -> out x12, x13; checks x12 (sub 2), x13 (sub 3)
# Expected:    x12 = 0x11, x13 = 0x12
# Depends on:  800, 912
# If it fails: the flush is firing on branch resolution regardless of the
#              outcome, so the two instructions after every branch are lost
# ============================================================
test_920:
    TEST_START 920
    li   x10, 1
    li   x11, 2
    li   x29, 1
    PAD
    beq  x10, x11, fail_920             # not taken
    addi x12, x10, 0x10                 # must execute, depends on x10
    add  x13, x12, x10                  # ... and on x12 at distance 1
    PAD
    CHECK x12, 0x11, 2, fail_920
    CHECK x13, 0x12, 3, fail_920

    jal  x0, lvl9_done

#-----------------------------------------------------------------------------
# Level 9 fail stubs
#-----------------------------------------------------------------------------
    FAIL_STUB 900
    FAIL_STUB 901
    FAIL_STUB 902
    FAIL_STUB 903
    FAIL_STUB 904
    FAIL_STUB 905
    FAIL_STUB 906
    FAIL_STUB 907
    FAIL_STUB 908
    FAIL_STUB 909
    FAIL_STUB 910
    FAIL_STUB 911
    FAIL_STUB 912
    FAIL_STUB 913
    FAIL_STUB 914
    FAIL_STUB 915
    FAIL_STUB 916
    FAIL_STUB 917
    FAIL_STUB 918
    FAIL_STUB 919
    FAIL_STUB 920
lvl9_done:

#=============================================================================
# LEVEL 10 -- COMBINED PROGRAMS
#
# Ordinary code, written the way a compiler would emit it: no PAD anywhere,
# dependencies at whatever distance the algorithm happens to produce, loops
# whose backward branch is taken many times and then once not taken.
#
# Levels 0-9 test mechanisms one at a time.  These test the interactions
# between them, and they are the tests most likely to catch something that
# only goes wrong on a particular combination -- a forward into a branch that
# closes a loop, a load-use pair that straddles a backward jump.
#
# Each program computes a result that is checked against a constant worked
# out by hand, not against a second computation on the machine under test.
#=============================================================================

# ============================================================
# TEST 1000: sum of 1..10 in a counted loop
# Purpose:     The smallest complete program: an accumulator, an induction
#              variable and a backward branch, all dependent on each other at
#              distance 1.  The loop-closing branch reads a register written
#              by the instruction directly in front of it on every iteration.
# Instructions: ADD, ADDI, BLT, LUI, BEQ, BNE
# Registers:   x5 accumulator, x6 counter; checks x5 (sub 1), x6 (sub 2)
# Expected:    x5 = 55, x6 = 11
# Depends on:  404, 800, 920
# If it fails: a sum that is low by a multiple of the last addend means
#              iterations were lost; x6 != 11 means the loop ran the wrong
#              number of times
# ============================================================
test_1000:
    TEST_START 1000
    li   x5, 0
    li   x6, 1
    li   x7, 11
t1000_loop:
    add  x5, x5, x6
    addi x6, x6, 1
    blt  x6, x7, t1000_loop             # reads x6 at distance 1
    PAD
    CHECK x5, 55, 1, fail_1000
    CHECK x6, 11, 2, fail_1000

# ============================================================
# TEST 1001: fill an array, then sum it back
# Purpose:     Two loops over the same memory, the second reading what the
#              first wrote.  The pointer increment feeds the next iteration's
#              address, so every iteration has a load or store whose address
#              was computed two instructions earlier.
# Instructions: SW, LW, ADD, ADDI, BLT, MV, LUI, BEQ, BNE
# Registers:   x20 base, x5 sum, x8 value; checks x5 (sub 1), x8 (sub 2)
# Expected:    values 1,4,7,...,22 -- sum 92, final value 25
# Depends on:  600, 900, 1000
# If it fails: a sum that is a multiple of 8 short of 92 means a store or a
#              load was lost at the loop boundary
# ============================================================
test_1001:
    TEST_START 1001
    li   x20, M10
    li   x6, 0
    li   x7, 8
    li   x8, 1
    mv   x9, x20
t1001_fill:
    sw   x8, 0(x9)
    addi x8, x8, 3
    addi x9, x9, 4
    addi x6, x6, 1
    blt  x6, x7, t1001_fill
    li   x5, 0
    li   x6, 0
    mv   x9, x20
t1001_sum:
    lw   x10, 0(x9)
    add  x5, x5, x10                    # load-use at distance 1
    addi x9, x9, 4
    addi x6, x6, 1
    blt  x6, x7, t1001_sum
    PAD
    CHECK x5, 92, 1, fail_1001
    CHECK x8, 25, 2, fail_1001

# ============================================================
# TEST 1002: signed minimum and maximum of an array
# Purpose:     A scan with two data-dependent forward branches inside the
#              loop body, so the path through the body differs from iteration
#              to iteration.  Signed comparison against negative entries is
#              the part that a BGE with the wrong comparator gets wrong.
# Instructions: LW, SW, BGE, BLT, SLLI, ADD, ADDI, MV, LUI, BEQ, BNE
# Registers:   x5 max, x6 min; checks x5 (sub 1), x6 (sub 2)
# Expected:    max 17, min -100 (0xFFFFFF9C)
# Depends on:  402, 403, 1001
# If it fails: a max of 5 means the forward branches never fell through; a
#              min of 0 means the signed compare treated -100 as large
# ============================================================
test_1002:
    TEST_START 1002
    li   x20, M10
    li   x4, 5
    sw   x4, 0(x20)
    li   x4, -3
    sw   x4, 4(x20)
    li   x4, 17
    sw   x4, 8(x20)
    li   x4, -100
    sw   x4, 12(x20)
    li   x4, 0
    sw   x4, 16(x20)
    li   x4, 17
    sw   x4, 20(x20)
    li   x4, -1
    sw   x4, 24(x20)
    li   x4, 9
    sw   x4, 28(x20)
    lw   x5, 0(x20)                     # seed both from element 0
    mv   x6, x5
    li   x7, 1
    li   x8, 8
t1002_loop:
    slli x9, x7, 2
    add  x9, x9, x20
    lw   x10, 0(x9)
    bge  x5, x10, t1002_nomax           # load-use into a branch
    mv   x5, x10
t1002_nomax:
    bge  x10, x6, t1002_nomin
    mv   x6, x10
t1002_nomin:
    addi x7, x7, 1
    blt  x7, x8, t1002_loop
    PAD
    CHECK x5, 17, 1, fail_1002
    CHECK x6, 0xFFFFFF9C, 2, fail_1002

# ============================================================
# TEST 1003: byte-at-a-time copy between two buffers
# Purpose:     A load and a store in every iteration, at different byte
#              offsets, with both addresses computed inside the loop.  This
#              is the test that catches a byte-enable bug that only shows up
#              when the lane changes from one iteration to the next.
# Instructions: LBU, SB, SW, LW, ADD, ADDI, BLT, LUI, BEQ, BNE
# Registers:   x20 source, x21 destination; checks x11 (sub 1), x12 (sub 2)
# Expected:    both words copied intact
# Depends on:  603, 607, 1001
# If it fails: compare the two words -- a single wrong byte names the lane,
#              and a whole wrong word means the address stepped wrongly
# ============================================================
test_1003:
    TEST_START 1003
    li   x20, M10
    li   x21, M10B
    li   x4, 0x44332211
    sw   x4, 0(x20)
    li   x4, 0x88776655
    sw   x4, 4(x20)
    sw   x0, 0(x21)
    sw   x0, 4(x21)
    li   x6, 0
    li   x7, 8
t1003_loop:
    add  x8, x20, x6
    lbu  x9, 0(x8)                      # address forwarded at distance 1
    add  x10, x21, x6
    sb   x9, 0(x10)                     # store address at distance 1
    addi x6, x6, 1
    blt  x6, x7, t1003_loop
    PAD
    lw   x11, 0(x21)
    PAD
    CHECK x11, 0x44332211, 1, fail_1003
    lw   x12, 4(x21)
    PAD
    CHECK x12, 0x88776655, 2, fail_1003

# ============================================================
# TEST 1004: length of a NUL-terminated string
# Purpose:     A loop whose exit condition is data rather than a count, so
#              the machine cannot get the right answer by running the body a
#              fixed number of times.  The exit branch tests a byte that was
#              loaded one instruction earlier.
# Instructions: LBU, SW, BEQ, ADDI, JAL, MV, LUI, BNE
# Registers:   x5 length; checks x5 (sub 1), x7 (sub 2)
# Expected:    "Hello" -- length 5, terminator 0
# Depends on:  607, 905, 1000
# If it fails: a length of 8 means the terminator was missed and the scan ran
#              into the next word
# ============================================================
test_1004:
    TEST_START 1004
    li   x20, M10
    li   x4, 0x6C6C6548                 # 'H','e','l','l'
    sw   x4, 0(x20)
    li   x4, 0x0000006F                 # 'o', NUL, NUL, NUL
    sw   x4, 4(x20)
    li   x5, 0
    mv   x6, x20
t1004_loop:
    lbu  x7, 0(x6)
    beq  x7, x0, t1004_done             # load-use into a branch
    addi x5, x5, 1
    addi x6, x6, 1
    jal  x0, t1004_loop
t1004_done:
    PAD
    CHECK x5, 5, 1, fail_1004
    CHECK x7, 0, 2, fail_1004

# ============================================================
# TEST 1005: bubble sort of six words
# Purpose:     The most demanding program here: nested loops, a conditional
#              swap that makes the control path depend on the data, and two
#              loads plus two stores to adjacent addresses inside the body.
#              Getting all six outputs right requires essentially everything
#              below this level to work at once.
# Instructions: LW, SW, BGE, BLT, SLLI, ADD, ADDI, SUB, JAL, LUI, BEQ, BNE
# Registers:   x20 base; checks the sorted array (sub 1..6)
# Expected:    5,2,9,1,7,3 sorts to 1,2,3,5,7,9
# Depends on:  1002, 1003
# If it fails: a partially sorted result means iterations were lost; a
#              permutation containing a duplicate means a swap wrote one half
#              and not the other
# ============================================================
test_1005:
    TEST_START 1005
    li   x20, M10
    li   x4, 5
    sw   x4, 0(x20)
    li   x4, 2
    sw   x4, 4(x20)
    li   x4, 9
    sw   x4, 8(x20)
    li   x4, 1
    sw   x4, 12(x20)
    li   x4, 7
    sw   x4, 16(x20)
    li   x4, 3
    sw   x4, 20(x20)
    li   x5, 6
    li   x6, 0
t1005_outer:
    li   x7, 0
    addi x8, x5, -1
    sub  x8, x8, x6                     # inner bound: n-1-i
t1005_inner:
    bge  x7, x8, t1005_inext
    slli x9, x7, 2
    add  x9, x9, x20
    lw   x10, 0(x9)
    lw   x11, 4(x9)
    bge  x11, x10, t1005_noswap         # in order already
    sw   x11, 0(x9)
    sw   x10, 4(x9)
t1005_noswap:
    addi x7, x7, 1
    jal  x0, t1005_inner
t1005_inext:
    addi x6, x6, 1
    blt  x6, x5, t1005_outer
    PAD
    lw   x12, 0(x20)
    PAD
    CHECK x12, 1, 1, fail_1005
    lw   x12, 4(x20)
    PAD
    CHECK x12, 2, 2, fail_1005
    lw   x12, 8(x20)
    PAD
    CHECK x12, 3, 3, fail_1005
    lw   x12, 12(x20)
    PAD
    CHECK x12, 5, 4, fail_1005
    lw   x12, 16(x20)
    PAD
    CHECK x12, 7, 5, fail_1005
    lw   x12, 20(x20)
    PAD
    CHECK x12, 9, 6, fail_1005

# ============================================================
# TEST 1006: multiply by shift and add
# Purpose:     RV32I has no multiplier, so this is how a multiply actually
#              gets done -- and it leans entirely on the shifter and on a
#              data-dependent branch inside a loop that terminates on a
#              shifted-out value rather than on a count.
# Instructions: ANDI, SLLI, SRLI, ADD, BEQ, BNE, LUI, ADDI
# Registers:   x5 multiplicand, x6 multiplier, x7 product
# Expected:    0x51 * 0x2B = 81 * 43 = 3483 = 0xD9B
# Depends on:  110, 112, 113, 1000
# If it fails: a product that is a clean multiple of the multiplicand short
#              of 3483 means a partial product was skipped; a wildly large
#              one means SRLI sign extended and the loop over-ran
# ============================================================
test_1006:
    TEST_START 1006
    li   x5, 0x51
    li   x6, 0x2B
    li   x7, 0
t1006_loop:
    andi x9, x6, 1
    beq  x9, x0, t1006_skip             # distance 1 into the comparator
    add  x7, x7, x5
t1006_skip:
    slli x5, x5, 1
    srli x6, x6, 1
    bne  x6, x0, t1006_loop
    PAD
    CHECK x7, 0xD9B, 1, fail_1006

# ============================================================
# TEST 1007: a subroutine called from inside a loop
# Purpose:     The calling convention under load.  popcount is called three
#              times with three different arguments; the caller's loop state
#              lives in x18..x21 across every call, and the callee's own loop
#              runs 32 iterations in between.  If the link register or any
#              caller register does not survive, the total comes out wrong.
# Instructions: JAL, JALR, LW, SW, ANDI, SRLI, ADD, ADDI, SLLI, BLT, LUI,
#               BEQ, BNE
# Registers:   x18 total, x1 link; checks x18 (sub 1), x19 (sub 2)
# Expected:    popcount(0xDEADBEEF) + popcount(0xFFFF) + popcount(0x80000001)
#              = 24 + 16 + 2 = 42
# Depends on:  508, 1006
# If it fails: a total of 24 means only the first call returned; a hang means
#              the link register was clobbered by the callee
# ============================================================
test_1007:
    TEST_START 1007
    li   x20, M10
    li   x4, 0xDEADBEEF
    sw   x4, 0(x20)
    li   x4, 0x0000FFFF
    sw   x4, 4(x20)
    li   x4, 0x80000001
    sw   x4, 8(x20)
    li   x18, 0
    li   x19, 0
    li   x21, 3
t1007_loop:
    slli x5, x19, 2
    add  x5, x5, x20
    lw   x10, 0(x5)                     # argument in x10
    jal  x1, popcount
    add  x18, x18, x11                  # result in x11, at distance 1
    addi x19, x19, 1
    blt  x19, x21, t1007_loop
    PAD
    CHECK x18, 42, 1, fail_1007
    CHECK x19, 3, 2, fail_1007

    jal  x0, lvl10_done

#-----------------------------------------------------------------------------
# Level 10 fail stubs, plus the one subroutine this level calls.
#-----------------------------------------------------------------------------
    FAIL_STUB 1000
    FAIL_STUB 1001
    FAIL_STUB 1002
    FAIL_STUB 1003
    FAIL_STUB 1004
    FAIL_STUB 1005
    FAIL_STUB 1006
    FAIL_STUB 1007

# popcount: counts the set bits of x10, returns in x11.
# Clobbers x10, x12, x13, x14 and nothing else -- in particular it leaves x1
# alone, which is what makes it callable from inside test 1007's loop.
popcount:
    li   x11, 0
    li   x12, 0
    li   x14, 32
t_popcount_loop:
    andi x13, x10, 1
    add  x11, x11, x13
    srli x10, x10, 1
    addi x12, x12, 1
    blt  x12, x14, t_popcount_loop
    jalr x0, x1, 0
lvl10_done:

#=============================================================================
# EPILOGUE -- park loops
#
# Order matters here.  pass_loop comes first and fail_loop last, so that a
# machine broken badly enough to fall out of a two-instruction self-loop
# drifts toward reporting FAILURE rather than toward a false pass.  The
# `li x30, 99` in between makes that drift explicit instead of leaving the
# pass signature sitting in x30.
#=============================================================================
pass_seq:
    li   x30, PASS_SIG
    li   x31, TOTAL_TESTS
    PAD
    .if TOHOST_EN
    li   x27, TOHOST_ADDR
    PAD
    sw   x30, 0(x27)                    # visible on CPU_TOP's WE/DATA_* pins
    PAD
    .endif

pass_loop:
    jal  x0, pass_loop                  # PASSED: x30 = 0x600D0000, x31 = count
    beq  x0, x0, pass_loop              # backstop if JAL is broken
    li   x30, 99                        # unreachable unless JAL *and* BEQ are
                                        # both broken; poison the signature so
                                        # a runaway machine cannot read as pass
fail_loop:
    jal  x0, fail_loop                  # FAILED: x30 = test, x29 = sub-check,
    beq  x0, x0, fail_loop              #         x31 = progress

#=============================================================================
# BUILDING AND RUNNING
#
# 1. Assemble and link at address 0.  -march=rv32i keeps the assembler from
#    quietly accepting an instruction this CPU does not implement; without it
#    a typo like `mul` assembles fine and then decodes to 'X on the DUT.
#
#      riscv64-unknown-elf-as  -march=rv32i -mabi=ilp32 \
#          -o rv32i_selftest.o tb/rv32i_selftest.S
#      riscv64-unknown-elf-ld  -m elf32lriscv -Ttext=0x0 \
#          -o rv32i_selftest.elf rv32i_selftest.o
#
# 2. Produce the $readmemh image IMEM.sv expects -- one 32-bit word per line,
#    no addresses, no 0x prefix:
#
#      riscv64-unknown-elf-objcopy -O binary rv32i_selftest.elf selftest.bin
#      od -An -tx4 -v -w4 selftest.bin | tr -d ' ' > imem.mem
#
#    DMEM.sv also calls $readmemh("ram.mem"), so it needs a file to exist even
#    though this program writes everything it reads:
#
#      python -c "print('00000000\n'*8192, end='')" > ram.mem
#
# 3. Keep the disassembly next to you.  Every fail code in x30 is a test
#    number, and the listing is how you turn that back into a source line:
#
#      riscv64-unknown-elf-objdump -d rv32i_selftest.elf > rv32i_selftest.lst
#
# 4. Elaborate and run.  Package first, and +rwc so the register file and the
#    pipeline registers are visible in the waveform database:
#
#      xrun -sv -access +rwc -timescale 1ns/1ps \
#           rtl/PIPELINE_REG_STRUCT_PKG.sv \
#           rtl/*.sv \
#           tb/<your_top_tb>.sv
#
# 5. Read the result out of the register file once the machine parks:
#
#      x30 == 0x600D0000 and x31 == TOTAL_TESTS  ->  every test passed
#      x30 == a test number                      ->  that test failed, and
#                                                    x29 says which sub-check
#      x30 == 99                                 ->  JAL and BEQ are both
#                                                    broken; nothing above
#                                                    this line can be trusted
#
#    In SimVision the fastest read is to plot x30 and x31 as a waveform: x31
#    steps through the test numbers in order, so wherever it stops climbing is
#    where the machine died, even if it never reached a park loop.
#=============================================================================
