# Testbench Authoring Spec — OTTER 5-Stage Pipeline

**Audience:** any AI agent asked to write a testbench for a module in `5_Stage_Pipeline/`.
**Read this file completely before writing a single line of SystemVerilog.**

The owner of this repo is an RTL designer, not a verification engineer. The purpose of
every testbench you write is not to make tests pass — it is to **tell the designer
whether the module is wrong, and in what way.** A testbench that passes while hiding a
architectural mistake is worse than no testbench at all.

---

## 0. Hard guardrails — non-negotiable

1. **You may only create or edit files inside `5_Stage_Pipeline/tb/`.**
   Everything else in this repository is **read-only.** No exceptions.

2. **Never modify the DUT, even when it is obviously broken.** Not a typo fix, not a
   missing port, not a semicolon. If you find a defect, you report it (Section 7). The
   designer fixes his own RTL — that is how he learns where his mental model is wrong,
   which is the entire point of this exercise.

3. **Do not create new folders.** One request produces exactly one file:
   `tb/<ModuleName>_tb.sv`. Contract documentation lives *in the testbench header*, not
   in a separate report. Run commands live in a comment block at the *bottom of the same
   file*.

4. **Do not run `xrun`, `xmvlog`, or any simulator.** The designer runs simulations
   himself on nanoHUB. You write the file and hand him the commands.

5. **Do not silently work around a broken DUT.** If the module cannot elaborate, write
   the testbench anyway against the *intended* interface, and lead your reply with the
   list of blockers.

---

## 1. Workflow

When the designer says *"write a testbench for `<File>.sv`"*:

| Step | Action |
|---|---|
| 1 | **Investigate** the DUT and its role in the system (Section 2). |
| 2 | **Build the contract** — what the module is obligated to do (Section 3). |
| 3 | **Write** `tb/<ModuleName>_tb.sv` following the fixed anatomy (Section 4). |
| 4 | **Report** back: contract summary, invented assumptions, suspected RTL defects (Section 7). |

Never skip step 1. A testbench written from the port list alone tests the ports; a
testbench written from the port list *plus the pipeline context* tests the design.

---

## 2. Step 1 — Investigation protocol

Before writing, you must read:

- **The DUT itself**, top to bottom, including comments. The designer leaves
  decision-log comments (`// Decsion: 9/2/2026: Remove the IF/ID reg...`) that state
  architectural intent you will not find anywhere else. These are primary sources.
- **`PIPELINE_REG_STRUCT_PKG.sv`** (package `CPU_pkg`). This is the shared type
  vocabulary: `alu_op_e`, `srca_sel_e`, `srcb_sel_e`, `WB_sel_e`, `pc_sel_e`,
  `instr_name_e`, `stage_e`, and the `id_ex_t` / `ex_mem_t` pipeline register structs.
  **Drive and check using these enum names, never raw magic numbers.** A testbench full
  of `4'b1101` instead of `alu_SRA` will silently drift out of sync with the RTL the
  first time an encoding changes.
- **`CPU_TOP.sv`** — find where the DUT is instantiated. This tells you what *actually*
  drives each input and what consumes each output. A module that looks generic in
  isolation usually has exactly one caller with very specific expectations.

From that, answer these four questions explicitly in your head before writing:

1. Which pipeline stage does this module live in? (FETCH / DECODE / EX / MEM / WB)
2. Is it combinational or clocked? If clocked, how many cycles until the output is valid?
3. What does the *next* stage assume about when this module's output is stable?
4. What inputs can this module legally receive, and what is it allowed to do with the rest?

Question 3 is where pipeline bugs live. Question 4 is where architectural mistakes live.

---

## 3. Step 2 — The Contract Table

Every testbench opens with a documented contract, split into **three buckets.** Every
single check you write must be tagged with the bucket it came from. This is the most
important requirement in this document, and here is why:

> When a check fails, the bucket tells the designer *what kind* of mistake he made.
> A **FUNC** failure means the logic is wrong — the module does not do what it was meant to do.
> A **TIME** or **ASSUME** failure usually means the *specification* is wrong — the module
> was designed against a mental model that does not match the rest of the pipeline.
> The second kind is far more expensive to find later, and it is invisible without this split.

### Bucket FUNC — Functional contract

Per input class, the required output. Source this from the **RISC-V Unprivileged ISA
spec** wherever the module implements an ISA behavior, not from the RTL. Examples:

