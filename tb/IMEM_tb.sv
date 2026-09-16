`timescale 1ns/1ps
//============================================================================
// Testbench: IMEM_tb
// DUT:       ../rtl/IMEM.sv
// Stage:     FETCH  (and, per the 9/2/2026 decision comment, the IF/ID register)
// Date:      9/12/2026
//
// Role in system:
//   IMEM is a single-port, read-only, synchronous (BRAM-style) memory. It is the
//   only thing in FETCH besides Program_Counter. Per the 9/2/2026 decision note
//   in IMEM.sv, the discrete IF/ID register was DELETED and IMEM absorbed its
//   job: it registers PC into PC_USED on the same edge that it registers the
//   fetched word into instruction, so the two arrive at DECODE already paired.
//
//   That makes PC_USED/instruction alignment a first-class contract, not a
//   convenience. CPU_TOP.sv:68 feeds Program_Counter with PC_USED + 4 and
//   CPU_TOP.sv:125 latches id_ex_d.PC = PC_USED, so if PC_USED ever slips one
//   cycle relative to instruction, every branch target, every JAL link address,
//   and the sequential fetch stream itself are all off by four -- and none of
//   those symptoms point back at IMEM. This testbench checks the pairing on
//   every single fetch for that reason.
//
// Verification strategy:
//   The memory image is generated and back-door loaded by the testbench, so the
//   test is hermetic -- it does not depend on an imem.mem file existing in the
//   simulation directory. See "MEMORY IMAGE" below for why, and for what the
//   core-level harness should do instead.
//
//   The reference model is a plain associative/unpacked array in the testbench
//   plus a word-index function derived from the definition of a byte-addressed
//   32-bit word memory (index = PC >> 2), NOT from IMEM.sv's wordAddress
//   expression. That is the whole point: IMEM.sv's address decode is currently
//   wrong (see blockers) and a checker that copied it would agree with it.
//
// No CPU_pkg import:
//   IMEM's port list carries no enumerated control -- no alu_op_e, no pc_sel_e,
//   nothing from CPU_pkg appears on its interface, so there is nothing here to
//   drive with an enum. Deliberately NOT importing CPU_pkg also means this file
//   does not inherit the package's current compile errors, so it is the one
//   testbench you can run the moment IMEM.sv itself elaborates. If you want the
//   fetch stream to print mnemonics later, see the commented decode_instr_name
//   hook next to check_fetch().
//
// KNOWN ELABORATION BLOCKERS in ../rtl/IMEM.sv -- this will not compile yet:
//   L31  module port list closes with ')' and no ';'
//   L39  $readmemh targets 'memory', which is not declared; the array is
//        named instruction_memory
//   L43  wordAddress is assigned from 'address', which is not declared or
//        ported; the address port is named PC
//   L43  {address[9:2], 2'b0} is an 8-bit slice re-multiplied by 4 (see
//        SUSPECTED DEFECTS)
//   L32  wordAddress is [11:0] = 4096 entries, but the array has 8192
//   L45  sensitivity is 'clk'; the port is CLK
//   L46-47 blocking '=' inside always_ff
//   L48  no endmodule
//
//   This file is written against the interface IMEM.sv was clearly intended to
//   have: ports CLK / PC[31:0] / instruction[31:0] / PC_USED[31:0], and an
//   internal array named instruction_memory[0:8191].
//============================================================================

//----------------------------------------------------------------------------
// MEMORY IMAGE -- what is standard, and what this file does
//----------------------------------------------------------------------------
// Two separate tiers, and they want opposite things:
//
//   Module level (this file). Standard practice is a SELF-CONTAINED image:
//   the testbench generates the contents and back-door loads them through a
//   hierarchical reference (dut.instruction_memory[i] = ...). A ROM has no
//   write port, so this is the only way in. It is done at #1 rather than at
//   time 0 so it lands strictly after the DUT's own initial $readmemh, whose
//   ordering relative to testbench initial blocks is otherwise undefined.
//   This is why -access +rwc is mandatory in the run notes below.
//
//   Core level (later, riscv-tests). Standard practice is the opposite: a real
//   assembled imem.mem hex file loaded by the DUT's $readmemh, because at that
//   point the program IS the stimulus. AGENTS.md section 9 reserves that
//   harness; this file does not build it.
//
// The generated image is {16'hFACE, byte_address[15:0]}: every one of the 8192
// words is unique, and a wrong word reads back with the byte address it
// actually came from printed in its own low half. An address-decode bug is
// then legible straight off the transcript -- "expected FACE0004, got
// FACE0010" says the decode multiplied by four -- with no waveform needed.
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// CONTRACT UNDER TEST
//----------------------------------------------------------------------------
// FUNC-1   instruction returns the 32-bit word at byte address PC, i.e. array
//          index PC >> 2. With a 32 KB memory that is PC[14:2], 13 bits,
//          indices 0..8191.
// FUNC-2   PC[1:0] is ignored (truncated toward zero, not rounded). RV32I
//          instructions are 4-byte aligned and this core has no C extension,
//          so the low two bits carry no address information. See ASSUME-1 --
//          truncating is a choice, not the ISA's answer.
// FUNC-3   Distinct word indices return distinct words across the ENTIRE
//          32 KB. No aliasing. This is the check that a too-narrow
//          wordAddress or a mis-sliced PC fails.
// FUNC-4   Read-only. There is no port that can modify contents, so a word
//          read twice must read the same both times, and the whole array must
//          be byte-identical to the loaded image at end of test.
// FUNC-5   PC_USED is a full 32-bit passthrough of PC, unmodified. Not
//          truncated to the memory's address width -- CPU_TOP computes
//          PC_USED + 4 and latches id_ex_d.PC from it, so any bit dropped
//          here corrupts branch and link addresses.
//
// TIME-1   Synchronous read, exactly one cycle of latency. A PC presented
//          during cycle N is sampled by the rising edge that ends cycle N;
//          instruction is valid from that edge onward. It must NOT change
//          before the edge -- a combinational read would pass every value
//          check in this file and fail only this one.
// TIME-2   instruction and PC_USED are captured on the SAME edge and are
//          therefore always the matched pair (word, address-that-fetched-it).
//          This is IMEM's IF/ID register role.
// TIME-3   Back-to-back fetches, one per cycle with no idle gap, sustain
//          TIME-1 and TIME-2 indefinitely. This is the pipeline's normal
//          operating mode; a one-deep output register that needs a dead cycle
//          to recover would only show up here.
// TIME-4   Holding PC constant across several cycles re-reads the same word
//          and holds the same PC_USED. Outputs are stable, not one-shot.
//
// ASSUME-1 PC is always 4-byte aligned. The ISA says a misaligned fetch raises
//          an instruction-address-misaligned exception; this core has no trap
//          logic, so IMEM silently truncates instead. FUNC-2 pins that down as
//          the intended behaviour so it is at least documented.   [INVENTED]
// ASSUME-2 PC always lands inside 0x0000_0000..0x0000_7FFC. Anything above
//          that wraps silently by truncation -- PC = 0x0001_0000 fetches the
//          word at 0x0000_0000 and nothing anywhere reports it. There is no
//          bounds check and no error output in the port list.      [INVENTED]
// ASSUME-3 PC is stable before the rising edge. IMEM has no read-enable, so it
//          samples whatever PC holds at every single edge; there is no way to
//          tell it "this address is not ready."                    [INVENTED]
// ASSUME-4 IMEM has NO reset and NO stall/enable input.
//          (a) Startup correctness rests entirely on Program_Counter driving
//              PC = 0 for at least one full clock while RST is high, because
//              CPU_TOP derives PC_PLUS_FOUR from PC_USED, which only IMEM
//              produces. If RST is not held a full cycle, PC_USED comes out of
//              reset as X and the first fetch address is X + 4.
//          (b) IMEM advances on every edge unconditionally. When you add
//              load-use stalls there is no port to freeze the fetch with, and
//              the instruction will be lost, not held.             [INVENTED]
// ASSUME-5 The memory image is loaded before the first fetch. If imem.mem is
//          absent, Xcelium warns and the array stays X; instruction is then X
//          and, because CPU_TOP has no X guard, that X reaches DECODE.
//          probe_uninitialised() below reports which of the two happened
//          without failing the run.                               [INVENTED]
//----------------------------------------------------------------------------

module IMEM_tb;

    //------------------------------------------------------------------------
    // Parameters
    //
    // IMEM.sv declares instruction_memory[0:8191]: 8192 words x 4 bytes =
    // 32768 bytes, so the 32 KB in the plan and the array size do agree. The
    // address DECODE is what does not -- see the wordAddress defect.
    //------------------------------------------------------------------------
    localparam int CLK_PERIOD  = 10;                       // 10 ns = 100 MHz
    localparam int IMEM_BYTES  = 32 * 1024;                // 32 KB
    localparam int NUM_WORDS   = IMEM_BYTES / 4;           // 8192
    localparam int IDX_MSB     = $clog2(IMEM_BYTES) - 1;   // 14 -> PC[14:2]

    localparam logic [31:0] LAST_WORD_ADDR = IMEM_BYTES - 4;  // 0x7FFC

    //------------------------------------------------------------------------
    // DUT signals
    //------------------------------------------------------------------------
    logic        CLK;
    logic [31:0] PC;
    logic [31:0] instruction;
    logic [31:0] PC_USED;

    int checks = 0;
    int errors = 0;

    // Golden copy of the image. This is the reference model's storage; the
    // index arithmetic that reaches into it is ref_index(), below.
    logic [31:0] golden [0:NUM_WORDS-1];

    // Last known-good outputs, so TIME-1 can assert "still the OLD value".
    logic [31:0] prev_instruction;
    logic [31:0] prev_pc_used;

    IMEM dut (
        .CLK         (CLK),
        .PC          (PC),
        .instruction (instruction),
        .PC_USED     (PC_USED)
    );

    //------------------------------------------------------------------------
    // Clock. No reset: IMEM has no reset port (ASSUME-4).
    //------------------------------------------------------------------------
    initial CLK = 1'b0;
    always #(CLK_PERIOD/2) CLK = ~CLK;

    // initial begin
    //     $shm_open("waves.shm");
    //     $shm_probe("AS");      // A = all signals, S = include sub-scopes
    // end

    //------------------------------------------------------------------------
    // Golden reference model
    //
    // ref_index is the DEFINITION of a byte-addressed word memory -- divide the
    // byte address by four and keep as many bits as the memory has words. It is
    // written from that definition, not lifted from IMEM.sv:43, so the two
    // disagreeing is a finding rather than a coincidence.
    //
    // image_word is the generator; it is used both to fill the DUT and to fill
    // golden, which is legitimate because the image contents are stimulus, not
    // behaviour. What is under test is which word comes back, never what is in
    // it.
    //------------------------------------------------------------------------
    function automatic int ref_index(input logic [31:0] pc);
        return int'(pc[IDX_MSB:2]);          // FUNC-1, FUNC-2: PC[1:0] dropped
    endfunction

    function automatic logic [31:0] image_word(input int word_index);
        return {16'hFACE, 16'(word_index * 4)};
    endfunction

    function automatic logic [31:0] ref_instruction(input logic [31:0] pc);
        return golden[ref_index(pc)];
    endfunction

    //------------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------------

    // A ROM has no write port, so the image goes in by hierarchical reference.
    // Called at #1, never at time 0, so it cannot race the DUT's own
    // $readmemh. If you rename instruction_memory, this is the ONE line in the
    // file that has to follow.
    task automatic backdoor_load();
        for (int w = 0; w < NUM_WORDS; w++) begin
            golden[w]                 = image_word(w);
            dut.instruction_memory[w] = golden[w];
        end
        $display("[%0t] NOTE  back-door loaded %0d words (%0d KB), image = {FACE, byte_addr}",
                 $time, NUM_WORDS, IMEM_BYTES/1024);
    endtask

    // Diagnostic only, deliberately not a check: tells you whether the DUT's
    // own $readmemh found imem.mem. Nothing in this repo ships that file, so X
    // here is expected today -- it is worth printing because the same X is
    // what a real core would silently fetch and decode (ASSUME-5).
    task automatic probe_uninitialised();
        if ($isunknown(dut.instruction_memory[0]))
            $display("[%0t] NOTE  imem.mem was NOT loaded by the DUT: word 0 is X. In a core-level run this X reaches DECODE unguarded.",
                     $time);
        else
            $display("[%0t] NOTE  DUT's $readmemh loaded word 0 = 0x%08h; about to overwrite the image.",
                     $time, dut.instruction_memory[0]);
    endtask

    // Present a PC for one whole cycle: set it up at the negedge so it has a
    // half period of margin before the sampling edge (ASSUME-3), then step
    // across the edge and let the registered outputs settle.
    //
    // check_before_edge exercises TIME-1. It compares against the PREVIOUS
    // fetch's outputs, so the caller must have parked somewhere different for
    // it to be able to falsify anything -- see park_far().
    task automatic fetch(
        input string        tag,
        input string        note,
        input logic [31:0]  pc_val,
        input bit           check_before_edge = 1
    );
        @(negedge CLK);
        PC = pc_val;

        if (check_before_edge) begin
            #1;                    // mid-cycle: address is up, edge has not come
            checks++;
            if (instruction !== prev_instruction) begin
                errors++;
                $error("[%0t] FAIL [TIME-1] %s | registered read: instruction changed BEFORE the sampling edge -- PC=0x%08h, held 0x%08h, now 0x%08h. A combinational read passes every value check in this file and fails only here.",
                       $time, note, pc_val, prev_instruction, instruction);
            end
        end

        @(posedge CLK);
        #1;                        // let the clocked outputs resolve
        check_fetch(tag, note, pc_val);
    endtask

    // Park at an address guaranteed to differ from the next one under test, so
    // the transition into it is a real change rather than a no-op. Its own
    // TIME-1 check is off because the value it is transitioning from is not
    // controlled.
    task automatic park_far(input logic [31:0] away_from);
        fetch("TIME-1", "parking fetch", away_from ^ 32'h0000_0FF0, 0);
    endtask

    //------------------------------------------------------------------------
    // Checker
    //
    // Every fetch is two checks, never one: the word (FUNC-1) and the address
    // that fetched it (TIME-2). Checking only the word would let PC_USED slip a
    // cycle undetected, which is the exact failure the 9/2/2026 IF/ID decision
    // created the risk of.
    //------------------------------------------------------------------------
    task automatic check_fetch(
        input string        tag,
        input string        note,
        input logic [31:0]  pc_val
    );
        logic [31:0] expected;
        expected = ref_instruction(pc_val);

        // '===' not '==': an X out of an unloaded array or an unreset output
        // must FAIL. With '==' the comparison itself returns X and slides
        // through as "not a mismatch".
        checks++;
        if (instruction !== expected) begin
            errors++;
            $error("[%0t] FAIL [%s] %s | PC=0x%08h (word %0d) -> instruction=0x%08h, expected 0x%08h. Image is {FACE,byte_addr}, so the low half of what you got is the address actually read.",
                   $time, tag, note, pc_val, ref_index(pc_val), instruction, expected);
        end

        checks++;
        if (PC_USED !== pc_val) begin
            errors++;
            $error("[%0t] FAIL [TIME-2] %s | PC=0x%08h -> PC_USED=0x%08h. instruction and PC_USED must be captured on the same edge; CPU_TOP builds PC+4 and id_ex_d.PC out of PC_USED.",
                   $time, note, pc_val, PC_USED);
        end

        prev_instruction = instruction;
        prev_pc_used     = PC_USED;

        // Once PIPELINE_REG_STRUCT_PKG.sv compiles, import CPU_pkg::* at the
        // top and uncomment for a readable fetch trace:
        //   $display("[%0t] fetch 0x%08h -> %s", $time, pc_val,
        //            decode_instr_name(instruction).name());
    endtask

    //------------------------------------------------------------------------
    // A real instruction sequence, hand-encoded from the ISA spec's field
    // diagrams. Overlaid on the FACE image at address 0 so the sequential
    // fetch test looks like an actual fetch stream -- a decode-side bug that
    // only shows up on plausible encodings has somewhere to appear.
    //------------------------------------------------------------------------
    task automatic overlay_program();
        logic [31:0] prog [] = '{
            32'h0000_0013,   // nop            (addi x0, x0, 0)
            32'h0010_0093,   // addi x1, x0, 1
            32'h0020_0113,   // addi x2, x0, 2
            32'h0020_81B3,   // add  x3, x1, x2
            32'h4020_8233,   // sub  x4, x1, x2
            32'h0000_A283,   // lw   x5, 0(x1)
            32'h0051_2023,   // sw   x5, 0(x2)
            32'hFE00_0CE3    // beq  x0, x0, -8
        };
        foreach (prog[i]) begin
            golden[i]                 = prog[i];
            dut.instruction_memory[i] = prog[i];
        end
    endtask

    //------------------------------------------------------------------------
    // Directed cases, in contract order.
    //------------------------------------------------------------------------
    initial begin
        PC               = 32'h0000_0000;
        prev_instruction = 'x;
        prev_pc_used     = 'x;

        $display("===== IMEM_tb : 32 KB (%0d words), %0d ns clock =====",
                 NUM_WORDS, CLK_PERIOD);

        #1;                        // strictly after the DUT's time-0 $readmemh
        probe_uninitialised();
        backdoor_load();
        overlay_program();

        //--------------------------------------------------------------------
        // FUNC-1 / TIME-1 / TIME-2. The first fetch of a run cannot check
        // TIME-1 (there is no previous value to have held), so it is off here
        // and every case after it has it on.
        //--------------------------------------------------------------------
        $display("\n----- FUNC-1: word at PC, at both ends of the map -----");
        fetch("FUNC-1", "word 0 must be the first word of the image",
              32'h0000_0000, 0);
        fetch("FUNC-1", "word 1: a 1-word step must move the read by 1 index, not 4",
              32'h0000_0004);
        fetch("FUNC-1", "an address inside the second 4 KB",
              32'h0000_1004);

        // The top word needs a 13-bit index. IMEM.sv declares wordAddress as
        // [11:0], which cannot represent 8191, so this case is the one that
        // catches the too-narrow decode.
        park_far(LAST_WORD_ADDR);
        fetch("FUNC-1", "last word of 32 KB: index 8191 needs 13 bits of decode",
              LAST_WORD_ADDR);

        //--------------------------------------------------------------------
        // FUNC-2: PC[1:0] carries no address information. A DUT that rounded
        // up, or that let the low bits leak into the index, fetches the wrong
        // instruction only on these.
        //--------------------------------------------------------------------
        $display("\n----- FUNC-2: PC[1:0] ignored -----");
        park_far(32'h0000_0100);
        fetch("FUNC-2", "PC+1 must still return the word at PC, not the next word",
              32'h0000_0101);
        fetch("FUNC-2", "PC+3 must truncate down, never round up",
              32'h0000_0103);

        //--------------------------------------------------------------------
        // FUNC-3: aliasing. Each pair below is chosen so that one specific
        // decode mistake collapses it.
        //--------------------------------------------------------------------
        $display("\n----- FUNC-3: no aliasing across the full 32 KB -----");

        // A 12-bit wordAddress cannot separate index 1 from index 4097, so
        // these two must be shown to be different words.
        park_far(32'h0000_0004);
        fetch("FUNC-3", "index 1 vs index 4097: a 12-bit wordAddress aliases them",
              32'h0000_0004);
        fetch("FUNC-3", "index 4097 -- the alias partner of 0x0004",
              32'h0000_4004);

        // {PC[9:2], 2'b0} only ever produces indices 0,4,8,...,1020, so every
        // address above 4 KB collapses into the bottom 4 KB and only every
        // fourth word is reachable. These three must all differ.
        park_far(32'h0000_0008);
        fetch("FUNC-3", "index 2 must not collapse into index 8",
              32'h0000_0008);
        fetch("FUNC-3", "index 2048 is above any 10-bit decode's reach",
              32'h0000_2000);
        fetch("FUNC-3", "index 6144 is above any 12-bit decode's reach",
              32'h0000_6000);

        //--------------------------------------------------------------------
        // FUNC-4: read-only. Nothing on this interface can write, so the same
        // address must read identically after the whole map has been walked.
        //--------------------------------------------------------------------
        $display("\n----- FUNC-4: read-only, contents stable -----");
        park_far(32'h0000_0000);
        fetch("FUNC-4", "re-read of word 0 after exercising the rest of memory",
              32'h0000_0000);
        park_far(LAST_WORD_ADDR);
        fetch("FUNC-4", "re-read of the last word after exercising the rest",
              LAST_WORD_ADDR);

        //--------------------------------------------------------------------
        // FUNC-5: PC_USED is 32 bits wide on purpose. Driving a PC with bits
        // set above the memory's range separates "passed through" from
        // "truncated to the address width" -- the instruction that comes back
        // is a documented alias (ASSUME-2) and is not checked here, only
        // reported.
        //--------------------------------------------------------------------
        $display("\n----- FUNC-5: PC_USED is a full 32-bit passthrough -----");
        @(negedge CLK);
        PC = 32'h8000_1004;
        @(posedge CLK);
        #1;
        checks++;
        if (PC_USED !== 32'h8000_1004) begin
            errors++;
            $error("[%0t] FAIL [FUNC-5] PC=0x8000_1004 -> PC_USED=0x%08h. PC_USED must not be truncated to the memory's address width; CPU_TOP feeds PC_USED+4 back into Program_Counter and latches id_ex_d.PC from it.",
                   $time, PC_USED);
        end
        $display("[%0t] NOTE  [ASSUME-2] out-of-range PC=0x8000_1004 returned 0x%08h with no error output. Silent aliasing into 0x%08h.",
                 $time, instruction, {17'b0, PC[IDX_MSB:2], 2'b0});
        prev_instruction = instruction;

        //--------------------------------------------------------------------
        // TIME-3: back-to-back fetches, one per cycle, no idle gap. This is
        // what FETCH actually does. A one-deep output register that needed a
        // dead cycle, or a PC_USED path with different latency from the data
        // path, passes every isolated case above and fails here.
        //--------------------------------------------------------------------
        $display("\n----- TIME-3: sustained one-fetch-per-cycle stream -----");
        park_far(32'h0000_0000);
        for (int i = 0; i < 8; i++) begin
            @(negedge CLK);
            PC = 32'h0000_0000 + (i * 4);
            @(posedge CLK);
            #1;
            check_fetch("TIME-3",
                        "gapless sequential fetch: instruction and PC_USED must stay the matched pair",
                        32'h0000_0000 + (i * 4));
        end

        //--------------------------------------------------------------------
        // TIME-4: hold PC still. Outputs must be stable across cycles, not a
        // one-shot pulse -- DECODE reads them combinationally all cycle long.
        //--------------------------------------------------------------------
        $display("\n----- TIME-4: outputs hold while PC is held -----");
        park_far(32'h0000_0200);
        @(negedge CLK);
        PC = 32'h0000_0200;
        repeat (3) begin
            @(posedge CLK);
            #1;
            check_fetch("TIME-4", "PC held constant: same word, same PC_USED, every cycle",
                        32'h0000_0200);
        end

        //--------------------------------------------------------------------
        // Random sweep over the full word-aligned address space. The directed
        // cases cover the decode mistakes that could be reasoned about; this
        // covers the interior, including any index whose bit pattern happens to
        // break an arithmetic error the corners missed.
        //--------------------------------------------------------------------
        $display("\n----- FUNC-R: 1000 random word-aligned fetches -----");
        begin
            logic [31:0] rand_pc;
            repeat (1000) begin
                rand_pc = 32'($urandom_range(NUM_WORDS-1, 0)) << 2;
                @(negedge CLK);
                PC = rand_pc;
                @(posedge CLK);
                #1;
                check_fetch("FUNC-R", "random word-aligned address", rand_pc);
            end
        end

        //--------------------------------------------------------------------
        // FUNC-4, the strong form. Every fetch above went through the port; a
        // stray write would only show on addresses the sweep did not revisit.
        // Scanning the array directly is the only way to prove no word moved.
        //--------------------------------------------------------------------
        $display("\n----- FUNC-4: full array scan for unintended writes -----");
        begin
            int corrupted = 0;
            for (int w = 0; w < NUM_WORDS; w++) begin
                if (dut.instruction_memory[w] !== golden[w]) begin
                    corrupted++;
                    if (corrupted <= 8)
                        $error("[%0t] FAIL [FUNC-4] word %0d (byte 0x%08h) changed during the run: 0x%08h, loaded 0x%08h. A read-only memory must have no path that writes.",
                               $time, w, w*4, dut.instruction_memory[w], golden[w]);
                end
            end
            checks++;
            if (corrupted != 0) begin
                errors++;
                $display("[%0t] FAIL [FUNC-4] %0d of %0d words changed (first 8 listed).",
                         $time, corrupted, NUM_WORDS);
            end
        end

        //--------------------------------------------------------------------
        // Coverage / completeness notes
        //
        // Covered: every word index reachable by directed corner + 1000 random
        // fetches; both ends of the 32 KB map; the specific alias pairs that a
        // 10-bit and a 12-bit decode collapse; PC[1:0] truncation; one-cycle
        // latency both directions (not-yet-valid and then valid); gapless
        // streaming; held-PC stability; whole-array read-only integrity.
        //
        // NOT covered here, and not coverable through this port list:
        //   - Stall/flush behaviour. IMEM has no enable, so "hold this fetch"
        //     is not expressible (ASSUME-4b). It becomes a real gap the moment
        //     you add load-use hazard stalls.
        //   - Reset. IMEM has no reset port, so the state of instruction and
        //     PC_USED during the first cycle out of RST is a CPU_TOP-level
        //     question (ASSUME-4a), not a module-level one.
        //   - Out-of-range fetch. Reported as a NOTE under FUNC-5 rather than
        //     checked, because IMEM has no defined behaviour to check against
        //     (ASSUME-2). Decide what you want it to do first.
        //   - Real program semantics. overlay_program() only supplies plausible
        //     encodings; nothing here executes them. That is the core-level
        //     harness in AGENTS.md section 9.
        //--------------------------------------------------------------------
        $display("\n=====================================================");
        $display(" %0d / %0d checks passed", checks - errors, checks);
        $display("=====================================================");

        if (errors) $fatal(1, "IMEM_tb: %0d check(s) failed", errors);
        $finish;
    end

endmodule

// ---------------------------------------------------------------------------
// XCELIUM RUN NOTES  (nanoHUB / Cadence -- run from tb/)
// ---------------------------------------------------------------------------
// IMEM.sv does not elaborate yet. Start here, because it is the fastest way to
// work the blocker list in the header down to zero:
//
//   xrun -sv -elaborate ../rtl/IMEM.sv
//
// Then compile + elaborate + run. IMEM_tb does not import CPU_pkg, so the
// package is NOT in the filelist and the package's current compile errors
// cannot block this run:
//
//   xrun -sv -timescale 1ns/1ps -access +rwc -l IMEM_tb.log \
//        ../rtl/IMEM.sv \
//        IMEM_tb.sv
//
//   -sv              treat inputs as SystemVerilog
//   -access +rwc     REQUIRED, not optional: the back-door image load writes
//                    dut.instruction_memory hierarchically. Without it the
//                    load silently does nothing and every FUNC check fails
//                    against X.
//   -l <file>        tee the transcript to a log you can grep for FAIL
//   -clean           add this to force a full rebuild if a stale INCA_libs
//                    directory is giving you confusing errors
//
// If your nanoHUB copy keeps the RTL flat alongside tb/ (the way ALU_tb's
// notes assume), drop the rtl/ and use ../IMEM.sv.
//
// No imem.mem is needed. The testbench loads its own image and reports whether
// the DUT's $readmemh found a file. When you do write one, note that
// $readmemh("imem.mem", instruction_memory, 0, 8191) names an explicit finish
// address, so Xcelium warns unless the file holds all 8192 entries -- dropping
// the 0, 8191 arguments makes a short file legal.
//
// Waveforms in SimVision:
//   Uncomment the $shm_open / $shm_probe block above, rerun, then:
//        simvision waves.shm &
//
//   Or launch interactively and drive it from the GUI:
//   xrun -sv -access +rwc -gui ../rtl/IMEM.sv IMEM_tb.sv
//
// Quick pass/fail check without reading the whole transcript:
//   grep -c FAIL IMEM_tb.log
//   echo $?            # 0 from xrun means no $fatal, so no failing checks
// ---------------------------------------------------------------------------
