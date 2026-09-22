`timescale 1ns/1ps
//============================================================================
// Testbench: CPU_TOP_tb
// DUT:       ../rtl/CPU_TOP.sv
// Stage:     whole pipeline (FETCH through WB)
// Date:      9/21/2026
//
// Role in system:
//   CPU_TOP is the 5-stage core. IMEM is inside it. DMEM is not -- DATA_IN /
//   DATA_OUT / DATA_ADDRESS / IOBUS_WE / IOBUS_RDEN / mem_data are the memory
//   ports. This bench is the CPU-only self-test harness: the Otter wrapper,
//   Interconnect, and real DMEM are not instantiated.
//
// Verification strategy:
//   Load rv32i_selftest.S into IMEM. A behavioral memory on the IOBUS ports
//   stands in for DMEM so Levels 6-10 have somewhere to read and write. The
//   memory model is written from the ISA, not copied from DMEM.sv. The
//   program is the scoreboard: when PC repeats, x30/x29 name the result.
//
// How to point IMEM at the image (do not edit CPU_TOP):
//   xrun ... -defparam CPU_TOP_tb.dut.IMEM.MEM_FILE=\"imem.mem\"
//============================================================================

//----------------------------------------------------------------------------
// CONTRACT UNDER TEST
//----------------------------------------------------------------------------
// FUNC-1  While RST is asserted, PC is 32'h0.
// FUNC-2  After RST releases, a defined PC stays word-aligned.  [ISA Vol I 1.2]
// FUNC-3  A defined nonzero in the x0 array slot is a write-gate failure.
//         X in that slot means nothing ever wrote it -- that is legal.
//                                                          [ISA Vol I 2.1]
// FUNC-4  After RST releases, PC is defined. X means PC_SEL went X.
// FUNC-5  Parked with x30 === 32'h600D_0000 and x31 === TOTAL_TESTS
//         is the program's pass signature.
// FUNC-6  Parked with x30 === 99 means JAL and BEQ both failed to loop.
// FUNC-7  Parked with any other defined x30 is a failed self-test case:
//         x30 is the test number, x29 the 1-based sub-check.
// FUNC-8  Loads and stores on the IOBUS ports obey RV32I widths and
//         sign/zero extension. The TB memory is the reference, not DMEM.sv.
//                                                          [ISA Vol I 2.6]
//
// TIME-1  CLK is 50 MHz (20 ns), the rate the wrapper feeds the core.
// TIME-2  RST is held for several rising edges so IMEM can produce a
//         defined ir / PC_USED at address 0 before fetch starts.
// TIME-3  RST is released on a negedge so the combinational PC update
//         does not race IMEM's posedge sample.                   [INVENTED]
// TIME-4  A park is PC repeating for PARK_HOLD consecutive clocks.
//         Longer than any stall this pipeline can raise.         [INVENTED]
// TIME-5  No park by WATCHDOG clocks is a timeout, not a pass.
// TIME-6  IOBUS address/WE/RDEN/DATA_OUT/mem_data are valid in EX.
//         The TB memory samples them on the posedge into MEM and
//         presents DATA_IN during MEM, matching CPU_TOP's comment
//         that the BRAM read is ready for the WB mux on that stage.
//                                                                [INVENTED]
//
// ASSUME-1 Hierarchical probes of dut.PC, dut.ir, dut.REG_FILE.registers[]
//          are legal under -access +rwc.                         [INVENTED]
// ASSUME-2 IMEM.MEM_FILE exists and $readmemh succeeds.          [INVENTED]
// ASSUME-3 The image is rv32i_selftest.S at address 0 with
//          ENABLE_LEVEL7 = 0, so TOTAL_TESTS is 130.             [INVENTED]
// ASSUME-4 Only DMEM_BASE .. DMEM_LIMIT is backed by the TB memory.
//          A store to TOHOST_ADDR is observed and dropped -- that
//          address is unclaimed on the real interconnect too.    [INVENTED]
//----------------------------------------------------------------------------

`ifndef IMEM_MEM_FILE
  `define IMEM_MEM_FILE "imem.mem"
`endif

import CPU_pkg::*;