- `SRA` shifts `srcA` arithmetically by `srcB[4:0]` — the upper 27 bits of `srcB` are ignored.
- `SLTU` compares as unsigned; `SLT` compares as signed.
- `LBU` zero-extends; `LB` sign-extends.
- Register `x0` reads as zero regardless of what was written to it.

### Bucket TIME — Timing contract

When outputs are valid relative to the clock. Examples:

- Combinational: output settles within the same cycle, no clock in the sensitivity list.
- Synchronous read (BRAM-style): data appears **one cycle after** address and read-enable
  are sampled. `DMEM` and `IMEM` both work this way, and the pipeline is built around it.
- Write-during-read to the same address: does the read return old or new data?
- What happens on the *first* cycle after reset, before anything is written?

### Bucket ASSUME — Assumptions the DUT is permitted to make

Preconditions the module relies on but does not check. Examples:

- "Inputs are stable before the rising edge" (no same-edge races).
- "Word accesses are 4-byte aligned."
- "`mem_size` never takes the reserved `2'b11` encoding."
- "This module is never asked to read and write the same address in one cycle."

**If you have to invent an ASSUME line because the RTL does not make it observable,
mark it `[INVENTED]` and call it out in your reply.** An invented assumption is almost
always the fingerprint of an under-specified interface — it means two modules are
relying on an agreement that was never written down, and those are the bugs that survive
until integration.

### How the table appears in the file

```systemverilog
// ---------------------------------------------------------------------------
// CONTRACT UNDER TEST
// ---------------------------------------------------------------------------
// FUNC-1   alu_SRA performs an arithmetic right shift of srcA by srcB[4:0].
//          Bits srcB[31:5] must be ignored.            [RISC-V spec, Vol I §2.4]
// FUNC-2   alu_SLTU compares srcA and srcB as UNSIGNED and returns 32'd1 / 32'd0.
// ...
// TIME-1   result is purely combinational; it must settle with no clock edge.
// ...
// ASSUME-1 alu_func is always a value defined in CPU_pkg::alu_op_e. Undefined
//          encodings are not driven by Control_Unit_Decoder.        [INVENTED]
// ---------------------------------------------------------------------------
```

---

## 4. Step 3 — Testbench anatomy

Every file uses this section order. No deviation — uniformity is what lets the designer
read the tenth testbench as fast as the first.

```
 1. `timescale
 2. Header block     — module purpose, role in pipeline, DUT file, date
 3. CONTRACT UNDER TEST  — the three-bucket table from Section 3
 4. Parameters / localparams
 5. DUT signal declarations
 6. DUT instantiation
 7. Clock and reset generation      (omit entirely if the DUT is combinational)
 8. Stimulus tasks                  — named for intent: drive_load(), park_bus()
 9. Golden reference model          — a function/task derived from the SPEC
10. check() task                    — compares DUT vs reference, tags the bucket
11. Directed test cases             — one per contract line, in contract order
12. Constrained-random sweep        — only where the input space justifies it
13. Coverage / completeness notes
14. Summary + $finish               — exit nonzero on any failure
15. XCELIUM RUN NOTES               — commented block (Section 6)
```

### The reference model rule

The checker must be **independent of the DUT's implementation.** Write the reference
model from the specification, not by transcribing the RTL's `case` statement. If you copy
the RTL, you verify that the bug is consistent with itself — which is worth nothing.

There is one precise exception, and you should understand the distinction:

> **Encodings are interface facts. Behaviors are specification claims.**
> You *may* copy the encoding (`alu_SRA == 4'b1101`) from `CPU_pkg`, because that is a
> shared agreement, not a claim about correctness.
> You *may never* copy the behavior (`result = $signed(srcA) >>> srcB[4:0]`) from the DUT.
> Derive that from the ISA spec and write it independently.

### Style — documented, not flooded

The designer explicitly does not want commented-every-line code. The standard is:

- **Comment the *why*, never the *what*.** `// park the bus at a different address so the
  transition is a real change, not a no-op` is useful. `// set address to 0` is noise.
- **Every test case states the hypothesis it is trying to falsify.** Not "test SRA" —
  rather "confirm SRA ignores srcB[31:5]; a DUT that forgot to mask the shift amount
  passes the small-shift cases and fails only here."
- **Name tasks after intent**, not mechanics: `write_word()`, `park_bus()`, `run_case()`.
- Section banners (`// ----- Clock -----`) to make the anatomy visible at a glance.
- `tb/DMEM_tb.sv` in this repo is the reference for tone. Match it.

### Checking rules

