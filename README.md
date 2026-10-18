# RV32I Pipeline FPGA

A 5-stage pipelined RV32I processor that runs on a Basys 3. It implements 37 of the 40 base integer instructions, with hazard detection and forwarding, and was originally built as a CPE 333 class project at Cal Poly.

The CPU clock is 50 MHz, divided down from the board’s 100 MHz oscillator. Instruction memory and data memory are both synchronous: every read and every write happens on the clock edge, and the pipeline inserts no extra wait states for memory.

## What it does

- **ISA:** 37 of 40 RV32I instructions. The three left out are `FENCE`, `ECALL`, and `EBREAK`.
- **Pipeline:** fetch, decode, execute, memory, writeback.
- **Hazards:** the forwarding unit resolves RAW hazards in execute by taking a result from memory or writeback. A load that the next instruction needs stalls the pipe for one cycle. Taken branches, `jal`, and `jalr` flush the instructions already fetched behind them.
- **Board:** Basys 3. Switches, buttons, LEDs, and the four-digit seven-segment display sit on a memory-mapped I/O bus.
- **Author:** Drew Nakamura. See Credits for the two pieces that came from elsewhere.

## Diagrams

These are reference drawings of the CPU and the MCU wrapper. A wire in the drawing may not match the RTL one-for-one.

### CPU

![Pipelined CPU block diagram](docs/images/CPU_diagram.jpg)

### MCU

![MCU block diagram](docs/images/MCU_diagram.jpeg)

## Memory map

| Address | What it is |
| --- | --- |
| `0x11000000` | Switches (read) |
| `0x11000020` | LEDs (write) |
| `0x11000040` | Seven-segment display (write) |
| `0x11000080` | Buttons (read) |
| `0x00003F60` and up | Data memory. The word index is `(address - 0x3F60) >> 2`. |

Instruction memory is inside the CPU and is read by the program counter. Addresses below the data-memory base do nothing on the data bus.

Loads and stores are byte, halfword, or word. Loads are sign-extended or zero-extended from the registered word.

## Verification & Testing (`riscv-tests`)

**Status (as of 10/17/2026):** **27 / 37** `riscv-tests` instructions passing.

I am currently testing the 37 implemented RV32I instructions against the official `riscv-tests` (`rv32ui`) repository using Cadence Xcelium (`xrun`) and the core testbench (`my-tests/tb/riscv_test_CPU_TOP_tb.sv`). 

Each test is compiled bare-metal and split into separate instruction (`imem.mem` at `0x0000_0000`) and data (`dmem.mem` starting at `0x0000_3F60`) memory images to match the processor's Harvard architecture. The testbench monitors stores to the `tohost` mailbox address (`0x0000_3F80`), where writing `1` indicates a pass and `(test_case << 1) | 1` indicates the failing test case number.

What makes the remaining failures especially interesting is that the CPU already passes all of my custom self-tests, large programs, and the full test suites provided in my classes. I have not yet completely verified the root cause of the 10 failing `riscv-tests` programs—it may be due to continued memory/section alignment issues when splitting the `riscv-tests` binaries into separate IMEM and DMEM images, or corner-case pipeline interactions exposed by the suite's macros. More testing and debugging are underway.

### Running the test suite (Cadence Xcelium)

```bash
make -C riscv-tests        # build .imem.mem and .dmem.mem images for all 37 tests
make                       # run all 37 tests in Xcelium xrun and print the score
make TEST=addi             # run a single instruction test
make gui TEST=addi         # open a single test in SimVision
```

## Layout

| Path | Contents |
| --- | --- |
| `rtl/` | CPU, memories, forwarding, hazard unit, and the Basys 3 wrapper |
| `riscv-tests/` | Official RV32I (`rv32ui`) test suite adapted for split IMEM/DMEM |
| `my-tests/` | Core/module testbenches (`tb/`) and custom software tests (`sw/`) |
| `docs/` | Diagrams |

`MCU_WRAPPER` is the FPGA top. It divides the board clock to 50 MHz, holds the CPU, data memory, the I/O interconnect, and the display.

## Credits

All of the processor RTL is by Drew Nakamura, except the two items below.

**Seven-segment display.** `SevSegDisp`, `BCD`, and `CathodeDriver` were written by Paul Hummel at Cal Poly. They drive the Basys 3’s four-digit display in hex or decimal. They are used here as written.

**Data memory.** `DMEM` follows the Cal Poly memory module primarily written by J. Callenes and P. Hummel. This copy keeps that structure and differs in only a few places, so it matches this pipeline’s address base and its byte, halfword, and word accesses.
