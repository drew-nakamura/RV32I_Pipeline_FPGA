`timescale 1ns/1ps
//============================================================================
// Testbench: CPU_TOP_tb
// DUT:       ../rtl/CPU_TOP.sv
// Stage:     whole pipeline (FETCH through WB)
// Date:      9/18/2026
//
// Role in system:
//   CPU_TOP is the 5-stage core. IMEM is inside it and is the only instruction
//   source; DMEM lives in MCU_WRAPPER as memory-mapped I/O and is intentionally
//   not in this bench. DATA_IN is tied to 0, so a load that does retire writes
//   zero, and IOBUS_WE is observed but not scored against a memory model.
//
// Verification strategy:
//   Load a $readmemh image into IMEM, clock the core at the same 50 MHz the
//   wrapper uses, and let the program run for a fixed cycle budget. This is a
//   program-level smoke harness, not an ISA scoreboard: the independent checks
//   are the architectural invariants that must hold for ANY legal RV32I image
//   (reset PC, IALIGN, x0). The register file dump at the end is how you
//   inspect whether YOUR .mem did what you think it did.
//
// How to point IMEM at a program (do not edit CPU_TOP):
//   xrun ... -defparam CPU_TOP_tb.dut.IMEM.MEM_FILE=\"myprog.mem\"
//   or compile with  -define IMEM_MEM_FILE=\"myprog.mem\"
//   The .mem path is resolved from the directory you launch xrun in.
//============================================================================

//----------------------------------------------------------------------------
// CONTRACT UNDER TEST
//----------------------------------------------------------------------------
// FUNC-1  While RST is asserted, PC is 32'h0. Program_Counter is combinational
//         and reset is its highest-priority input.              [CPU_TOP.sv]
// FUNC-2  After RST releases, PC[1:0] stays 2'b00. RV32I IALIGN is 32; a
//         defined PC that is not word-aligned is a fetch bug, not a legal
//         compressed instruction.                             [ISA Vol I 1.2]
// FUNC-3  x0 remains 32'h0 for the whole run, regardless of any write the
//         pipeline tries to aim at it.                         [ISA Vol I 2.1]
// FUNC-4  After RST releases, PC is a defined (non-X) value. An X PC means
//         PC_SEL was X: usually an X opcode from an unloaded IMEM word
//         hitting Control_Unit_Decoder's default, or PC_Decoder's unique
//         case falling to default.
//
// TIME-1  CLK is 50 MHz (20 ns period), matching MCU_WRAPPER's divided clock.
//         The core is not run at the 100 MHz board clock.
// TIME-2  RST is held for several rising edges so IMEM's synchronous read can
//         produce a defined instruction and PC_USED at address 0 BEFORE reset
//         is released. IMEM has no reset of its own; one posedge with PC=0 is
//         the minimum, this TB holds more so the fill is not a race.
// TIME-3  After RST deasserts, the core is allowed exactly RUN_CYCLES rising
//         edges and then the bench stops. There is no tohost / ecall retire
//         condition -- the budget IS the test.
// TIME-4  RST is released on a negedge so Program_Counter's combinational PC
//         (PC_USED + 4) is stable a half period before the next IMEM sample.
//         Releasing on the posedge is a same-edge race with IMEM. [INVENTED]
//
// ASSUME-1 DATA_IN is tied to 0. Loads that retire write 0 into the register
//          file. No DMEM, no MMIO, no store data check.         [INVENTED]
// ASSUME-2 IMEM.MEM_FILE exists and $readmemh succeeds. Unloaded words stay
//          X; an X opcode makes Control_Unit_Decoder drive 'X on every
//          control output, which poisons PC_SEL and then PC. A program that
//          runs off the end of its .mem will fail FUNC-2 / the X-on-PC
//          watch as a consequence, not as a separate memory bug. [INVENTED]
// ASSUME-3 The image is register/branch/jump code. Stores still toggle
//          IOBUS_WE (driven combinationally from EX) but nothing consumes
//          DATA_OUT. A store in the image is not a TB failure.  [INVENTED]
// ASSUME-4 Hierarchical probes of dut.PC, dut.ir, dut.instruction,
//          dut.PC_SEL, dut.REG_FILE.registers[] are legal under -access +rwc.
//          Those nets are not on the CPU_TOP port list.         [INVENTED]
//----------------------------------------------------------------------------

`ifndef IMEM_MEM_FILE
  `define IMEM_MEM_FILE "garbagestuff.mem"
`endif

import CPU_pkg::*;