- **Always use `===` and `!==`**, never `==`. `==` returns X when either side has an X,
  and an X compared with `==` will not reliably fail — so an uninitialized DUT output can
  slide through as a pass. `===` catches X propagation, which in this design is a very
  common real bug (see the `'X` defaults in `Control_Unit_Decoder.sv`).
- **Failure messages must be self-contained.** Bucket tag, contract ID, stimulus,
  expected, actual, time. The designer should never have to open the waveform to know
  *what* failed — only to know *why*.

```systemverilog
// Required failure message shape:
$error("[%0t] FAIL [FUNC-1] SRA: srcA=0x%08h srcB=0x%08h -> got 0x%08h, expected 0x%08h",
       $time, srcA, srcB, result, expected);
```

- Maintain `int checks` and `int errors`, print a summary, and end with
  `if (errors) $fatal(1, "...");` so the exit code is scriptable.

---

## 5. Per-module recipes

Generic advice produces generic testbenches. Match the DUT to its class.

### Pure combinational datapath
*`ALU.sv`, `Immediate_Generator.sv`, `2_To_1_MUX.sv`, `4_TO_1_MUX.sv`,
`Branch_Condition_Generator.sv`, `Jump_Branch_Address_Generator.sv`*

No clock. Drive, wait a delta (`#1`), check. Priorities:
- **Signed/unsigned boundaries** — `32'h8000_0000`, `32'h7FFF_FFFF`, `-1` vs `0xFFFFFFFF`.
  This is where `SLT` vs `SLTU` and `SRA` vs `SRL` bugs hide.
- **Shift amount masking** — shift by 0, 1, 31, 32, 33. A DUT that forgot `srcB[4:0]`
  passes every shift under 32.
- **Immediate bit-scrambling** — for `Immediate_Generator`, the RISC-V immediate encodings
  are deliberately bit-shuffled. Build the expected value by hand from the ISA spec's
  field diagrams, sign bit first, and verify the implicit trailing `1'b0` on B-type and
  J-type. Do not trust the RTL's concatenation order.
- Exhaustive sweep over the select/function input; random sweep over the data inputs.

### Control and decode
*`Control_Unit_Decoder.sv`, `PC_Decoder.sv`*

The input space is small enough to be **exhaustive — so be exhaustive.**
- Sweep **all 128 opcodes**, not just the legal ones. For each, sweep all 8 `func3` values
  and both `ir30` values. That is 2048 cases and runs instantly.
- **Illegal opcodes are a required test, not an optional one.** Check that the DUT does
  something defined and safe. The current default branch drives `'X` on every output,
  which will propagate X through the whole pipeline — decide with the designer whether
  that is intended (it is a legitimate "poison the pipeline so bugs are loud" choice) or
  an oversight, and document which in the ASSUME bucket.
- **Assert that write-enables are inactive by default.** The dangerous failure mode here
  is not a wrong ALU op — it is `RF_WE` or `memWE` accidentally asserting on an
  instruction that should not write. Give those two signals their own dedicated checks.

### Synchronous memory
*`DMEM.sv`, `IMEM.sv`, `Reg_File.sv`*

The clock relationship *is* the contract. Priorities:
- **Read latency**, checked explicitly. Assert the data is *not* yet valid in the same
  cycle, then valid in the next.
- **Write-then-immediately-read** the same address.
- **Read-during-write** to the same address in the same cycle.
- **Byte/halfword lane placement** at every byte offset, times signed and unsigned. For
  `DMEM` that is the `{mem_sign, mem_size, byteOffset}` space — sweep it fully, and
  include the combinations the RTL leaves in its `default` branch.
- **Address aliasing** — write two addresses that should be distinct and confirm they are.
  This catches address-decode arithmetic errors, which are common and quiet.
- For `Reg_File`: **`x0` is a required test.** Write a nonzero value to `x0`, read it
  back, confirm zero. Also confirm the two read ports are independent, and check the
  write-enable gating.

### Pipeline registers and staging logic
- Confirm every field propagates exactly one stage per cycle, unchanged.
- Confirm reset clears the register.
- Confirm a value entering the pipeline arrives at the far end with the correct latency
  — off-by-one-stage is the signature bug of a hand-built pipeline.

---

## 6. Xcelium run notes (nanoHUB / Cadence)

End every testbench with a commented block giving the designer the exact commands. He
runs these himself in the nanoHUB Linux terminal from inside `5_Stage_Pipeline/tb/`.

**Compile order matters:** the package must come before any module that imports it.