module CPU_TOP_tb;

    //------------------------------------------------------------------------
    // Parameters -- pass signature is the program's, not the RTL's
    //------------------------------------------------------------------------
    localparam int unsigned CLK_PERIOD   = 20;
    localparam int unsigned RESET_CYCLES = 8;
    localparam int unsigned PARK_HOLD    = 16;
    localparam int unsigned WATCHDOG     = 200000;
    localparam int unsigned TRACE_HEAD   = 40;
    localparam int unsigned TRACE_STRIDE = 512;

    localparam logic [31:0] PASS_SIG     = 32'h600D_0000;
    localparam int unsigned TOTAL_TESTS  = 130;
    localparam logic [31:0] POISON_CODE  = 32'd99;
    localparam logic [31:0] TOHOST_ADDR  = 32'h1100_0100;
    localparam logic [31:0] DMEM_BASE    = 32'h0000_8000;
    localparam logic [31:0] DMEM_LIMIT   = 32'h0000_87FF;

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

    defparam dut.IMEM.MEM_FILE = `IMEM_MEM_FILE;

    //------------------------------------------------------------------------
    // Clock -- core rate, no wrapper divider
    //------------------------------------------------------------------------
    initial CLK = 1'b0;
    always #(CLK_PERIOD/2) CLK = ~CLK;

    //------------------------------------------------------------------------
    // Behavioral DMEM (FUNC-8 / TIME-6)
    //
    // Byte-addressable, ISA widths, sampled on the posedge the core uses
    // to leave EX. Not a copy of DMEM.sv: that module's case statement is
    // what a CPU-only bench is supposed to be independent of.
    //------------------------------------------------------------------------
    logic [7:0]  dmem [bit [31:0]];

    function automatic bit in_dmem(input logic [31:0] a);
        return (a >= DMEM_BASE) && (a <= DMEM_LIMIT);
    endfunction

    function automatic logic [31:0] pack_load(
        input logic [31:0] addr,
        input logic [1:0]  size,
        input logic        sign
    );
        logic [7:0]  b0, b1, b2, b3;
        b0 = dmem.exists(addr)   ? dmem[addr]   : 8'h00;
        b1 = dmem.exists(addr+1) ? dmem[addr+1] : 8'h00;
        b2 = dmem.exists(addr+2) ? dmem[addr+2] : 8'h00;
        b3 = dmem.exists(addr+3) ? dmem[addr+3] : 8'h00;
        case (size)
            2'b00: return sign ? {24'b0, b0} : {{24{b0[7]}}, b0};   // LBU / LB
            2'b01: return sign ? {16'b0, b1, b0} : {{16{b1[7]}}, b1, b0}; // LHU / LH
            default: return {b3, b2, b1, b0};                       // LW
        endcase
    endfunction

    task automatic do_store(
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [1:0]  size
    );
        dmem[addr] = data[7:0];
        if (size !== 2'b00) dmem[addr+1] = data[15:8];
        if (size === 2'b10) begin
            dmem[addr+2] = data[23:16];
            dmem[addr+3] = data[31:24];
        end
    endtask

    // Sample on the EX->MEM edge. write_data muxes DATA_IN while the load
    // sits in ex_mem_q, so one cycle of latency is the whole budget -- a
    // second register here would deliver the word a stage too late.
    always_ff @(posedge CLK) begin
        if (RST) begin
            DATA_IN <= 32'h0;
        end
        else begin
            if ((IOBUS_WE === 1'b1) && in_dmem(DATA_ADDRESS))
                do_store(DATA_ADDRESS, DATA_OUT, mem_data[2:1]);

            if ((IOBUS_RDEN === 1'b1) && in_dmem(DATA_ADDRESS))
                DATA_IN <= pack_load(DATA_ADDRESS, mem_data[2:1], mem_data[0]);
            else
                DATA_IN <= 32'h0;
        end
    end

    //------------------------------------------------------------------------
    // Golden fragments -- program convention, not RTL
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

    function automatic logic [31:0] rf(input int unsigned idx);
        return dut.REG_FILE.registers[idx];
    endfunction

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

    task automatic sample_invariants();
        logic [31:0] pc_now, ir_now, x0_now;
        pc_now = dut.PC;
        ir_now = dut.ir;
        x0_now = rf(0);

        checks++;
        if ($isunknown(pc_now)) begin
            pc_x_cycles++;
            if (!pc_x_reported) begin
                pc_x_reported = 1'b1;
                errors++;
                $error("[%0t] FAIL [FUNC-4] PC went X at cycle %0d. Unloaded IMEM word, or an unimplemented opcode hit the decoder default.",
                       $time, cycle_i);
            end
        end
        else if (!pc_word_aligned(pc_now)) begin
            misalign_cycles++;
            if (!misalign_reported) begin
                misalign_reported = 1'b1;
                errors++;
                $error("[%0t] FAIL [FUNC-2] IALIGN: PC=0x%08h ir=0x%08h",
                       $time, pc_now, ir_now);
            end
        end

        checks++;
        if (!$isunknown(x0_now) && (x0_now !== x0_ref())) begin
            x0_bad_cycles++;
            if (!x0_reported) begin
                x0_reported = 1'b1;
                errors++;
                $error("[%0t] FAIL [FUNC-3] x0 array = 0x%08h, expected 0",
                       $time, x0_now);
            end
        end

        if ($isunknown(ir_now) && !ir_x_reported) begin
            ir_x_reported = 1'b1;
            $display("[%0t] NOTE [ASSUME-2] ir is X at PC=0x%08h.", $time, pc_now);
        end

        if ((IOBUS_WE === 1'b1) && (DATA_ADDRESS === TOHOST_ADDR)) begin
            tohost_seen = 1'b1;
            tohost_data = DATA_OUT;
        end
    endtask

    task automatic maybe_trace();
        int unsigned progress;
        progress = rf(31);
        if ((progress !== last_progress) && !$isunknown(progress)) begin
            $display("[%0t] progress test %0d  PC=0x%08h",
                     $time, progress, dut.PC);
            last_progress = progress;
        end
        else if ((cycle_i < TRACE_HEAD) || ((cycle_i % TRACE_STRIDE) == 0)) begin
            $display("[%0t] cyc=%0d PC=0x%08h x30=0x%08h x31=%0d",
                     $time, cycle_i, dut.PC, rf(30), rf(31));
        end
    endtask

    task automatic apply_reset();
        int i;
        RST     = 1'b1;
        DATA_IN = 32'h0;

        for (i = 0; i < RESET_CYCLES; i++) begin
            @(posedge CLK);
            #1;
            check("FUNC-1",
                  $sformatf("RST held, cycle %0d: PC must be 0, got 0x%08h", i, dut.PC),
                  dut.PC === 32'h0);
        end

        if ($isunknown(dut.ir))
            $display("[%0t] NOTE [ASSUME-2] ir is still X after reset. Is %s visible to xrun?",
                     $time, `IMEM_MEM_FILE);

        @(negedge CLK);
        RST = 1'b0;
        $display("[%0t] RST released; watchdog = %0d cycles", $time, WATCHDOG);
    endtask

    task automatic dump_report_regs();
        $display("  x29 (sub-check) = %0d", rf(29));
        $display("  x30 (fail code) = 0x%08h (%0d)", rf(30), rf(30));
        $display("  x31 (progress)  = %0d", rf(31));
        $display("  PC              = 0x%08h", dut.PC);
    endtask

    task automatic score_halt();
        logic [31:0] x29, x30, x31;
        x29 = rf(29);
        x30 = rf(30);
        x31 = rf(31);

        $display("----- halt after %0d cycles -----", cycle_i);
        dump_report_regs();
        if (tohost_seen)
            $display("  tohost store    = 0x%08h", tohost_data);

        if ($isunknown(x30) || $isunknown(x31)) begin
            check("FUNC-5",
                  $sformatf("parked with X in the report regs: x30=0x%08h x31=0x%08h", x30, x31),
                  1'b0);
        end
        else if (is_pass_sig(x30, x31)) begin
            check("FUNC-5", "pass signature matched", 1'b1);
            $display("SELFTEST PASS: all %0d tests retired", TOTAL_TESTS);
        end
        else if (x30 === POISON_CODE) begin
            check("FUNC-6",
                  "x30==99: JAL and BEQ both failed to hold a park loop",
                  1'b0);
        end
        else begin
            check("FUNC-7",
                  $sformatf("FAILED test %0d  sub-check %0d  (x31 progress=%0d)",
                            x30, x29, x31),
                  1'b0);
            $display("SELFTEST FAIL: test %0d  sub-check %0d", x30, x29);
        end
    endtask

    //------------------------------------------------------------------------
    // Directed: reset, run until park or watchdog. The .mem is the stimulus.
    //------------------------------------------------------------------------
    initial begin
        $display("===== CPU_TOP_tb (self-test harness) =====");
        $display("IMEM_MEM_FILE = %s", `IMEM_MEM_FILE);
        $display("TOTAL_TESTS   = %0d", TOTAL_TESTS);

        last_pc       = 32'hXXXX_XXXX;
        last_progress = 32'hFFFF_FFFF;
        park_count    = 0;
        parked        = 1'b0;
        timed_out     = 1'b0;
        cycle_i       = 0;
        DATA_IN       = 32'h0;

        apply_reset();

        while (!parked && !timed_out) begin
            @(posedge CLK);
            #1;
            sample_invariants();
            maybe_trace();

            if (!$isunknown(dut.PC) && (dut.PC === last_pc))
                park_count++;
            else
                park_count = 0;
            last_pc = dut.PC;

            if (park_count >= PARK_HOLD)
                parked = 1'b1;

            cycle_i++;
            if (cycle_i >= WATCHDOG)
                timed_out = 1'b1;
        end

        if (timed_out && !parked) begin
            check("TIME-5",
                  $sformatf("watchdog: no park after %0d cycles; last test in x31=%0d PC=0x%08h",
                            WATCHDOG, rf(31), dut.PC),
                  1'b0);
            dump_report_regs();
        end
        else begin
            score_halt();
        end

        $display("----- run stats -----");
        $display("  cycles                  %0d", cycle_i);
        $display("  PC was X for            %0d cycles", pc_x_cycles);
        $display("  PC misaligned for       %0d cycles", misalign_cycles);
        $display("  x0 defined-nonzero for  %0d cycles", x0_bad_cycles);

        $display("=========================================");
        $display(" %0d / %0d checks passed", checks - errors, checks);
        $display("=========================================");

        if (errors)
            $error("CPU_TOP_tb: %0d check(s) failed -- $stop so SimVision stays up", errors);
        else
            $display("CPU_TOP_tb: all checks passed -- $stop so SimVision stays up");

        // $stop, not $finish: the GUI stays open and the waveform database
        // stays attached. Drag signals from the Design Browser onto the
        // wave window; the cursor reads values at a given time. Type
        // `finish` in the console when you are done looking.
        $stop;
    end

    // SHM is Cadence's native dump. "A" = every signal in this scope,
    // "S" = walk into dut / REG_FILE / IMEM so you can drag those too.
    initial begin
        $shm_open("waves.shm");
        $shm_probe("AS");
    end

endmodule

// ---------------------------------------------------------------------------
// XCELIUM RUN NOTES  (run from tb/ on nanoHUB)
// ---------------------------------------------------------------------------
// Put imem.mem (assembled rv32i_selftest.S) in the directory you launch
// xrun from. No dmem.mem is required -- the TB owns the data memory.
//
// Waveform GUI (what you want): -gui opens SimVision. -access +rwc is
// what makes every wire draggable. The TB writes waves.shm as it runs
// and $stop's at the end so the window does not vanish.
//
//   xrun -sv -timescale 1ns/1ps -access +rwc -gui -l CPU_TOP_tb.log \
//        -defparam CPU_TOP_tb.dut.IMEM.MEM_FILE=\"imem.mem\" \
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
// In SimVision:
//   1. Design Browser (left) -> CPU_TOP_tb -> dut
//   2. Drag CLK, RST, PC, ir, DATA_ADDRESS, DATA_IN, DATA_OUT,
//      IOBUS_WE, IOBUS_RDEN onto the waveform window
//   3. Open dut.REG_FILE.registers and drag x29 / x30 / x31
//   4. Click in the wave window for the value at that time
//
// If the GUI is already closed and you just want to reopen the dump:
//   simvision waves.shm &
//
//   -access +rwc     required: probes AND drag-and-drop in SimVision
//   -gui             bring SimVision up with the run
//   -l <file>        grep the log for SELFTEST / FAIL
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
// Quick pass/fail:
//   grep -E "SELFTEST PASS|SELFTEST FAIL|FAIL \\[TIME-5\\]" CPU_TOP_tb.log
// ---------------------------------------------------------------------------
