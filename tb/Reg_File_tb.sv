`timescale 1ns/1ps
//============================================================================
// Testbench: Reg_File_tb
// DUT:       ../rtl/Reg_File.sv   (module name: REG_FILE)
// Stage:     DECODE (reads) / WB-commit (writes)
// Date:      9/17/2026
//
// Role in system:
//   The register file is the integer ISA state. DECODE presents rs1/rs2
//   addresses from the instruction and captures the returned values into
//   ID/EX in the SAME cycle (CPU_TOP.sv:130-136, 184-187). Writes are the
//   other end of the pipe: CPU_TOP drives en/w_adr/w_data from ex_mem_q
//   (MEM-stage hold) so the posedge that leaves MEM is the architectural
//   writeback commit. Forwarding exists precisely because a DECODE-stage
//   combinational read cannot see that write until the edge has passed.
//
//   This is NOT a BRAM. DMEM/IMEM sample address and produce data one
//   cycle later. If this module ever grew a registered read, ID/EX would
//   capture a stale operand and every forwarding path would be aiming at
//   the wrong cycle. TIME-1 exists to make that regression loud.
//
// Verification strategy:
//   Directed cases from the RISC-V integer register convention (x0 hardwired
//   zero, 31 writable GPRs, two independent read ports) plus the pipeline
//   timing the rest of the core is built around. The golden model is a
//   shadow array written from that spec, not copied from REG_FILE's
//   always_ff / always_comb split, so a bug in the RTL cannot hide inside
//   a matching bug in the checker.
//
// This file does NOT import CPU_pkg. REG_FILE has no enum ports, and the
// package currently does not elaborate -- importing it would make a clean
// DUT unreachable. Encodings are not an interface fact here.
//============================================================================

//----------------------------------------------------------------------------
// CONTRACT UNDER TEST
//----------------------------------------------------------------------------
// FUNC-1  x0 is hardwired to 32'd0 on BOTH read ports. A write to x0 with
//         en=1 is discarded; a later read of x0 is still zero, and no other
//         register is disturbed.                              [ISA Vol I 2.1]
// FUNC-2  x1..x31 are distinct 32-bit locations. A write to register k is
//         visible on a later read of k and is NOT visible on a read of any
//         j != k. This is the address-decode contract: a one-hot error
//         aliases two names onto one word and is silent on a single-register
//         write/read.
// FUNC-3  en is a write gate. en=0 must leave every register unchanged even
//         if w_adr and w_data are presenting a legal, nonzero destination.
// FUNC-4  The two read ports are independent. They may name two different
//         registers, or the same register, in one cycle, and both answers
//         must be correct simultaneously. DECODE issues both addresses from
//         one instruction; a port that secretly shared an address mux would
//         pass every single-port test.
// FUNC-5  A second write to the same register replaces the first. There is
//         no byte-enable and no write-merging -- the whole word is replaced.
//
// TIME-1  Reads are combinational. Changing adr1/adr2 must update rs1/rs2
//         in the same cycle, with no clock edge. A registered read would
//         still show the previous register's data until the next posedge,
//         and ID/EX would snapshot the wrong operand.
// TIME-2  Writes commit on the rising edge, not combinationally. With en=1
//         and a new w_data already set up, a read of w_adr must still return
//         the OLD value until that posedge, and the NEW value after it.
// TIME-3  Write-then-immediately-read of the same address: after the
//         committing posedge, a combinational read of w_adr returns the
//         value just written, with no extra cycle. (New-data / "write-first"
//         from the read's point of view. This is what an async-read RF
//         does; a BRAM-style sync read would still show old data.)
// TIME-4  Before any write, every register reads as 0. The DUT has no reset
//         pin -- this is simulation-initialisation behaviour, not a hardware
//         reset contract. See ASSUME-1.
//
// ASSUME-1 The DUT's `initial` block zeros the array. That is simulation-
//          only and the source comment says to remove it later. There is no
//          RST port. On FPGA the power-up value of distributed RAM is not
//          this contract. This TB treats a pre-write 0 as required so that
//          removing the initial shows up as a TIME-4 failure rather than as
//          mysterious X in DECODE.                                      [INVENTED]
// ASSUME-2 Write-side inputs (en, w_adr, w_data) are stable before the
//          rising edge. This TB sets them up on the preceding negedge.
//          Same-edge races are not a defined result.                    [INVENTED]
// ASSUME-3 en is 0 or 1 in normal operation. Control_Unit_Decoder drives
//          RF_WE = 'X on illegal opcodes; if that X survives to the RF
//          write port, `if (en && ...)` will not take the write branch in
//          simulation (an X condition is not true). This TB asserts that
//          current behaviour so a later change is deliberate.           [INVENTED]
// ASSUME-4 Addresses are 5 bits, so they cannot name a location outside
//          x0..x31. The DUT does not have to handle an out-of-range index.
//----------------------------------------------------------------------------

module Reg_File_tb;

    //------------------------------------------------------------------------
    // Parameters
    //------------------------------------------------------------------------
    localparam time CLK_PERIOD = 10ns;
    localparam time SETTLE     = 1ns;   // comb cloud, and NBA -> always_comb

    //------------------------------------------------------------------------
    // DUT signals
    //------------------------------------------------------------------------
    logic        CLK;
    logic        en;
    logic [4:0]  adr1, adr2, w_adr;
    logic [31:0] w_data;
    logic [31:0] rs1, rs2;

    int checks = 0;
    int errors = 0;

    // Loop temporaries live here: nested declarations in unnamed blocks are
    // legal SV but not every elaborate flow agrees, and this TB has to
    // survive a strict one.
    int          r;
    logic [4:0]  a, b, other;
    logic [31:0] data, old_val, new_val, parked;

    REG_FILE dut (
        .CLK    (CLK),
        .en     (en),
        .adr1   (adr1),
        .adr2   (adr2),
        .w_adr  (w_adr),
        .w_data (w_data),
        .rs1    (rs1),
        .rs2    (rs2)
    );

    //------------------------------------------------------------------------
    // Clock. No reset generation: the DUT has no RST pin (ASSUME-1).
    //------------------------------------------------------------------------
    initial CLK = 1'b0;
    always #(CLK_PERIOD/2) CLK = ~CLK;

    //------------------------------------------------------------------------
    // Golden reference model
    //
    // Spec, not RTL: 32 architectural registers, x0 hardwired zero, writes
    // to x0 discarded, writes to x1..x31 replace the whole word when enabled.
    // Timing of the commit (posedge) is applied by the caller; this model
    // only answers "what is architectural state right now."
    //------------------------------------------------------------------------
    logic [31:0] golden [0:31];

    function automatic logic [31:0] rf_read(input logic [4:0] addr);
        // Read-side x0 is specified independently of the write-side discard
        // so a DUT that stored into x0 and then forgot the output mux still
        // fails FUNC-1.
        if (addr === 5'd0) return 32'd0;
        return golden[addr];
    endfunction

    task automatic rf_commit(input logic we, input logic [4:0] addr, input logic [31:0] data);
        if (we === 1'b1 && addr !== 5'd0)
            golden[addr] = data;
    endtask

    // Unique, address-tagged pattern. Low 5 bits equal the register index so
    // an aliasing decode error prints the wrong identity in the failure line.
    function automatic logic [31:0] pat(input logic [4:0] addr);
        return {27'h0A5A5A, addr};
    endfunction

    //------------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------------
    task automatic park_addrs();
        // Park both ports on a pair that is almost never the next target, so
        // the following address change is a real transition rather than a
        // no-op a registered read could sleep through.
        adr1 = 5'd30;
        adr2 = 5'd31;
        #SETTLE;
    endtask

    task automatic apply_write_setup(input logic we, input logic [4:0] addr, input logic [31:0] data);
        en     = we;
        w_adr  = addr;
        w_data = data;
    endtask

    // Clean synchronous write: setup on the negedge (ASSUME-2), commit on
    // the posedge, drop en so a later idle edge cannot re-write.
    task automatic commit_write(input logic [4:0] addr, input logic [31:0] data);
        @(negedge CLK);
        apply_write_setup(1'b1, addr, data);
        @(posedge CLK);
        rf_commit(1'b1, addr, data);
        @(negedge CLK);
        en = 1'b0;
    endtask

    //------------------------------------------------------------------------
    // Checker. Every call carries the contract ID it defends.
    //------------------------------------------------------------------------
    task automatic check_ports(input string tag, input string note,
                               input logic [4:0] a1, input logic [4:0] a2);
        logic [31:0] exp1, exp2;

        adr1 = a1;
        adr2 = a2;
        #SETTLE;

        exp1 = rf_read(a1);
        exp2 = rf_read(a2);
        checks++;

        // '===' not '==': an X on rs1/rs2 must FAIL. Unwritten storage after
        // someone removes the initial block is exactly that bug class.
        if (rs1 !== exp1 || rs2 !== exp2) begin
            errors++;
            $error("[%0t] FAIL [%s] %s | adr1=%0d adr2=%0d -> rs1=0x%08h rs2=0x%08h, expected rs1=0x%08h rs2=0x%08h",
                   $time, tag, note, a1, a2, rs1, rs2, exp1, exp2);
        end
    endtask

    task automatic check_word(input string tag, input string note,
                              input logic [4:0] addr, input logic [31:0] expected);
        adr1 = addr;
        adr2 = addr;
        #SETTLE;
        checks++;
        if (rs1 !== expected || rs2 !== expected) begin
            errors++;
            $error("[%0t] FAIL [%s] %s | x%0d -> rs1=0x%08h rs2=0x%08h, expected 0x%08h",
                   $time, tag, note, addr, rs1, rs2, expected);
        end
    endtask

    //------------------------------------------------------------------------
    // Directed cases, in contract order.
    //------------------------------------------------------------------------
    initial begin
        $display("===== Reg_File_tb =====");

        en     = 1'b0;
        adr1   = 5'd0;
        adr2   = 5'd0;
        w_adr  = 5'd0;
        w_data = 32'd0;

        for (r = 0; r < 32; r++)
            golden[r] = 32'd0;

        // Let the DUT's simulation initial (ASSUME-1) run and give the
        // combinational read mux a delta to settle before TIME-4 samples.
        #SETTLE;

        //--------------------------------------------------------------------
        // TIME-4 first: if unwritten registers are X, every later FUNC check
        // that reads a register we have not just written will also fail, and
        // those failures look like decode bugs. Surface the init question
        // under its own tag.
        //--------------------------------------------------------------------
        for (r = 0; r < 32; r++) begin
            a = r[4:0];
            check_word("TIME-4",
                       "unwritten register must read 0 (sim init, no RST pin)",
                       a, 32'd0);
        end

        //--------------------------------------------------------------------
        // FUNC-1: x0 is hardwired zero. The interesting case is not "reads 0
        // at reset" -- TIME-4 already did that -- it is "a write with en=1
        // cannot make it nonzero, and cannot land in a neighbour."
        //--------------------------------------------------------------------
        commit_write(5'd0, 32'hFFFF_FFFF);
        check_word("FUNC-1",
                   "write to x0 with en=1 must be discarded; both ports stay 0",
                   5'd0, 32'd0);
        check_word("FUNC-1",
                   "discarded x0 write must not have landed in x1",
                   5'd1, 32'd0);

        commit_write(5'd1, pat(5'd1));
        check_word("FUNC-1",
                   "a real write to x1 must not change the x0 mux",
                   5'd0, 32'd0);
        check_word("FUNC-1",
                   "x1 took the write that x0 refused",
                   5'd1, pat(5'd1));

        //--------------------------------------------------------------------
        // FUNC-2: distinct locations. Unique pattern per register, then read
        // every register back, including the ones we did not just touch. A
        // DUT whose write decoder is a truncated index (e.g. w_adr[3:0])
        // aliases x1 and x17 and only fails when both have been written.
        //--------------------------------------------------------------------
        for (r = 1; r < 32; r++) begin
            a = r[4:0];
            commit_write(a, pat(a));
        end
        for (r = 0; r < 32; r++) begin
            a = r[4:0];
            check_word("FUNC-2",
                       "each architectural name maps to its own word",
                       a, (a === 5'd0) ? 32'd0 : pat(a));
        end

        // Bit-4 alias: x1 (5'b00001) vs x17 (5'b10001). A DUT that used
        // w_adr[3:0] as the index would have just overwritten x1 with x17's
        // pattern, and the x1 check above would already have fired -- this
        // pair is the explicit hypothesis so the failure message says so.
        check_word("FUNC-2", "x1 must not alias x17 (w_adr[4] dropped)",
                   5'd1,  pat(5'd1));
        check_word("FUNC-2", "x17 must not alias x1",
                   5'd17, pat(5'd17));
        // LSB alias: x2 vs x3.
        check_word("FUNC-2", "x2 must not alias x3 (w_adr[0] dropped)",
                   5'd2, pat(5'd2));
        check_word("FUNC-2", "x3 must not alias x2",
                   5'd3, pat(5'd3));

        //--------------------------------------------------------------------
        // FUNC-3: en is a gate, not a suggestion. w_adr/w_data present a
        // legal overwrite of x7; the only thing keeping it out is en=0.
        //--------------------------------------------------------------------
        commit_write(5'd7, 32'h1111_1111);
        @(negedge CLK);
        apply_write_setup(1'b0, 5'd7, 32'hEEEE_EEEE);
        @(posedge CLK);
        rf_commit(1'b0, 5'd7, 32'hEEEE_EEEE);   // model: gated, no update
        @(negedge CLK);
        check_word("FUNC-3",
                   "en=0 must ignore a legal w_adr/w_data pair",
                   5'd7, 32'h1111_1111);

        // Neighbours of x7 must still hold FUNC-2 patterns -- a DUT that
        // treated en as a chip-enable on a whole-file write-clear would
        // wipe more than x7.
        check_word("FUNC-3", "gated non-write must not disturb x6",
                   5'd6, pat(5'd6));
        check_word("FUNC-3", "gated non-write must not disturb x8",
                   5'd8, pat(5'd8));

        //--------------------------------------------------------------------
        // FUNC-4: both ports at once. Single-port tests cannot catch a DUT
        // that wired adr2 to adr1, or that has only one internal read mux.
        //--------------------------------------------------------------------
        commit_write(5'd9,  32'hAAAA_0009);
        commit_write(5'd10, 32'hBBBB_000A);
        check_ports("FUNC-4",
                    "two ports, two registers, same cycle",
                    5'd9, 5'd10);
        check_ports("FUNC-4",
                    "ports swapped: the independence is in the addresses, not the port names",
                    5'd10, 5'd9);
        check_ports("FUNC-4",
                    "both ports naming x9 must agree with each other",
                    5'd9, 5'd9);
        check_ports("FUNC-4",
                    "one port on x0, the other on a live GPR",
                    5'd0, 5'd10);
        check_ports("FUNC-4",
                    "both ports on x0",
                    5'd0, 5'd0);

        //--------------------------------------------------------------------
        // FUNC-5: whole-word replace. A DUT that ORed the new value in, or
        // that only wrote the low 16 bits, survives every first-write check.
        //--------------------------------------------------------------------
        commit_write(5'd11, 32'h0000_FFFF);
        commit_write(5'd11, 32'hFFFF_0000);
        check_word("FUNC-5",
                   "second write must replace the first, not merge with it",
                   5'd11, 32'hFFFF_0000);

        //--------------------------------------------------------------------
        // TIME-1: combinational read. Park on x31 (known pattern), then
        // retarget to x12 with no clock edge. A registered read still shows
        // x31 until the next posedge; DECODE cannot wait that long.
        //--------------------------------------------------------------------
        commit_write(5'd12, 32'hC0DE_0012);
        park_addrs();
        parked = rs1;   // x30's pattern, from the park
        adr1 = 5'd12;
        #SETTLE;
        checks++;
        if (rs1 !== 32'hC0DE_0012) begin
            errors++;
            $error("[%0t] FAIL [TIME-1] comb read must follow adr1 with no clock; parked=0x%08h rs1=0x%08h expected 0x%08h",
                   $time, parked, rs1, 32'hC0DE_0012);
        end
        // Still the same value just before the next posedge: if a clocked
        // read "caught up" here we would want to know, but more importantly
        // we must not have lost the comb answer while waiting.
        @(posedge CLK);
        #SETTLE;
        checks++;
        if (rs1 !== 32'hC0DE_0012) begin
            errors++;
            $error("[%0t] FAIL [TIME-1] comb read drifted across an idle posedge -> rs1=0x%08h expected 0x%08h",
                   $time, rs1, 32'hC0DE_0012);
        end

        // Same hypothesis on port 2, so a DUT that registered only rs2
        // (easy to do when copying the read mux) cannot hide behind TIME-1
        // on rs1.
        park_addrs();
        adr2 = 5'd12;
        #SETTLE;
        checks++;
        if (rs2 !== 32'hC0DE_0012) begin
            errors++;
            $error("[%0t] FAIL [TIME-1] comb read must follow adr2 with no clock -> rs2=0x%08h expected 0x%08h",
                   $time, rs2, 32'hC0DE_0012);
        end

        //--------------------------------------------------------------------
        // TIME-2: write is edge-sampled. Setup NEW while the read port is
        // already sitting on that register; the value must not change until
        // the posedge. A combinational write (always_comb / blocking into
        // the array) would show NEW a half-cycle early, and DECODE in the
        // same cycle as WB would see a bypass the forwarding unit does not
        // know about.
        //--------------------------------------------------------------------
        commit_write(5'd13, 32'h01D0_0013);
        old_val = 32'h01D0_0013;
        new_val = 32'h0E00_0013;

        @(negedge CLK);
        adr1 = 5'd13;
        adr2 = 5'd13;
        apply_write_setup(1'b1, 5'd13, new_val);
        #SETTLE;
        checks++;
        if (rs1 !== old_val || rs2 !== old_val) begin
            errors++;
            $error("[%0t] FAIL [TIME-2] write leaked combinationally before the posedge | x13 -> rs1=0x%08h rs2=0x%08h, still expected old 0x%08h",
                   $time, rs1, rs2, old_val);
        end

        @(posedge CLK);
        rf_commit(1'b1, 5'd13, new_val);
        #SETTLE;
        checks++;
        if (rs1 !== new_val || rs2 !== new_val) begin
            errors++;
            $error("[%0t] FAIL [TIME-2] write did not commit on the posedge | x13 -> rs1=0x%08h rs2=0x%08h, expected new 0x%08h",
                   $time, rs1, rs2, new_val);
        end
        @(negedge CLK);
        en = 1'b0;

        //--------------------------------------------------------------------
        // TIME-3: after that same posedge, the combinational read already
        // shows NEW -- no extra cycle. A BRAM-style registered read would
        // have passed TIME-2's "old before the edge" and failed here.
        // (TIME-2's post-edge check is the same observation; this case
        // restates it as the write-then-read contract the recipe asks for,
        // with a fresh address so a sticky rs1 from TIME-2 cannot fake it.)
        //--------------------------------------------------------------------
        commit_write(5'd14, 32'hFEED_0014);
        park_addrs();
        @(negedge CLK);
        apply_write_setup(1'b1, 5'd14, 32'hF00D_0014);
        @(posedge CLK);
        rf_commit(1'b1, 5'd14, 32'hF00D_0014);
        adr1 = 5'd14;          // retarget AFTER the edge, still same cycle
        adr2 = 5'd14;
        #SETTLE;
        checks++;
        if (rs1 !== 32'hF00D_0014 || rs2 !== 32'hF00D_0014) begin
            errors++;
            $error("[%0t] FAIL [TIME-3] write-then-read same cycle must return new data | x14 -> rs1=0x%08h rs2=0x%08h, expected 0x%08h",
                   $time, rs1, rs2, 32'hF00D_0014);
        end
        @(negedge CLK);
        en = 1'b0;

        //--------------------------------------------------------------------
        // ASSUME-3: en=X does not write. Illegal opcodes poison RF_WE with
        // 'X; if that X reaches this port three stages later, today's
        // `if (en && ...)` silently drops the write. Assert that so a
        // change to "treat X as 1" cannot sneak in.
        //--------------------------------------------------------------------
        commit_write(5'd15, 32'h5151_0015);
        @(negedge CLK);
        en     = 1'bX;
        w_adr  = 5'd15;
        w_data = 32'hDEAD_0015;
        @(posedge CLK);
        // Model: X-enable is not a write. Do not call rf_commit.
        @(negedge CLK);
        en = 1'b0;
        check_word("ASSUME-3",
                   "en=X must not commit a write (today's if(X) is not taken)",
                   5'd15, 32'h5151_0015);

        //--------------------------------------------------------------------
        // Constrained-random sweep. Directed cases above cover the corners
        // we could name; this covers back-to-back writes, random port
        // pairings, and the interior of the 31 writable names.
        //--------------------------------------------------------------------
        begin
            void'($urandom(32'hC0FFEE));

            repeat (200) begin
                // Never randomly write x0 here -- FUNC-1 already owns that
                // path. Random x0 writes would just re-check hardwired zero
                // and starve the writable space.
                a    = 5'd1 + $urandom_range(0, 30);
                data = $urandom();
                commit_write(a, data);

                b     = $urandom_range(0, 31);
                other = $urandom_range(0, 31);
                check_ports("FUNC-R", "random write then dual-port read", b, other);
            end

            // Back-to-back writes on consecutive posedges, the way a string
            // of ALU ops actually arrive from MEM. The helper's extra idle
            // negedge would hide a DUT that only works with a cycle of gap.
            @(negedge CLK);
            apply_write_setup(1'b1, 5'd20, 32'h2222_0020);
            @(posedge CLK);
            rf_commit(1'b1, 5'd20, 32'h2222_0020);
            @(negedge CLK);
            apply_write_setup(1'b1, 5'd21, 32'h2121_0021);
            @(posedge CLK);
            rf_commit(1'b1, 5'd21, 32'h2121_0021);
            @(negedge CLK);
            en = 1'b0;
            check_ports("FUNC-R",
                        "back-to-back writes on consecutive posedges",
                        5'd20, 5'd21);
        end

        //--------------------------------------------------------------------
        // Coverage / completeness notes
        //   Covered: x0 write+read on both ports; all 32 names written and
        //     read back; en=0 gating; en=X; dual-port distinct/same/x0;
        //     bit-4 and bit-0 alias pairs; whole-word replace; comb read
        //     with no clock; old-before-edge / new-after-edge; write-then-
        //     read same cycle; 200 random writes; consecutive-edge writes.
        //   Not covered (and not this module's): whether CPU_TOP should
        //     write from ex_mem_q vs mem_wb_q; whether DECODE should take
        //     addresses from ir vs if_id_q.ir. Those are CPU_TOP contracts.
        //   Byte/halfword lane placement is not a register-file problem --
        //     the integer RF is word-only per the ISA.
        //--------------------------------------------------------------------

        $display("=========================================");
        $display(" %0d / %0d checks passed", checks - errors, checks);
        $display("=========================================");

        if (errors) $fatal(1, "Reg_File_tb: %0d check(s) failed", errors);
        $finish;
    end

    // Waveforms: uncomment for SimVision, then 'simvision waves.shm &'
    // initial begin
    //     $shm_open("waves.shm");
    //     $shm_probe("AS");      // A = all signals, S = include sub-scopes
    // end

endmodule

// ---------------------------------------------------------------------------
// XCELIUM RUN NOTES  (run from tb/ on nanoHUB; AGENTS.md still names this
// directory 5_Stage_Pipeline/tb/ -- same place, this repo's tree has rtl/
// one level up from tb/)
// ---------------------------------------------------------------------------
// REG_FILE does not import CPU_pkg. Do not put PIPELINE_REG_STRUCT_PKG.sv
// on this command: the package currently does not elaborate, and this DUT
// does not need it.
//
// Elaborate only (fastest way to check the DUT compiles at all):
//
//   xrun -sv -elaborate ../rtl/Reg_File.sv Reg_File_tb.sv
//
// Single-shot compile + elaborate + run:
//
//   xrun -sv -timescale 1ns/1ps -access +rwc -l Reg_File_tb.log \
//        ../rtl/Reg_File.sv \
//        Reg_File_tb.sv
//
//   -sv              treat inputs as SystemVerilog
//   -access +rwc     read/write/connectivity access, required for waveforms
//   -l <file>        tee the transcript to a log you can grep for FAIL
//   -clean           add this to force a full rebuild if a stale INCA_libs
//                    directory is giving you confusing errors
//
// Waveforms in SimVision:
//   Uncomment the $shm_open / $shm_probe block above, rerun, then:
//        simvision waves.shm &
//
//   Or launch interactively and drive it from the GUI:
//   xrun -sv -access +rwc -gui ../rtl/Reg_File.sv Reg_File_tb.sv
//
// Quick pass/fail check without reading the whole transcript:
//   grep -c FAIL Reg_File_tb.log
//   echo $?            # 0 from xrun means no $fatal, so no failing checks
// ---------------------------------------------------------------------------