```systemverilog
// ---------------------------------------------------------------------------
// XCELIUM RUN NOTES  (run from 5_Stage_Pipeline/tb/ on nanoHUB)
// ---------------------------------------------------------------------------
// Single-shot compile + elaborate + run:
//
//   xrun -sv -timescale 1ns/1ps -access +rwc -l ALU_tb.log \
//        ../PIPELINE_REG_STRUCT_PKG.sv \
//        ../ALU.sv \
//        ALU_tb.sv
//
//   -sv              treat inputs as SystemVerilog
//   -access +rwc     read/write/connectivity access, required for waveform probing
//   -l <file>        tee the transcript to a log you can grep for FAIL
//   -clean           add this to force a full rebuild if a stale INCA_libs
//                    directory is giving you confusing errors
//
// Elaborate only (fastest way to check the DUT compiles at all):
//
//   xrun -sv -elaborate ../PIPELINE_REG_STRUCT_PKG.sv ../ALU.sv ALU_tb.sv
//
// Waveforms in SimVision:
//   Uncomment the $shm_open / $shm_probe block in the initial block above, rerun,
//   then:   simvision waves.shm &
//
//   Or launch interactively and drive it from the GUI:
//   xrun -sv -access +rwc -gui ../PIPELINE_REG_STRUCT_PKG.sv ../ALU.sv ALU_tb.sv
//
// Quick pass/fail check without reading the whole transcript:
//   grep -c FAIL ALU_tb.log
// ---------------------------------------------------------------------------
```

The Cadence-native waveform hooks, to include (commented out) in the initial block:

```systemverilog
// initial begin
//     $shm_open("waves.shm");
//     $shm_probe("AS");      // A = all signals, S = include sub-scopes
// end
```

Use `$shm_*` rather than `$dumpvars`/VCD — SHM is Cadence's native format and loads
directly into SimVision.

---

## 7. Step 4 — What you report back

Your reply to the designer, in this order:

1. **Blockers first, if any.** If the DUT does not elaborate, say so immediately and list
   every reason. Do not bury this under a description of the testbench.
2. **The contract table**, summarized in prose — what you decided the module owes the
   system.
3. **Invented assumptions**, flagged clearly. These are the ones most likely to reveal an
   architectural misunderstanding.
4. **Suspected RTL defects**, each with file, line, what you expected, what is there, and
   why it matters. You are not fixing these — you are handing him a list.
5. The run command.

### On reporting defects

Be specific and show your reasoning, because the designer needs to evaluate whether
*you* are wrong before he changes his RTL. Distinguish confidence levels honestly:
a missing semicolon is certain; a suspected address-decode error is a judgement call.

A worked example of the standard, from a real discrepancy in this repo:

> `DMEM.sv:31` declares `address` as `[10:0]`, but `tb/DMEM_tb.sv` was written against a
> 13-bit address and the module comment claims 8 KB. An 11-bit byte address only spans
> 2 KB, so either the port is too narrow or the comment is stale.
>
> Separately, `DMEM.sv:56` computes `wordAddress = {address[10:2], 2'b0}` and then indexes
> `memory[wordAddress]`. `address[10:2]` is already the word index; appending `2'b0`
> multiplies it by four again, so only every fourth word of the array is reachable and the
> top three quarters of memory are dead. I believe this should be `address[10:2]` alone,
> but confirm against your intended memory map before changing it.

That is the level of detail to aim for. Note that it names the file and line, states what
it expected and why, quantifies the consequence, and defers the fix to the designer.

---

## 8. Worked example — `ALU_tb.sv`

This is the reference implementation of everything above. `ALU.sv` elaborates cleanly
today, which makes it the right module to demonstrate on.

```systemverilog
`timescale 1ns/1ps
//============================================================================
// Testbench: ALU_tb
// DUT:       ../ALU.sv
// Stage:     EX
//
// Role in system:
//   The ALU is the only arithmetic element in the EX stage. Control_Unit_Decoder
//   picks alu_func in DECODE and it arrives through the ID/EX register; srcA and
//   srcB arrive from the srcA/srcB muxes. The result feeds both the EX/MEM
//   register (for writeback) and the DMEM address port (for loads and stores),
//   so an address-arithmetic error here shows up as a memory bug, not an ALU bug.
//
// Verification strategy:
//   Directed cases derived from the RISC-V Unprivileged ISA spec, one group per
//   contract line, followed by a constrained-random sweep across all operations.
//   The reference model is written from the ISA spec independently of the RTL.
//============================================================================