module CPU_TOP_tb;

    //------------------------------------------------------------------------
    // Parameters
    //------------------------------------------------------------------------
    localparam int unsigned CLK_PERIOD  = 20;     // 50 MHz
    localparam int unsigned RESET_CYCLES = 8;     // TIME-2: IMEM fill under RST
    localparam int unsigned RUN_CYCLES  = 10000;
    localparam int unsigned TRACE_HEAD  = 32;     // full trace through pipe fill
    localparam int unsigned TRACE_STRIDE = 256;   // then periodic heartbeat

    //------------------------------------------------------------------------
    // DUT signals
    //------------------------------------------------------------------------
    logic        RST;
    logic        CLK;
    logic [31:0] DATA_IN;
    logic [2:0]  mem_data;
    logic [31:0] DATA_ADDRESS;
    logic [31:0] DATA_OUT;
    logic        IOBUS_RDEN;
    logic        IOBUS_WE;

    int checks = 0;
    int errors = 0;

    int unsigned cycle_i;
    int unsigned pc_x_cycles;
    int unsigned misalign_cycles;
    int unsigned x0_bad_cycles;
    int unsigned ir_x_cycles;
    int unsigned store_cycles;
    int unsigned load_cycles;
    bit          pc_x_reported;
    bit          misalign_reported;
    bit          x0_reported;
    bit          ir_x_reported;

    CPU_TOP dut (
        .RST          (RST),
        .CLK          (CLK),
        .DATA_IN      (DATA_IN),
        .mem_data     (mem_data),
        .DATA_ADDRESS (DATA_ADDRESS),
        .DATA_OUT     (DATA_OUT),
        .IOBUS_RDEN   (IOBUS_RDEN),
        .IOBUS_WE     (IOBUS_WE)
    );

    // CPU_TOP does not expose IMEM's file parameter, so the override has to
    // punch through the instance. Command-line -defparam wins over this if
    // you pass one.
    defparam dut.IMEM.MEM_FILE = `IMEM_MEM_FILE;

    //------------------------------------------------------------------------
    // Clock -- 50 MHz, same rate the wrapper feeds the core
    //------------------------------------------------------------------------
    initial CLK = 1'b0;
    always #(CLK_PERIOD/2) CLK = ~CLK;

    //------------------------------------------------------------------------
    // Golden fragments. These are ISA facts, not a transcription of the RTL.
    // A full ISS is out of scope for a cycle-budget harness; x0 and IALIGN
    // are the two properties that do not depend on which .mem you loaded.
    //------------------------------------------------------------------------
    function automatic logic [31:0] x0_ref();
        return 32'h0;
    endfunction

    function automatic bit pc_word_aligned(input logic [31:0] pc);
        return (pc[1:0] === 2'b00);
    endfunction

    //------------------------------------------------------------------------
    // Checker. `cond` is the already-evaluated predicate so the caller can
    // use === on the probed net; we still tag every call with its contract
    // line so a fail names the bucket without opening a waveform.
    //------------------------------------------------------------------------
    task automatic check(
        input string tag,
        input string note,
        input bit    cond
    );
        checks++;
        if (!cond) begin
            errors++;
            $error("[%0t] FAIL [%s] %s", $time, tag, note);
        end
    endtask

    //------------------------------------------------------------------------
    // Per-cycle invariants sampled after the posedge NBA update. Repeat
    // failures are tallied, not printed 10000 times -- the first message is
    // the one that tells you what broke; the tally at the end tells you how
    // long it stayed broken.
    //------------------------------------------------------------------------
    task automatic sample_invariants();
        logic [31:0] pc_now;
        logic [31:0] ir_now;
        logic [31:0] x0_now;
        pc_sel_e     pcsel_now;
        instr_name_e iname;

        pc_now    = dut.PC;
        ir_now    = dut.ir;
        x0_now    = dut.REG_FILE.registers[0];
        pcsel_now = pc_sel_e'(dut.PC_SEL);
        iname     = dut.instruction;

        // FUNC-1 only applies while RST is high; checked in apply_reset().

        // Repeat failures are counted, not reprinted. The first $error names
        // the bug; the end-of-run tally says how long it lasted.
        checks++;
        if ($isunknown(pc_now)) begin
            pc_x_cycles++;
            if (!pc_x_reported) begin
                pc_x_reported = 1'b1;
                errors++;
                $error("[%0t] FAIL [FUNC-4] PC went X. Usual causes: the .mem ended and an X opcode poisoned PC_SEL, or PC_Decoder's unique-case default fired.",
                       $time);
            end
        end
        else if (!pc_word_aligned(pc_now)) begin
            misalign_cycles++;
            if (!misalign_reported) begin
                misalign_reported = 1'b1;
                errors++;
                $error("[%0t] FAIL [FUNC-2] IALIGN: PC=0x%08h is not word-aligned (PC_SEL=%s ir=0x%08h %s)",
                       $time, pc_now, pcsel_now.name(), ir_now, iname.name());
            end
        end

        checks++;
        if (x0_now !== x0_ref()) begin
            x0_bad_cycles++;
            if (!x0_reported) begin
                x0_reported = 1'b1;
                errors++;
                $error("[%0t] FAIL [FUNC-3] x0=0x%08h, expected 0x%08h",
                       $time, x0_now, x0_ref());
            end
        end

        if ($isunknown(ir_now)) begin
            ir_x_cycles++;
            if (!ir_x_reported) begin
                ir_x_reported = 1'b1;
                $display("[%0t] NOTE [ASSUME-2] ir is X at PC=0x%08h. $readmemh missed this word, or fetch walked off the image.",
                         $time, pc_now);
            end
        end

        if (IOBUS_WE === 1'b1)   store_cycles++;
        if (IOBUS_RDEN === 1'b1) load_cycles++;
    endtask

    task automatic maybe_trace();
        bit          interesting;
        pc_sel_e     pcsel_now;
        instr_name_e iname;

        pcsel_now = pc_sel_e'(dut.PC_SEL);
        iname     = dut.instruction;
        interesting = (cycle_i < TRACE_HEAD) ||
                      ((cycle_i % TRACE_STRIDE) == 0) ||
                      (dut.PC_SEL !== pc_PC4) ||
                      (IOBUS_WE === 1'b1);

        if (interesting)
            $display("[%0t] cyc=%0d PC=0x%08h ir=0x%08h %s PC_SEL=%s WE=%0b RDEN=%0b ALU=0x%08h",
                     $time, cycle_i, dut.PC, dut.ir, iname.name(),
                     pcsel_now.name(), IOBUS_WE, IOBUS_RDEN, dut.ALU_result);
    endtask

    task automatic apply_reset();
        int i;
        RST     = 1'b1;
        DATA_IN = 32'h0;

        // TIME-2: clock under reset so IMEM can register PC=0 into ir / PC_USED.
        for (i = 0; i < RESET_CYCLES; i++) begin
            @(posedge CLK);
            #1;
            check("FUNC-1",
                  $sformatf("RST held, cycle %0d: PC must be 0, got 0x%08h", i, dut.PC),
                  dut.PC === 32'h0);
        end

        // After the fill, ir at address 0 should be a real instruction if the
        // .mem actually loaded. One warning, not a hard fail -- an all-X image
        // is a file problem, and the X-on-PC watch will catch the fallout.
        if ($isunknown(dut.ir))
            $display("[%0t] NOTE [ASSUME-2] ir is still X after %0d reset cycles. Check that %s is visible to xrun.",
                     $time, RESET_CYCLES, `IMEM_MEM_FILE);

        // TIME-4: drop RST on a negedge so PC's combo update is not racing IMEM.
        @(negedge CLK);
        RST = 1'b0;
        $display("[%0t] RST released; running %0d cycles at %0d ns period",
                 $time, RUN_CYCLES, CLK_PERIOD);
    endtask

    task automatic dump_regfile();
        int i;
        $display("----- register file after %0d cycles -----", RUN_CYCLES);
        for (i = 0; i < 32; i++)
            $display("  x%0d = 0x%08h", i, dut.REG_FILE.registers[i]);
    endtask

    //------------------------------------------------------------------------
    // Directed: reset contract, then the cycle-budget run. There is no
    // constrained-random sweep -- the input is the .mem image.
    //------------------------------------------------------------------------
    initial begin
        $display("===== CPU_TOP_tb =====");
        $display("IMEM_MEM_FILE = %s", `IMEM_MEM_FILE);
        $display("CLK           = %0d ns period (%0d MHz)", CLK_PERIOD, 1000/CLK_PERIOD);
        $display("RUN_CYCLES    = %0d", RUN_CYCLES);

        apply_reset();

        for (cycle_i = 0; cycle_i < RUN_CYCLES; cycle_i++) begin
            @(posedge CLK);
            #1;                    // let NBA on IMEM / pipeline regs / RF settle
            sample_invariants();
            maybe_trace();
        end

        dump_regfile();

        $display("----- run stats -----");
        $display("  PC was X for            %0d / %0d cycles", pc_x_cycles, RUN_CYCLES);
        $display("  PC misaligned for       %0d / %0d cycles", misalign_cycles, RUN_CYCLES);
        $display("  x0 nonzero for          %0d / %0d cycles", x0_bad_cycles, RUN_CYCLES);
        $display("  ir was X for            %0d / %0d cycles", ir_x_cycles, RUN_CYCLES);
        $display("  IOBUS_WE asserted        %0d cycles (stores; not scored)", store_cycles);
        $display("  IOBUS_RDEN asserted      %0d cycles (loads; DATA_IN=0)", load_cycles);

        //--------------------------------------------------------------------
        // Coverage / completeness notes
        //
        //   - No store/load data checks: DMEM is I/O in the wrapper and is
        //     not instantiated here (ASSUME-1 / ASSUME-3).
        //   - No forwarding/hazard directed sequences: those belong in
        //     Forwarding_Unit_tb / HazardUnit_tb. This harness only sees
        //     them if the .mem happens to exercise them.
        //   - No instruction-by-instruction scoreboard. If you want that,
        //     it is a core-level ISS, not this file.
        //--------------------------------------------------------------------

        $display("=========================================");
        $display(" %0d / %0d checks passed", checks - errors, checks);
        $display("=========================================");

        if (errors) $fatal(1, "CPU_TOP_tb: %0d check(s) failed", errors);
        $finish;
    end

    // Waveforms: uncomment for SimVision, then 'simvision waves.shm &'
    // initial begin
    //     $shm_open("waves.shm");
    //     $shm_probe("AS");
    // end

endmodule

// ---------------------------------------------------------------------------
// XCELIUM RUN NOTES  (run from tb/ on nanoHUB)
// ---------------------------------------------------------------------------
// Put the program image where xrun can see it (this directory, or an
// absolute path in the defparam). IMEM's default name is garbagestuff.mem.
//
// Single-shot compile + elaborate + run, pointing IMEM at myprog.mem:
//
//   xrun -sv -timescale 1ns/1ps -access +rwc -l CPU_TOP_tb.log \
//        -defparam CPU_TOP_tb.dut.IMEM.MEM_FILE=\"myprog.mem\" \
//        ../rtl/PIPELINE_REG_STRUCT_PKG.sv \
//        ../rtl/2_To_1_MUX.sv \
//        ../rtl/4_TO_1_MUX.sv \
//        ../rtl/ALU.sv \
//        ../rtl/Branch_Condition_Generator.sv \
//        ../rtl/Program_Counter.sv \
//        ../rtl/IMEM.sv \
//        ../rtl/Reg_File.sv \
//        ../rtl/Control_Unit_Decoder.sv \
//        ../rtl/Immediate_Generator.sv \
//        ../rtl/PC_Decoder.sv \
//        ../rtl/Jump_Branch_Address_Generator.sv \
//        ../rtl/Forwarding_Unit.sv \
//        ../rtl/HazardUnit.sv \
//        ../rtl/CPU_TOP.sv \
//        CPU_TOP_tb.sv
//
//   -sv              treat inputs as SystemVerilog
//   -access +rwc     required: the TB probes dut.PC / dut.REG_FILE.registers
//   -l <file>        tee the transcript to a log you can grep for FAIL
//   -clean           add this to force a full rebuild if a stale INCA_libs
//                    directory is giving you confusing errors
//
// Elaborate only:
//
//   xrun -sv -elaborate \
//        ../rtl/PIPELINE_REG_STRUCT_PKG.sv \
//        ../rtl/2_To_1_MUX.sv ../rtl/4_TO_1_MUX.sv ../rtl/ALU.sv \
//        ../rtl/Branch_Condition_Generator.sv ../rtl/Program_Counter.sv \
//        ../rtl/IMEM.sv ../rtl/Reg_File.sv ../rtl/Control_Unit_Decoder.sv \
//        ../rtl/Immediate_Generator.sv ../rtl/PC_Decoder.sv \
//        ../rtl/Jump_Branch_Address_Generator.sv \
//        ../rtl/Forwarding_Unit.sv ../rtl/HazardUnit.sv \
//        ../rtl/CPU_TOP.sv CPU_TOP_tb.sv
//
// Waveforms in SimVision:
//   Uncomment the $shm_open / $shm_probe block above, rerun, then:
//        simvision waves.shm &
//
//   Or launch interactively:
//   xrun -sv -access +rwc -gui -defparam CPU_TOP_tb.dut.IMEM.MEM_FILE=\"myprog.mem\" \
//        <same file list as above>
//
// Quick pass/fail:
//   grep -c FAIL CPU_TOP_tb.log
//   echo $?            # 0 from xrun means no $fatal
// ---------------------------------------------------------------------------
