`timescale 1ns/1ps
//============================================================================
// Testbench: MCU_WRAPPER_tb
// DUT:       ../rtl/MCU_WRAPPER.sv  (CPU_TOP + IMEM + DMEM + Interconnect)
// Stage:     whole machine
// Date:      9/21/2026
//
// Role in system:
//   MCU_WRAPPER is the board-level machine: the 5-stage core, instruction
//   ROM, data RAM, and the MMIO decode that sits between them. This is the
//   first place the rv32i_selftest.S image can actually run, because
//   CPU_TOP_tb ties DATA_IN to 0 and has no DMEM -- every load would write
//   zero and Level 6 would fail for a reason that is not a CPU bug.
//
// Verification strategy:
//   Load the assembled self-test into IMEM, clock the wrapper the way the
//   board does, and wait until the program parks (PC repeats). The program
//   itself is the scoreboard: it leaves a signature in x30/x31. This bench
//   does not interpret instructions. It only enforces the halt contract the
//   program published, plus the ISA invariants that must hold for any image
//   (x0, IALIGN, a defined PC).
//
// How to point IMEM at the image (do not edit the DUT):
//   xrun ... -defparam MCU_WRAPPER_tb.dut.CPU_TOP.IMEM.MEM_FILE=\"imem.mem\"
//   The .mem path is resolved from the directory you launch xrun in.
//============================================================================

//----------------------------------------------------------------------------
// CONTRACT UNDER TEST
//----------------------------------------------------------------------------
// FUNC-1  While BTNC (reset) is asserted, PC is 32'h0.
//         Program_Counter treats reset as its highest-priority input.
// FUNC-2  After reset releases, a defined PC stays word-aligned. RV32I
//         IALIGN is 32; a defined misaligned PC is a fetch bug.
//                                                          [ISA Vol I 1.2]
// FUNC-3  Architectural x0 reads as 0 for the whole run. The register-file
//         array itself may stay X if nothing ever wrote x0 -- that is the
//         write-gate working, not a failure. A *defined* nonzero is.
//                                                          [ISA Vol I 2.1]
// FUNC-4  After reset releases, PC is defined. An X PC means PC_SEL went
//         X: usually an X opcode from an unloaded IMEM word, or
//         PC_Decoder's unique-case default.
// FUNC-5  The self-test parks in pass_loop with
//             x30 === 32'h600D_0000  and  x31 === TOTAL_TESTS
//         That pair is the program's published pass signature, not an
//         RTL encoding. Anything else at a park is a functional fail of
//         the core (or of the image, if the .mem is stale).
// FUNC-6  A park with x30 === 99 means JAL and BEQ both failed to loop.
//         Nothing above that line in the program can be trusted.
// FUNC-7  A park with x30 holding any other defined value is a failed
//         self-test case: x30 is the test number, x29 the 1-based
//         sub-check. The bench reports that pair; it does not retry.
//
// TIME-1  Wrapper CLK is 100 MHz (10 ns). MCU_WRAPPER divides it to 50 MHz
//         for the core; that is the clock the register file and PC see.
// TIME-2  Reset is held across several wrapper edges so IMEM's synchronous
//         read can produce a defined ir / PC_USED at address 0 before
//         fetch starts. IMEM has no reset of its own.
// TIME-3  Reset is released on a wrapper negedge so the combinational PC
//         update is not racing IMEM's posedge sample.            [INVENTED]
// TIME-4  A park is PC repeating for PARK_HOLD consecutive *core* clocks.
//         pass_loop / fail_loop are 1-instruction jal-to-self; a shorter
//         hold would also fire on a stall. PARK_HOLD is longer than any
//         stall this pipeline can raise.                         [INVENTED]
// TIME-5  If the core has not parked by WATCHDOG core clocks, the run is
//         a timeout, not a pass. The program is 5395 instructions; the
//         budget is sized for pipeline bubbles plus the Level 10 loops.
//
// ASSUME-1 Hierarchical probes of dut.CPU_TOP.PC, dut.CPU_TOP.ir,
//          dut.CPU_TOP.REG_FILE.registers[], dut.clk_50, and the IOBUS
//          nets are legal under -access +rwc. None of those are wrapper
//          ports.                                                [INVENTED]
// ASSUME-2 IMEM.MEM_FILE exists and $readmemh succeeds. Unloaded words
//          stay X and poison PC_SEL through the decoder default.
//                                                                [INVENTED]
// ASSUME-3 DMEM.MEM_FILE exists. The self-test writes every location it
//          later reads, so a file of zeros is enough; a missing file
//          makes $readmemh fail the elaboration.                 [INVENTED]
// ASSUME-4 The image in IMEM is rv32i_selftest.S assembled at address 0
//          with ENABLE_LEVEL7 = 0, so TOTAL_TESTS is 130. Rebuild the
//          .mem and bump TOTAL_TESTS together if you flip that flag.
//                                                                [INVENTED]
// ASSUME-5 DMEM is clocked from the *undivided* wrapper clock while the
//          core is clocked from clk_50. This bench does not paper over
//          that. If loads come back stale or X, look there before the
//          pipeline.                                             [INVENTED]
//----------------------------------------------------------------------------

`ifndef IMEM_MEM_FILE
  `define IMEM_MEM_FILE "imem.mem"
`endif