//----------------------------------------------------------------------------
// CONTRACT UNDER TEST
//----------------------------------------------------------------------------
// FUNC-1  alu_ADD/alu_SUB are 32-bit two's complement, wrapping on overflow.
//         RISC-V defines no overflow trap.                    [ISA Vol I §2.4]
// FUNC-2  alu_SLT compares SIGNED, alu_SLTU compares UNSIGNED. Result is
//         32'd1 or 32'd0 -- never a sign-extended -1.
// FUNC-3  Shifts (SLL/SRL/SRA) use ONLY srcB[4:0]. srcB[31:5] must be ignored.
// FUNC-4  alu_SRA is arithmetic (replicates srcA[31]); alu_SRL is logical.
// FUNC-5  alu_LUI_COPY passes srcA through unmodified. Immediate_Generator has
//         already applied the 12-bit shift, so the ALU must NOT shift again.
// FUNC-6  Bitwise AND/OR/XOR are plain 32-bit bitwise operations.
//
// TIME-1  result is purely combinational. No clock, no state, no latch: the
//         same inputs must always produce the same output.
//
// ASSUME-1 alu_func only ever carries an encoding defined in CPU_pkg::alu_op_e.
//          The RTL's default branch returns 32'b0 for anything else, which is a
//          silent value rather than an error -- an illegal op is indistinguish-
//          able from a legitimate zero result.                      [INVENTED]
// ASSUME-2 ALU.sv uses raw 4'b literals rather than importing CPU_pkg. The
//          encodings currently agree, but nothing enforces that they stay in
//          sync. This testbench drives the CPU_pkg enums deliberately, so it
//          will fail loudly if the two ever diverge.                [INVENTED]
//----------------------------------------------------------------------------

import CPU_pkg::*;

