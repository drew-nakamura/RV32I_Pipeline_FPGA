`timescale 1ns/1ps
//============================================================================
// Testbench: ALU_tb
// DUT:       ../ALU.sv
// Stage:     EX
// Date:      9/12/2026
//
// Role in system:
//   The ALU is the only arithmetic element(excluding the adders for address cal
//   calculations and immediate generation) in the EX stage. Control_Unit_Decoder
//   picks ALU_FUN in DECODE, it rides the ID/EX register into EX, and srcA/srcB
//   arrive from the srcA 2:1 and srcB 4:1 muxes. The result fans out to two
//   very different consumers: the EX/MEM register (writeback data) and the DMEM
//   address port (load/store effective address). That second path is why an
//   arithmetic bug here does not look like an ALU bug -- it looks like memory
//   returning garbage three stages later.
//
// Verification strategy:
//   Directed cases derived from the RISC-V Unprivileged ISA spec, one group per
//   contract line, then an exhaustive sweep of all 16 alu_func encodings, then
//   a corner x corner plus constrained-random sweep. The reference model is
//   written from the ISA spec, not transcribed from ALU.sv, so a bug in the RTL
//   cannot hide inside a matching bug in the checker.
//
// KNOWN ELABORATION BLOCKERS (all in ../PIPELINE_REG_STRUCT_PKG.sv, not in the
// ALU). This file imports CPU_pkg, so xrun will not get as far as the ALU until
// the package compiles:
//   - id_ex_t / ex_mem_t / third struct separate members with ',' not ';'
//   - third struct (line ~103) has no typedef name and no closing ';'
//   - 'loigc' typo, lines 97 and 110
//   - 'instruction_e' / 'STAGE_e' (lines 86-87) do not exist; the declared
//     types are 'instr_name_e' and 'stage_e'
//   - enum declares AUPIC, decode_instr_name() assigns AUIPC
//   - no 'endpackage'
// ALU.sv itself elaborates standalone and is unchanged by any of this.
//============================================================================

//----------------------------------------------------------------------------
// CONTRACT UNDER TEST
//----------------------------------------------------------------------------
// FUNC-1  alu_ADD / alu_SUB are 32-bit two's complement and WRAP on overflow.
//         RISC-V defines no overflow trap and no flags.        [ISA Vol I 2.4]
// FUNC-2  alu_SLT compares SIGNED, alu_SLTU compares UNSIGNED. The result is
//         exactly 32'd1 or 32'd0 -- never a sign-extended -1, never a 1-bit
//         value zero-extended by luck.
// FUNC-3  Shifts (SLL/SRL/SRA) use ONLY srcB[4:0]. srcB[31:5] must be ignored,
//         so a shift by 32 is a shift by 0 and a shift by 33 is a shift by 1.
// FUNC-4  alu_SRA is arithmetic (replicates srcA[31]); alu_SRL is logical and
//         fills with zeros. The two differ only when srcA is negative.
// FUNC-5  alu_LUI_COPY passes srcA through unmodified and ignores srcB.
//         Immediate_Generator has already applied the 12-bit shift for U-type,
//         so the ALU must NOT shift again.
// FUNC-6  AND/OR/XOR are plain 32-bit bitwise operations, no sign involvement.
// FUNC-7  Every one of the 11 encodings defined in CPU_pkg::alu_op_e must be
//         decoded to its own operation. No two ops may alias.
//
// TIME-1  result is purely combinational: no clock, no state, no latch. The
//         same inputs must always produce the same output, regardless of what
//         was driven in between. An incomplete case or a missing default in a
//         future edit would show up here as replay drift.
//
// ASSUME-1 alu_func may carry an encoding NOT defined in alu_op_e (4'b1010,
//          1011, 1100, 1110, 1111). ALU.sv's default returns 32'b0, which is a
//          silent value: an illegal operation is indistinguishable from a
//          legitimate zero result. This TB asserts the current behaviour so
//          that changing it is a deliberate act, not an accident.
// ASSUME-2 ALU.sv uses raw 4'b literals and does NOT import CPU_pkg, so nothing
//          in the compiler enforces that the two agree. They agree today. This
//          TB drives CPU_pkg enums and separately asserts the literal values,
//          so it fails loudly if they ever diverge.
// ASSUME-3 alu_func can legally be X. Control_Unit_Decoder.sv drives
//          ALU_FUN = 'X on every illegal opcode (line 143) and on undefined
//          func3 (lines 102, 120), and there is no valid bit between DECODE and
//          EX to squash it. ALU.sv's case then falls through to default and
//          converts that X into a clean 32'b0 -- a decoder failure becomes a
//          plausible-looking zero in the datapath instead of a loud X. Flagged
//          for a design decision, not asserted as correct.
// ASSUME-4 srcA / srcB are stable before they are sampled downstream, and X on
//          a data operand must propagate rather than be masked away.
//----------------------------------------------------------------------------

import CPU_pkg::*;

module ALU_tb;

    //------------------------------------------------------------------------
    // Parameters
    //------------------------------------------------------------------------
    localparam time SETTLE = 1ns;   // time for the combinational cloud to resolve

    //------------------------------------------------------------------------
    // DUT signals
    //------------------------------------------------------------------------
    logic [31:0] srcA, srcB;
    logic [3:0]  alu_func;
    logic [31:0] result;

    int checks = 0;
    int errors = 0;

    ALU dut (
        .srcA     (srcA),
        .srcB     (srcB),
        .alu_func (alu_func),
        .result   (result)
    );

    // No clock or reset generation: the DUT is combinational by contract
    // (TIME-1), and giving this TB a clock would imply otherwise.

    //------------------------------------------------------------------------
    // Stimulus pools
    //------------------------------------------------------------------------
    alu_op_e defined_ops [] = '{alu_ADD, alu_SUB, alu_AND, alu_OR, alu_XOR,
                                alu_SLL, alu_SRL, alu_SRA, alu_SLT, alu_SLTU,
                                alu_LUI_COPY};

    // The values that break signed/unsigned confusion, plus the shift-amount
    // boundary. Random generation lands on these almost never.
    logic [31:0] corners [] = '{32'h0000_0000, 32'h0000_0001, 32'h0000_001F,
                                32'h0000_0020, 32'h7FFF_FFFF, 32'h8000_0000,
                                32'hFFFF_FFFF};

    //------------------------------------------------------------------------
    // Replay bookkeeping for TIME-1.
    //
    // Every directed case records its stimulus and the value the DUT actually
    // produced. At the end of the run the whole list is re-applied and compared
    // against those recordings -- DUT vs its own past self, with no reference
    // model involved. That is what catches an accidental latch: a latch agrees
    // with the reference on first touch and only disagrees after the input has
    // moved away and come back.
    //------------------------------------------------------------------------
    typedef struct {
        logic [3:0]  func;
        logic [31:0] a;
        logic [31:0] b;
    } stim_t;

    stim_t       stim_log [$];
    logic [31:0] obs_log  [$];
    bit          recording = 1'b0;

    // Loop temporaries live here rather than inside the loop bodies: nested
    // declarations in unnamed blocks are legal SystemVerilog but not every
    // tool flow agrees, and this TB has to survive a strict elaborate.
    alu_op_e     probe;
    logic [31:0] rnd_a;

    //------------------------------------------------------------------------
    // Stimulus tasks
    //------------------------------------------------------------------------
    task automatic apply(input logic [3:0]  func,
                         input logic [31:0] a,
                         input logic [31:0] b);
        srcA     = a;
        srcB     = b;
        alu_func = func;
        #SETTLE;
    endtask

    // Drive something deliberately unrelated, so that the next apply() is a
    // genuine transition on every input rather than a no-op the DUT can sleep
    // through.
    task automatic park_inputs();
        apply(alu_XOR, 32'h5A5A_5A5A, 32'hA5A5_A5A5);
    endtask

    //------------------------------------------------------------------------
    // Golden reference model
    //
    // Written from the ISA spec. The ENCODINGS come from CPU_pkg because those
    // are a shared interface fact; the BEHAVIOURS are stated independently of
    // ALU.sv on purpose. The argument is logic [3:0] rather than alu_op_e so
    // that undefined encodings can be driven -- the DUT's port is 4 bits wide
    // and therefore so is its real input space (ASSUME-1).
    //------------------------------------------------------------------------
    function automatic logic [31:0] alu_ref(input logic [3:0]  func,
                                            input logic [31:0] a,
                                            input logic [31:0] b);
        logic [4:0] shamt = b[4:0];   // FUNC-3: srcB[31:5] is not part of the shift amount

        case (func)
            alu_ADD      : return a + b;                                    // FUNC-1
            alu_SUB      : return a - b;                                    // FUNC-1
            alu_SLT      : return ($signed(a) <  $signed(b)) ? 32'd1 : 32'd0; // FUNC-2
            alu_SLTU     : return (a < b)                    ? 32'd1 : 32'd0; // FUNC-2
            alu_SLL      : return a << shamt;                               // FUNC-3
            alu_SRL      : return a >> shamt;                               // FUNC-3/4
            alu_SRA      : return $signed(a) >>> shamt;                     // FUNC-4
            alu_LUI_COPY : return a;                                        // FUNC-5
            alu_AND      : return a & b;                                    // FUNC-6
            alu_OR       : return a | b;                                    // FUNC-6
            alu_XOR      : return a ^ b;                                    // FUNC-6
            default      : return 32'd0;   // ASSUME-1 / ASSUME-3, not a spec claim
        endcase
    endfunction

    // Undefined encodings have no .name(), and calling .name() on one is not
    // something to find out about at 3am in a log file.
    function automatic string op_name(input logic [3:0] func);
        alu_op_e op;
        if ($cast(op, func)) return op.name();
        else                 return $sformatf("UNDEFINED_4'b%4b", func);
    endfunction

    //------------------------------------------------------------------------
    // Checker. Every call carries the contract ID it defends, so the failure
    // message says which bucket of the design is wrong before the designer
    // opens a waveform.
    //------------------------------------------------------------------------
    task automatic check(input string        tag,    // e.g. "FUNC-3"
                         input string        note,   // hypothesis this case falsifies
                         input logic [3:0]   func,
                         input logic [31:0]  a,
                         input logic [31:0]  b);
        logic [31:0] expected;

        apply(func, a, b);
        expected = alu_ref(func, a, b);
        checks++;

        // '===' not '==' : an X on result must FAIL. With '==' an unknown
        // compares as unknown, the if() takes the false branch, and an
        // uninitialised output slides through as a pass.
        if (result !== expected) begin
            errors++;
            $error("[%0t] FAIL [%s] %s | %s  srcA=0x%08h srcB=0x%08h -> 0x%08h, expected 0x%08h",
                   $time, tag, op_name(func), note, a, b, result, expected);
        end

        if (recording) begin
            stim_log.push_back('{func: func, a: a, b: b});
            obs_log.push_back(result);
        end
    endtask

    // ASSUME-2: the encodings on the right are transcribed from ALU.sv's case
    // labels, which is allowed -- an encoding is an interface fact. This is a
    // tripwire for interface drift, nothing more: if the package moves and the
    // hardcoded ALU literals do not, every functional check below would start
    // testing the wrong operation and the failures would look like logic bugs.
    task automatic check_encoding(input string name, input logic [3:0] pkg_val,
                                                    input logic [3:0] rtl_val);
        checks++;
        if (pkg_val !== rtl_val) begin
            errors++;
            $error("[%0t] FAIL [ASSUME-2] encoding drift: CPU_pkg::%s = 4'b%4b but ALU.sv decodes 4'b%4b",
                   $time, name, pkg_val, rtl_val);
        end
    endtask

    task automatic replay_for_hidden_state();
        foreach (stim_log[i]) begin
            park_inputs();
            apply(stim_log[i].func, stim_log[i].a, stim_log[i].b);
            checks++;
            if (result !== obs_log[i]) begin
                errors++;
                $error("[%0t] FAIL [TIME-1] %s hidden state: srcA=0x%08h srcB=0x%08h -> 0x%08h on replay, was 0x%08h",
                       $time, op_name(stim_log[i].func), stim_log[i].a,
                       stim_log[i].b, result, obs_log[i]);
            end
        end
    endtask

    //------------------------------------------------------------------------
    // Directed cases, in contract order.
    //------------------------------------------------------------------------
    initial begin
        $display("===== ALU_tb =====");

        // ---- ASSUME-2 first: if the encodings disagree, nothing below means
        // what it claims to mean, so the designer should see this at the top.
        check_encoding("alu_ADD",      alu_ADD,      4'b0000);
        check_encoding("alu_SUB",      alu_SUB,      4'b1000);
        check_encoding("alu_OR",       alu_OR,       4'b0110);
        check_encoding("alu_AND",      alu_AND,      4'b0111);
        check_encoding("alu_XOR",      alu_XOR,      4'b0100);
        check_encoding("alu_SRL",      alu_SRL,      4'b0101);
        check_encoding("alu_SLL",      alu_SLL,      4'b0001);
        check_encoding("alu_SRA",      alu_SRA,      4'b1101);
        check_encoding("alu_SLT",      alu_SLT,      4'b0010);
        check_encoding("alu_SLTU",     alu_SLTU,     4'b0011);
        check_encoding("alu_LUI_COPY", alu_LUI_COPY, 4'b1001);

        recording = 1'b1;   // from here on, directed stimulus is replayed at the end

        //--------------------------------------------------------------------
        // FUNC-1: wrap-around is defined behaviour, not an error case. A DUT
        // that tried to saturate or that widened the adder to catch carry would
        // fail here and nowhere else.
        //--------------------------------------------------------------------
        check("FUNC-1", "max positive + 1 must wrap to min negative",
              alu_ADD, 32'h7FFF_FFFF, 32'h0000_0001);
        check("FUNC-1", "all-ones + 1 must wrap to zero, carry discarded",
              alu_ADD, 32'hFFFF_FFFF, 32'h0000_0001);
        check("FUNC-1", "0 - 1 must borrow to all-ones",
              alu_SUB, 32'h0000_0000, 32'h0000_0001);
        // SUB is the one operation where swapped operands are silent: A-B and
        // B-A are both plausible-looking numbers. Only an asymmetric pair
        // exposes it.
        check("FUNC-1", "operand order: 5 - 3 must be 2, not 0xFFFFFFFE",
              alu_SUB, 32'd5, 32'd3);
        check("FUNC-1", "min negative - 1 must wrap to max positive",
              alu_SUB, 32'h8000_0000, 32'h0000_0001);

        //--------------------------------------------------------------------
        // FUNC-2: the classic signed/unsigned confusion. 0x80000000 is the most
        // negative signed value but the largest-magnitude unsigned one, so a
        // DUT using the wrong comparison passes SLT and fails SLTU, or the
        // reverse. Equality is included because '<' and '<=' are one keystroke
        // apart and a DUT with '<=' passes every unequal case.
        //--------------------------------------------------------------------
        check("FUNC-2", "signed: 0x80000000 is negative, so it is < 1",
              alu_SLT,  32'h8000_0000, 32'h0000_0001);
        check("FUNC-2", "unsigned: 0x80000000 is huge, so it is NOT < 1",
              alu_SLTU, 32'h8000_0000, 32'h0000_0001);
        check("FUNC-2", "signed: -1 < 0",
              alu_SLT,  32'hFFFF_FFFF, 32'h0000_0000);
        check("FUNC-2", "unsigned: 0xFFFFFFFF is the maximum, never < 0",
              alu_SLTU, 32'hFFFF_FFFF, 32'h0000_0000);
        check("FUNC-2", "equal operands are NOT less-than (signed)",
              alu_SLT,  32'h1234_5678, 32'h1234_5678);
        check("FUNC-2", "equal operands are NOT less-than (unsigned)",
              alu_SLTU, 32'h1234_5678, 32'h1234_5678);
        // A DUT that returned a sign-extended -1 for true, or that left the
        // upper 31 bits of result undriven, fails on the whole-word compare.
        check("FUNC-2", "true must be exactly 32'd1 in all 32 bits",
              alu_SLT,  32'hFFFF_FFFF, 32'h7FFF_FFFF);

        //--------------------------------------------------------------------
        // FUNC-3: shift amount masking. A DUT that forgot srcB[4:0] passes
        // every shift under 32, so the small amounts prove nothing on their
        // own -- 32 and 33 are the whole reason these cases exist.
        //--------------------------------------------------------------------
        check("FUNC-3", "shift by 0 must be a pass-through",
              alu_SLL, 32'hDEAD_BEEF, 32'd0);
        check("FUNC-3", "shift by 31 must leave exactly one bit",
              alu_SLL, 32'h0000_0001, 32'd31);
        check("FUNC-3", "shift by 32 must behave as shift by 0, not clear",
              alu_SLL, 32'hDEAD_BEEF, 32'd32);
        check("FUNC-3", "shift by 33 must behave as shift by 1",
              alu_SLL, 32'hDEAD_BEEF, 32'd33);
        check("FUNC-3", "SRL by 32 must behave as shift by 0",
              alu_SRL, 32'hDEAD_BEEF, 32'd32);
        check("FUNC-3", "SRA by 32 must behave as shift by 0",
              alu_SRA, 32'h8000_0000, 32'd32);
        check("FUNC-3", "high bits of srcB must be ignored entirely",
              alu_SRL, 32'hDEAD_BEEF, 32'hFFFF_FFE4);   // low 5 bits = 4

        // Every legal shift amount, with srcB[31:5] set to garbage the DUT is
        // required to discard. This is the exhaustive version of the two cases
        // above: it catches a mask that is off by a bit (srcB[3:0] or
        // srcB[5:0]) rather than missing outright.
        for (int s = 0; s < 32; s++) begin
            check("FUNC-3", "srcB[31:5] garbage must not affect SLL",
                  alu_SLL, 32'hDEAD_BEEF, {27'h7FF_FFFF, s[4:0]});
            check("FUNC-3", "srcB[31:5] garbage must not affect SRL",
                  alu_SRL, 32'hDEAD_BEEF, {27'h7FF_FFFF, s[4:0]});
            check("FUNC-3", "srcB[31:5] garbage must not affect SRA",
                  alu_SRA, 32'h8000_0001, {27'h7FF_FFFF, s[4:0]});
        end

        //--------------------------------------------------------------------
        // FUNC-4: sign replication. SRL and SRA produce identical answers for
        // every non-negative srcA, so a swapped SRL/SRA opcode pair is
        // invisible unless srcA[31] is set. All of these use negative srcA on
        // purpose.
        //--------------------------------------------------------------------
        check("FUNC-4", "arithmetic shift must replicate the sign bit",
              alu_SRA, 32'h8000_0000, 32'd4);
        check("FUNC-4", "logical shift must fill with zeros",
              alu_SRL, 32'h8000_0000, 32'd4);
        check("FUNC-4", "SRA of -1 by 31 must still be -1",
              alu_SRA, 32'hFFFF_FFFF, 32'd31);
        check("FUNC-4", "SRL of -1 by 31 must leave exactly 1",
              alu_SRL, 32'hFFFF_FFFF, 32'd31);
        check("FUNC-4", "SRA must NOT sign-extend a positive srcA",
              alu_SRA, 32'h7FFF_FFFF, 32'd4);

        //--------------------------------------------------------------------
        // FUNC-5: LUI's 12-bit shift belongs to Immediate_Generator, and srcB
        // for a U-type is whatever the srcB mux happens to be presenting. If
        // the ALU shifts again the constant lands 12 bits too high; if it uses
        // srcB at all, LUI's value depends on an unrelated register.
        //--------------------------------------------------------------------
        check("FUNC-5", "LUI copy must not re-shift the already-shifted immediate",
              alu_LUI_COPY, 32'hABCD_E000, 32'h0000_0000);
        check("FUNC-5", "LUI copy must ignore srcB entirely",
              alu_LUI_COPY, 32'hABCD_E000, 32'hFFFF_FFFF);
        check("FUNC-5", "LUI copy must not sign-extend or mask the top bit",
              alu_LUI_COPY, 32'h8000_0000, 32'h1234_5678);

        //--------------------------------------------------------------------
        // FUNC-6: alternating patterns so that an AND/OR swap cannot produce
        // the same answer by coincidence, and self-XOR because it is the one
        // case that must clear all 32 bits.
        //--------------------------------------------------------------------
        check("FUNC-6", "bitwise AND across alternating patterns",
              alu_AND, 32'hAAAA_AAAA, 32'h5555_5555);
        check("FUNC-6", "bitwise OR across alternating patterns must fill",
              alu_OR,  32'hAAAA_AAAA, 32'h5555_5555);
        check("FUNC-6", "XOR with itself must clear",
              alu_XOR, 32'hDEAD_BEEF, 32'hDEAD_BEEF);
        check("FUNC-6", "AND with all-ones must pass srcA through",
              alu_AND, 32'hDEAD_BEEF, 32'hFFFF_FFFF);

        //--------------------------------------------------------------------
        // FUNC-7 / ASSUME-1: sweep all 16 encodings the 4-bit port can carry,
        // not just the 11 that are defined. One stimulus is deliberately reused
        // for every op, so two ops that alias to the same logic are visible as
        // a pair of results that should differ but do not -- and the five
        // undefined encodings get checked against ASSUME-1 rather than being
        // quietly skipped.
        //--------------------------------------------------------------------
        for (int f = 0; f < 16; f++) begin
            if ($cast(probe, f[3:0]))
                check("FUNC-7", "defined encoding must decode to its own operation",
                      f[3:0], 32'h8000_0F0F, 32'h0000_0004);
            else
                check("ASSUME-1", "undefined encoding returns a silent 32'b0",
                      f[3:0], 32'h8000_0F0F, 32'h0000_0004);
        end

        //--------------------------------------------------------------------
        // ASSUME-3: X on alu_func. This is reachable in the real pipeline --
        // Control_Unit_Decoder drives ALU_FUN = 'X on any illegal opcode and
        // nothing between DECODE and EX squashes it. The case statement cannot
        // match X, so the default fires and the X becomes a clean zero. The
        // check below asserts today's behaviour so that a future change to X
        // propagation is a decision rather than a surprise; if this line fails
        // after a DUT edit, ask whether the zero or the X is what you wanted.
        //--------------------------------------------------------------------
        check("ASSUME-3", "X on alu_func is absorbed into 32'b0, hiding a decode failure",
              4'bxxxx, 32'h0000_00FF, 32'h0000_000F);

        //--------------------------------------------------------------------
        // ASSUME-4: X on the data operands must propagate. A DUT that masked
        // or ignored an operand would turn an unknown into a definite value,
        // which is how a real bug becomes untraceable four stages downstream.
        // Both sides of the comparison use the same SystemVerilog operators
        // here, so this is testing that the DUT does not sanitise X -- not
        // that two implementations of X arithmetic agree.
        //--------------------------------------------------------------------
        check("ASSUME-4", "X in srcA must not be sanitised by ADD",
              alu_ADD, 32'hxxxx_xxxx, 32'h0000_0001);
        check("ASSUME-4", "AND with all-ones must keep X unknown, bit for bit",
              alu_AND, 32'hxxxx_xxxx, 32'hFFFF_FFFF);

        recording = 1'b0;   // the sweeps below are too large to replay

        //--------------------------------------------------------------------
        // Corner x corner, then constrained-random. The directed cases cover
        // the corners we could reason about in advance; this covers the
        // interior of the input space, and the corner cross-product covers the
        // pairs of boundary values that random generation almost never hits.
        //--------------------------------------------------------------------
        foreach (defined_ops[i]) begin
            foreach (corners[j])
                foreach (corners[k])
                    check("FUNC-R", "corner x corner", defined_ops[i],
                          corners[j], corners[k]);

            repeat (200)
                check("FUNC-R", "random", defined_ops[i], $urandom(), $urandom());

            // Adjacent operands. Purely random pairs are almost never close in
            // value, so an off-by-one in a comparator or a borrow that leaks
            // across the wrong bit survives the sweep above.
            repeat (50) begin
                rnd_a = $urandom();
                check("FUNC-R", "adjacent operands", defined_ops[i], rnd_a, rnd_a + 1);
                check("FUNC-R", "adjacent operands, reversed", defined_ops[i], rnd_a + 1, rnd_a);
            end
        end

        //--------------------------------------------------------------------
        // TIME-1: replay every directed case after thousands of unrelated
        // values have passed through the DUT, with a parking transition
        // between each one. A combinational block gives the same answer; a
        // latch gives whatever it was holding.
        //--------------------------------------------------------------------
        replay_for_hidden_state();

        //--------------------------------------------------------------------
        // Coverage / completeness notes
        //
        // Covered:
        //   - all 16 alu_func encodings, defined and undefined
        //   - all 32 legal shift amounts x 3 shift ops, with srcB[31:5] set to
        //     garbage that must be discarded
        //   - signed/unsigned boundaries at 0, 1, 0x7FFFFFFF, 0x80000000, -1,
        //     as a full cross product per operation
        //   - adjacent operand pairs (n, n+1) in both orders, per operation
        //   - X on alu_func and on a data operand
        //   - determinism replay of every directed case
        //
        // NOT covered here, and why:
        //   - srcA/srcB mux selection: that is 2_To_1_MUX / 4_TO_1_MUX, and a
        //     wrong operand reaching a correct ALU is their bug, not this one.
        //   - which ALU_FUN a given instruction should produce: that contract
        //     belongs to Control_Unit_Decoder_tb. This TB assumes only that
        //     whatever arrives is executed per the ISA.
        //   - the EX/MEM handoff timing of result. The ALU has no clock, so
        //     the setup margin into that register is a CPU_TOP-level property.
        //     Worth checking there: see the note in the reply about the ALU
        //     result net in CPU_TOP.sv.
        //--------------------------------------------------------------------

        $display("=========================================");
        $display(" %0d / %0d checks passed", checks - errors, checks);
        $display("=========================================");

        if (errors) $fatal(1, "ALU_tb: %0d check(s) failed", errors);
        $finish;
    end

    //Waveforms: uncomment for SimVision, then 'simvision waves.shm &'
    initial begin
        $shm_open("waves.shm");
        $shm_probe("AS");      // A = all signals, S = include sub-scopes
    end

endmodule

// ---------------------------------------------------------------------------
// XCELIUM RUN NOTES  (run from 5_Stage_Pipeline/tb/ on nanoHUB)
// ---------------------------------------------------------------------------
// NOTE: PIPELINE_REG_STRUCT_PKG.sv does not compile as of 9/12/2026 (see the
// blocker list in the header). Until it does, every command below stops in the
// package and never reaches ALU.sv. ALU.sv itself is clean:
//
//   xrun -sv -elaborate ../ALU.sv          <-- proves the DUT alone is fine
//
// Single-shot compile + elaborate + run:
//
//   xrun -sv -timescale 1ns/1ps -access +rwc -l ALU_tb.log \
//        ../PIPELINE_REG_STRUCT_PKG.sv \
//        ../ALU.sv \
//        ALU_tb.sv
//
//   -sv              treat inputs as SystemVerilog
//   -access +rwc     read/write/connectivity access, required for waveforms
//   -l <file>        tee the transcript to a log you can grep for FAIL
//   -clean           add this to force a full rebuild if a stale INCA_libs
//                    directory is giving you confusing errors
//
// Elaborate only (fastest way to check everything compiles):
//
//   xrun -sv -elaborate ../PIPELINE_REG_STRUCT_PKG.sv ../ALU.sv ALU_tb.sv
//
// Waveforms in SimVision:
//   Uncomment the $shm_open / $shm_probe block above, rerun, then:
//        simvision waves.shm &
//
//   Or launch interactively and drive it from the GUI:
//   xrun -sv -access +rwc -gui ../PIPELINE_REG_STRUCT_PKG.sv ../ALU.sv ALU_tb.sv
//
// Quick pass/fail check without reading the whole transcript:
//   grep -c FAIL ALU_tb.log
//   echo $?            # 0 from xrun means no $fatal, so no failing checks
// ---------------------------------------------------------------------------