`ifndef DMEM_MEM_FILE
  `define DMEM_MEM_FILE "dmem.mem"
`endif

import CPU_pkg::*;

module MCU_WRAPPER_tb;

    //------------------------------------------------------------------------
    // Parameters -- the pass signature is the program's, not the RTL's
    //------------------------------------------------------------------------
    localparam int unsigned CLK_PERIOD   = 10;      // 100 MHz board clock
    localparam int unsigned RESET_CYCLES = 16;      // TIME-2, wrapper edges
    localparam int unsigned PARK_HOLD    = 16;      // TIME-4, core edges
    localparam int unsigned WATCHDOG     = 200000;  // TIME-5, core edges
    localparam int unsigned TRACE_HEAD   = 40;
    localparam int unsigned TRACE_STRIDE = 512;

    localparam logic [31:0] PASS_SIG     = 32'h600D_0000;
    localparam int unsigned TOTAL_TESTS  = 130;     // ASSUME-4
    localparam logic [31:0] POISON_CODE  = 32'd99;
    localparam logic [31:0] TOHOST_ADDR  = 32'h1100_0100;

    //------------------------------------------------------------------------
    // DUT signals
    //------------------------------------------------------------------------
    logic        CLK;
    logic        BTNC;
    logic        BTNC2;
    logic [15:0] SWITCHES;
    logic [15:0] LEDS;
    logic [7:0]  CATHODES;
    logic [3:0]  ANODES;

    int checks = 0;
    int errors = 0;

    int unsigned core_cyc;
    int unsigned park_count;
    int unsigned last_progress;
    logic [31:0] last_pc;
    bit          parked;
    bit          timed_out;
    bit          tohost_seen;
    logic [31:0] tohost_data;

    int unsigned pc_x_cycles;
    int unsigned misalign_cycles;
    int unsigned x0_bad_cycles;
    bit          pc_x_reported;
    bit          misalign_reported;
    bit          x0_reported;
    bit          ir_x_reported;

    MCU_WRAPPER dut (
        .CLK      (CLK),
        .BTNC     (BTNC),
        .BTNC2    (BTNC2),
        .SWITCHES (SWITCHES),
        .LEDS     (LEDS),
        .CATHODES (CATHODES),
        .ANODES   (ANODES)
    );

    // CPU_TOP / DMEM do not expose their file parameters, so the override
    // punches through the instance. A command-line -defparam wins over this.
    defparam dut.CPU_TOP.IMEM.MEM_FILE    = `IMEM_MEM_FILE;
    defparam dut.DATA_MEMORY.MEM_FILE     = `DMEM_MEM_FILE;

    //------------------------------------------------------------------------
    // Clock -- board rate. The wrapper divides it; we sample on clk_50.
    //------------------------------------------------------------------------
    initial CLK = 1'b0;
    always #(CLK_PERIOD/2) CLK = ~CLK;

    //------------------------------------------------------------------------
    // Golden fragments. The pass/fail decode is the program convention
    // (tb/rv32i_selftest.S header), not a transcription of any RTL case.
    //------------------------------------------------------------------------
    function automatic logic [31:0] x0_ref();
        return 32'h0;
    endfunction

    function automatic bit pc_word_aligned(input logic [31:0] pc);
        return (pc[1:0] === 2'b00);
    endfunction

    function automatic bit is_pass_sig(
        input logic [31:0] x30,
        input logic [31:0] x31
    );
        return (x30 === PASS_SIG) && (x31 === TOTAL_TESTS);
    endfunction

    //------------------------------------------------------------------------
    // Checker. `cond` is already evaluated with === at the call site so an
    // X on a probed net cannot hide inside `==`.
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

    function automatic logic [31:0] rf(input int unsigned idx);
        return dut.CPU_TOP.REG_FILE.registers[idx];
    endfunction

    //------------------------------------------------------------------------
    // Per-core-cycle invariants, sampled after the clk_50 NBA update.
    //------------------------------------------------------------------------
    task automatic sample_invariants();
        logic [31:0] pc_now;
        logic [31:0] ir_now;
        logic [31:0] x0_now;

        pc_now = dut.CPU_TOP.PC;
        ir_now = dut.CPU_TOP.ir;
        x0_now = rf(0);

        checks++;
        if ($isunknown(pc_now)) begin
            pc_x_cycles++;
            if (!pc_x_reported) begin
                pc_x_reported = 1'b1;
                errors++;
                $error("[%0t] FAIL [FUNC-4] PC went X at core cycle %0d. Usual causes: the .mem ended, or an unimplemented opcode hit the decoder default.",
                       $time, core_cyc);
            end
        end
        else if (!pc_word_aligned(pc_now)) begin
            misalign_cycles++;
            if (!misalign_reported) begin
                misalign_reported = 1'b1;
                errors++;
                $error("[%0t] FAIL [FUNC-2] IALIGN: PC=0x%08h is not word-aligned (ir=0x%08h)",
                       $time, pc_now, ir_now);
            end
        end

        // A defined nonzero in the x0 slot means the write-gate lost.
        // X means nothing ever wrote it, which is the gate working.
        checks++;
        if (!$isunknown(x0_now) && (x0_now !== x0_ref())) begin
            x0_bad_cycles++;
            if (!x0_reported) begin
                x0_reported = 1'b1;
                errors++;
                $error("[%0t] FAIL [FUNC-3] x0 array = 0x%08h, expected 0x%08h",
                       $time, x0_now, x0_ref());
            end
        end

        if ($isunknown(ir_now) && !ir_x_reported) begin
            ir_x_reported = 1'b1;
            $display("[%0t] NOTE [ASSUME-2] ir is X at PC=0x%08h. $readmemh missed this word, or fetch walked off the image.",
                     $time, pc_now);
        end

        // The program's optional tohost store is a side channel, not the
        // pass condition -- x30/x31 at the park are. Seeing it just means
        // the pass sequence reached the store.
        if ((dut.CPU_TOP.IOBUS_WE === 1'b1) &&
            (dut.CPU_TOP.DATA_ADDRESS === TOHOST_ADDR)) begin
            tohost_seen = 1'b1;
            tohost_data = dut.CPU_TOP.DATA_OUT;
        end
    endtask

    task automatic maybe_trace();
        int unsigned progress;
        progress = rf(31);

        // x31 is the live test number until the epilogue overwrites it
        // with TOTAL_TESTS. Printing on change is how you see where a
        // timeout died without opening a waveform.
        if ((progress !== last_progress) && !$isunknown(progress)) begin
            $display("[%0t] progress x31=%0d  PC=0x%08h  ir=0x%08h",
                     $time, progress, dut.CPU_TOP.PC, dut.CPU_TOP.ir);
            last_progress = progress;
        end
        else if ((core_cyc < TRACE_HEAD) || ((core_cyc % TRACE_STRIDE) == 0)) begin
            $display("[%0t] cyc=%0d PC=0x%08h ir=0x%08h x30=0x%08h x31=%0d",
                     $time, core_cyc, dut.CPU_TOP.PC, dut.CPU_TOP.ir, rf(30), rf(31));
        end
    endtask

    task automatic apply_reset();
        int i;
        BTNC     = 1'b1;
        BTNC2    = 1'b0;
        SWITCHES = 16'h0;

        for (i = 0; i < RESET_CYCLES; i++) begin
            @(posedge CLK);
            #1;
            check("FUNC-1",
                  $sformatf("BTNC held, wrapper cycle %0d: PC must be 0, got 0x%08h",
                            i, dut.CPU_TOP.PC),
                  dut.CPU_TOP.PC === 32'h0);
        end

        if ($isunknown(dut.CPU_TOP.ir))
            $display("[%0t] NOTE [ASSUME-2] ir is still X after %0d wrapper cycles. Check that %s is visible to xrun.",
                     $time, RESET_CYCLES, `IMEM_MEM_FILE);

        // TIME-3: drop reset off the sampling edge.
        @(negedge CLK);
        BTNC = 1'b0;
        $display("[%0t] reset released; watchdog = %0d core cycles",
                 $time, WATCHDOG);
    endtask

    task automatic dump_regfile();
        int i;
        $display("----- register file -----");
        for (i = 0; i < 32; i++)
            $display("  x%0d = 0x%08h", i, rf(i));
    endtask

    // FUNC-5/6/7: classify the parked architectural state against the
    // program convention. Called once, after PARK_HOLD repeats.
    task automatic score_halt();
        logic [31:0] x29, x30, x31, pc_now;
        x29    = rf(29);
        x30    = rf(30);
        x31    = rf(31);
        pc_now = dut.CPU_TOP.PC;

        $display("----- halt -----");
        $display("  PC  = 0x%08h  (held %0d core cycles)", pc_now, park_count);
        $display("  x29 = %0d", x29);
        $display("  x30 = 0x%08h (%0d)", x30, x30);
        $display("  x31 = %0d", x31);
        if (tohost_seen)
            $display("  tohost store saw 0x%08h", tohost_data);

        if ($isunknown(x30) || $isunknown(x31)) begin
            check("FUNC-5",
                  $sformatf("parked with X in the report regs: x30=0x%08h x31=0x%08h",
                            x30, x31),
                  1'b0);
        end
        else if (is_pass_sig(x30, x31)) begin
            check("FUNC-5",
                  $sformatf("pass signature: x30=0x%08h x31=%0d", x30, x31),
                  1'b1);
            $display("SELFTEST PASS: all %0d tests retired", TOTAL_TESTS);
        end
        else if (x30 === POISON_CODE) begin
            check("FUNC-6",
                  "x30==99: JAL and BEQ both failed to hold a park loop",
                  1'b0);
        end
        else begin
            check("FUNC-7",
                  $sformatf("self-test failed: test %0d  sub-check %0d  progress x31=%0d  PC=0x%08h",
                            x30, x29, x31, pc_now),
                  1'b0);
        end
    endtask

    //------------------------------------------------------------------------
    // Directed: reset, then run until park or watchdog. The image is the
    // stimulus; there is no constrained-random sweep.
    //------------------------------------------------------------------------
    initial begin
        $display("===== MCU_WRAPPER_tb =====");
        $display("IMEM_MEM_FILE = %s", `IMEM_MEM_FILE);
        $display("DMEM_MEM_FILE = %s", `DMEM_MEM_FILE);
        $display("PASS_SIG      = 0x%08h", PASS_SIG);
        $display("TOTAL_TESTS   = %0d", TOTAL_TESTS);

        last_pc       = 32'hXXXX_XXXX;
        last_progress = 32'hFFFF_FFFF;
        park_count    = 0;
        parked        = 1'b0;
        timed_out     = 1'b0;
        core_cyc      = 0;

        apply_reset();

        while (!parked && !timed_out) begin
            @(posedge dut.clk_50);
            #1;
            sample_invariants();
            maybe_trace();

            if (!$isunknown(dut.CPU_TOP.PC) && (dut.CPU_TOP.PC === last_pc))
                park_count++;
            else
                park_count = 0;
            last_pc = dut.CPU_TOP.PC;

            if (park_count >= PARK_HOLD)
                parked = 1'b1;

            core_cyc++;
            if (core_cyc >= WATCHDOG)
                timed_out = 1'b1;
        end

        if (timed_out && !parked) begin
            check("TIME-5",
                  $sformatf("watchdog: no park after %0d core cycles; last PC=0x%08h x30=0x%08h x31=%0d x29=%0d",
                            WATCHDOG, dut.CPU_TOP.PC, rf(30), rf(31), rf(29)),
                  1'b0);
        end
        else begin
            score_halt();
        end

        dump_regfile();

        $display("----- run stats -----");
        $display("  core cycles             %0d", core_cyc);
        $display("  PC was X for            %0d cycles", pc_x_cycles);
        $display("  PC misaligned for       %0d cycles", misalign_cycles);
        $display("  x0 defined-nonzero for  %0d cycles", x0_bad_cycles);

        //--------------------------------------------------------------------
        // Coverage / completeness notes
        //
        //   - No instruction-by-instruction ISS. The self-test is the
        //     scoreboard; this bench only reads its report registers.
        //   - No check that DMEM contents match an independent memory
        //     model. Level 6 of the image already does that architecturally.
        //   - TOHOST_ADDR is unclaimed in Interconnect, so the store is
        //     observed on the bus and then dropped. That is expected.
        //--------------------------------------------------------------------

        $display("=========================================");
        $display(" %0d / %0d checks passed", checks - errors, checks);
        $display("=========================================");

        if (errors) $fatal(1, "MCU_WRAPPER_tb: %0d check(s) failed", errors);
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
// You need two hex files in the directory you launch xrun from:
//
//   imem.mem   -- assembled rv32i_selftest.S (one word per line, no 0x)
//   dmem.mem   -- zeros is enough; the program writes what it reads
//
//   python3 -c "print('00000000\\n'*2048, end='')" > dmem.mem
//
// Single-shot compile + elaborate + run:
//
//   xrun -sv -timescale 1ns/1ps -access +rwc -l MCU_WRAPPER_tb.log \
//        -defparam MCU_WRAPPER_tb.dut.CPU_TOP.IMEM.MEM_FILE=\"imem.mem\" \
//        -defparam MCU_WRAPPER_tb.dut.DATA_MEMORY.MEM_FILE=\"dmem.mem\" \
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
//        ../rtl/DMEM.sv \
//        ../rtl/Interconnect.sv \
//        ../rtl/BCDMod.sv \
//        ../rtl/CathodeDriver.sv \
//        ../rtl/SevSegDisp.sv \
//        ../rtl/MCU_WRAPPER.sv \
//        MCU_WRAPPER_tb.sv
//
//   -sv              treat inputs as SystemVerilog
//   -access +rwc     required: the TB probes CPU_TOP.PC / REG_FILE.registers
//   -l <file>        tee the transcript; grep it for FAIL / SELFTEST
//   -clean           force a full rebuild if a stale INCA_libs is lying
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
//        ../rtl/CPU_TOP.sv ../rtl/DMEM.sv ../rtl/Interconnect.sv \
//        ../rtl/BCDMod.sv ../rtl/CathodeDriver.sv ../rtl/SevSegDisp.sv \
//        ../rtl/MCU_WRAPPER.sv MCU_WRAPPER_tb.sv
//
// Waveforms:
//   Uncomment the $shm_open / $shm_probe block above, rerun, then:
//        simvision waves.shm &
//
// Quick pass/fail:
//   grep -E "SELFTEST PASS|FAIL \\[FUNC-7\\]|FAIL \\[TIME-5\\]" MCU_WRAPPER_tb.log
//   echo $?            # 0 from xrun means no $fatal
// ---------------------------------------------------------------------------