module ALU_tb;

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

    //------------------------------------------------------------------------
    // Golden reference model
    //
    // Written from the ISA spec, NOT transcribed from ALU.sv. The encodings
    // come from CPU_pkg (they are a shared interface fact); the behaviours are
    // stated independently so that a bug in the RTL cannot hide inside a
    // matching bug in the checker.
    //------------------------------------------------------------------------
    function automatic logic [31:0] alu_ref(
        input alu_op_e      op,
        input logic [31:0]  a,
        input logic [31:0]  b
    );
        logic [4:0] shamt = b[4:0];   // FUNC-3: upper bits of srcB are not shift amount

        case (op)
            alu_ADD      : return a + b;
            alu_SUB      : return a - b;
            alu_AND      : return a & b;
            alu_OR       : return a | b;
            alu_XOR      : return a ^ b;
            alu_SLL      : return a << shamt;
            alu_SRL      : return a >> shamt;
            alu_SRA      : return $signed(a) >>> shamt;
            alu_SLT      : return ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            alu_SLTU     : return (a < b)                   ? 32'd1 : 32'd0;
            alu_LUI_COPY : return a;
            default      : return 32'd0;   // see ASSUME-1
        endcase
    endfunction

    //------------------------------------------------------------------------
    // Checker. Every call carries the contract ID it is defending, so a failure
    // message tells the designer which bucket of his design is wrong.
    //------------------------------------------------------------------------
    task automatic check(
        input string        tag,      // e.g. "FUNC-3"
        input string        note,     // the hypothesis this case falsifies
        input alu_op_e      op,
        input logic [31:0]  a,
        input logic [31:0]  b
    );
        logic [31:0] expected;

        srcA     = a;
        srcB     = b;
        alu_func = op;
        #1;                            // settle the combinational cloud

        expected = alu_ref(op, a, b);
        checks++;

        // '===' not '==' : an X on result must FAIL, not evaluate to unknown
        // and slip through as a non-mismatch.
        if (result !== expected) begin
            errors++;
            $error("[%0t] FAIL [%s] %s | %s  srcA=0x%08h srcB=0x%08h -> 0x%08h, expected 0x%08h",
                   $time, tag, op.name(), note, a, b, result, expected);
        end
    endtask

    //------------------------------------------------------------------------
    // Directed cases, in contract order.
    //------------------------------------------------------------------------
    initial begin
        $display("===== ALU_tb =====");

        // FUNC-1: wrap-around is defined behaviour, not an error case.
        check("FUNC-1", "max positive + 1 must wrap to min negative",
              alu_ADD, 32'h7FFF_FFFF, 32'h0000_0001);
        check("FUNC-1", "0 - 1 must borrow to all-ones",
              alu_SUB, 32'h0000_0000, 32'h0000_0001);

        // FUNC-2: the classic signed/unsigned confusion. 0x80000000 is the most
        // negative signed value but the largest-magnitude unsigned one, so a DUT
        // that used the wrong comparison passes SLT and fails SLTU, or vice versa.
        check("FUNC-2", "signed: 0x80000000 is negative, so it is < 1",
              alu_SLT,  32'h8000_0000, 32'h0000_0001);
        check("FUNC-2", "unsigned: 0x80000000 is huge, so it is NOT < 1",
              alu_SLTU, 32'h8000_0000, 32'h0000_0001);

        // FUNC-3: a DUT that forgot to mask srcB to 5 bits passes every shift
        // under 32 and only fails here. This is the whole reason the case exists.
        check("FUNC-3", "shift by 32 must behave as shift by 0",
              alu_SLL, 32'hDEAD_BEEF, 32'd32);
        check("FUNC-3", "high bits of srcB must be ignored entirely",
              alu_SRL, 32'hDEAD_BEEF, 32'hFFFF_FFE4);   // low 5 bits = 4

        // FUNC-4: sign replication. SRL and SRA differ only on negative inputs,
        // so a positive srcA would let a swapped-opcode bug pass unnoticed.
        check("FUNC-4", "arithmetic shift must replicate the sign bit",
              alu_SRA, 32'h8000_0000, 32'd4);
        check("FUNC-4", "logical shift must fill with zeros",
              alu_SRL, 32'h8000_0000, 32'd4);

        // FUNC-5: LUI's 12-bit shift belongs to Immediate_Generator. If the ALU
        // shifts as well the immediate lands 12 bits too high and LUI silently
        // produces the wrong constant.
        check("FUNC-5", "LUI copy must not re-shift the already-shifted immediate",
              alu_LUI_COPY, 32'hABCD_E000, 32'h0000_0000);

        // FUNC-6
        check("FUNC-6", "bitwise AND across alternating patterns",
              alu_AND, 32'hAAAA_AAAA, 32'h5555_5555);
        check("FUNC-6", "XOR with itself must clear",
              alu_XOR, 32'hDEAD_BEEF, 32'hDEAD_BEEF);

        //--------------------------------------------------------------------
        // Constrained-random sweep. The directed cases above cover the corners
        // we could reason about; this covers the interior of the input space,
        // including the boundary values that random generation rarely hits on
        // its own.
        //--------------------------------------------------------------------
        begin
            alu_op_e ops [] = '{alu_ADD, alu_SUB, alu_AND, alu_OR, alu_XOR,
                                alu_SLL, alu_SRL, alu_SRA, alu_SLT, alu_SLTU,
                                alu_LUI_COPY};
            logic [31:0] corners [] = '{32'h0000_0000, 32'h0000_0001,
                                        32'h7FFF_FFFF, 32'h8000_0000,
                                        32'hFFFF_FFFF};

            foreach (ops[i]) begin
                foreach (corners[j]) foreach (corners[k])
                    check("FUNC-R", "corner x corner", ops[i], corners[j], corners[k]);

                repeat (200)
                    check("FUNC-R", "random", ops[i], $urandom(), $urandom());
            end
        end

        //--------------------------------------------------------------------
        // TIME-1: re-apply an earlier stimulus after having driven unrelated
        // values through the DUT. A combinational block returns the same answer;
        // an accidental latch (an incomplete case or a missing default) returns
        // whatever it was holding.
        //--------------------------------------------------------------------
        check("TIME-1", "no hidden state: repeat of the first ADD must match",
              alu_ADD, 32'h7FFF_FFFF, 32'h0000_0001);

        //--------------------------------------------------------------------
        $display("=========================================");
        $display(" %0d / %0d checks passed", checks - errors, checks);
        $display("=========================================");

        if (errors) $fatal(1, "ALU_tb: %0d check(s) failed", errors);
        $finish;
    end

endmodule
```

---

## 9. Scope boundary — module level only

This spec covers **module-level testbenches.** Getting the official `riscv-tests` suite
passing is a separate tier that needs a core-level harness: `.hex` program loading into
`IMEM`, a `tohost` / pass-fail convention, and a cycle-limit watchdog.

Do not build that harness unless explicitly asked. Do, however, keep module testbenches
compatible with it: use `CPU_pkg` enums, keep reference models in standalone `automatic`
functions so they can be reused by a core-level scoreboard, and keep the `$fatal(1, ...)`
exit convention so a batch runner can tell pass from fail by exit code alone.
