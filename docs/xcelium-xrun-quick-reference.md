# Xcelium `xrun` Quick Reference

For SystemVerilog RTL and CPU simulation on nanoHUB.

## 1. Check that Xcelium is available

```bash
which xrun
xrun -version
xrun -help
```

If `xrun` is not found, launch the nanoHUB Xcelium/Cadence environment or use the setup command supplied by your course or nanoHUB tool page.

## 2. Smallest useful commands

Compile, elaborate, and simulate SystemVerilog:

```bash
xrun -sv rtl/alu.sv tb/alu_tb.sv
```

Specify the top-level testbench and save the log:

```bash
xrun -64bit -sv rtl/alu.sv tb/alu_tb.sv \
  -top alu_tb -timescale 1ns/1ps -l xrun.log
```

Recommended command for a project:

```bash
xrun -64bit -sv -f filelist.f \
  -top cpu_tb \
  -timescale 1ns/1ps \
  -access +rwc \
  -l xrun.log
```

Clean Xcelium's generated working data before rebuilding:

```bash
xrun -clean
```

## 3. Flags you will use most

| Option | Meaning |
| --- | --- |
| `-sv` | Treat appropriate input files as SystemVerilog. Keep the `.sv` extension too. |
| `-f filelist.f` | Read source paths and options from a file list. |
| `-top cpu_tb` | Select the top-level module. Usually this is the testbench, not the DUT. |
| `-timescale 1ns/1ps` | Default simulation time unit and precision when a source omits them. |
| `-64bit` | Run the 64-bit simulator. |
| `-access +r` | Preserve signal read access for debugging. |
| `-access +rw` | Preserve read/write access. |
| `-access +rwc` | Preserve read, write, and connectivity access; useful for full debugging and waveforms but may slow simulation. |
| `-l xrun.log` | Write messages to the named log file. |
| `-input waves.tcl` | Execute simulator Tcl commands, often for waveform recording. |
| `-gui` | Start the graphical debugger when the nanoHUB session supports a GUI. |
| `-clean` | Remove Xcelium's generated work area so the next build is fresh. |
| `-define NAME` | Define a SystemVerilog preprocessor symbol. `+define+NAME` is also common. |
| `-define NAME=VALUE` | Define a symbol with a value. |
| `-incdir path` | Add an include directory. `+incdir+path` is also common. |
| `-svseed 1234` | Set the SystemVerilog random seed for a repeatable randomized test. |
| `-svseed random` | Select a new random seed. Record the reported seed if a test fails. |

When unsure about an installed-version option:

```bash
xrun -help | less
xrun -help | grep -i timescale
```

## 4. File-list template

Create `filelist.f` in the project root:

```text
-sv
+incdir+./rtl
+incdir+./tb

# Packages must appear before files that import them.
./rtl/cpu_pkg.sv

# Design files
./rtl/alu.sv
./rtl/register_file.sv
./rtl/control_unit.sv
./rtl/imem.sv
./rtl/dmem.sv
./rtl/cpu.sv

# Testbench last
./tb/cpu_tb.sv
```

Important file-list rules:

- Run `xrun` from the directory against which these relative paths are written.
- Put packages before modules that import them.
- Put interfaces before modules that use them.
- Put the testbench after the RTL.
- List header files such as `.svh` through an include directory; normally do not compile them as separate source files.
- A line beginning with `#` is a comment.

## 5. Record waveforms in batch mode

Create `waves.tcl`:

```tcl
database -open waves -into waves.shm -default
probe -create -all -depth all
run
exit
```

Run the simulation:

```bash
xrun -64bit -sv -f filelist.f \
  -top cpu_tb -timescale 1ns/1ps \
  -access +rwc -input waves.tcl -l xrun.log
```

If SimVision is available in the graphical nanoHUB session:

```bash
simvision waves.shm &
```

For a quick interactive GUI run:

```bash
xrun -64bit -sv -f filelist.f \
  -top cpu_tb -timescale 1ns/1ps \
  -access +rwc -gui -l xrun.log
```

If GUI access is unreliable, prefer batch simulation, save `waves.shm`, and inspect the log first.

## 6. Passing compile-time and run-time values

Compile only selected debug code:

```systemverilog
`ifdef CPU_DEBUG
  $display("PC=%08h instruction=%08h", pc, instruction);
`endif
```

Enable it at compile time:

```bash
xrun -sv -f filelist.f -top cpu_tb -define CPU_DEBUG
```

Pass a run-time plusarg:

```bash
xrun -sv -f filelist.f -top cpu_tb +PROGRAM=tests/add.hex
```

Read it in the testbench:

```systemverilog
string program_file;

initial begin
  if (!$value$plusargs("PROGRAM=%s", program_file)) begin
    program_file = "tests/default.hex";
  end
  $readmemh(program_file, dut.imem.mem);
end
```

Do not confuse the two:

- `-define CPU_DEBUG` changes what is compiled.
- `+PROGRAM=file.hex` passes a value to the running testbench.

## 7. A self-checking testbench pattern

```systemverilog
`timescale 1ns/1ps

module cpu_tb;
  logic clk = 1'b0;
  logic rst = 1'b1;

  always #5 clk = ~clk;

  cpu dut (
    .clk (clk),
    .rst (rst)
  );

  initial begin
    repeat (5) @(posedge clk);
    rst <= 1'b0;

    repeat (100) @(posedge clk);

    if (dut.register_file.registers[5] !== 32'd12)
      $fatal(1, "FAIL: x5=%h, expected 0000000c",
             dut.register_file.registers[5]);

    $display("PASS");
    $finish;
  end

  initial begin
    #100_000;
    $fatal(1, "TIMEOUT: simulation did not finish");
  end
endmodule
```

Use `===`/`!==` in checks when an `X` or `Z` must cause failure. Always include `$finish` and a timeout so a batch job cannot run forever.

## 8. A simple Makefile

Recipe lines under `run`, `gui`, and `clean` must begin with a real tab.

```make
XRUN := xrun
TOP  := cpu_tb
COMMON := -64bit -sv -f filelist.f -top $(TOP) -timescale 1ns/1ps

.PHONY: run waves gui clean

run:
	$(XRUN) $(COMMON) -l xrun.log

waves:
	$(XRUN) $(COMMON) -access +rwc -input waves.tcl -l xrun.log

gui:
	$(XRUN) $(COMMON) -access +rwc -gui -l xrun.log

clean:
	$(XRUN) -clean
```

Then use:

```bash
make run
make waves
make gui
make clean
```

## 9. How to read failures

Xcelium normally performs three stages:

1. **Compile**: checks syntax and compiles modules/packages.
2. **Elaborate**: builds the hierarchy and resolves ports, parameters, widths, and top modules.
3. **Simulate**: runs clocks, testbench stimulus, assertions, and checks.

Useful log search:

```bash
grep -nE '\*E,|\*F,|Error|Fatal|FAIL|TIMEOUT' xrun.log
```

Common problems:

| Symptom | Likely fix |
| --- | --- |
| `xrun: command not found` | Start the correct nanoHUB Cadence/Xcelium environment or load its setup. |
| Package not found | Put the package earlier in `filelist.f`. |
| Include file not found | Add `+incdir+path` and check filename capitalization. |
| Multiple or wrong top modules | Pass `-top cpu_tb`. |
| Timescale error/warning | Add `` `timescale 1ns/1ps`` or pass `-timescale 1ns/1ps`. |
| Signals optimized away | Rerun with `-access +rwc`. |
| Simulation never ends | Add `$finish` and a timeout block. |
| Lots of `X` values | Check reset, uninitialized memories/registers, multiple drivers, and incomplete combinational assignments. |
| Old/stale behavior after edits | Run `xrun -clean`, then simulate again. |

## 10. CPU-project checklist

Before trusting a CPU test:

- Reset every architectural state element intentionally.
- Initialize instruction/data memory explicitly.
- Check that register `x0` always remains zero.
- Use byte addresses consistently; convert to local word indexes deliberately.
- Check unsupported misaligned accesses and illegal instructions.
- Make the testbench report `PASS` or terminate with `$fatal`.
- Keep test programs and expected results under version control.
- Save the exact random seed for randomized failures.
- Commit source, testbench, file lists, Tcl scripts, and Makefiles; do not commit generated `xcelium.d/`, logs, or waveform databases unless required.

Suggested `.gitignore` entries:

```gitignore
xcelium.d/
*.log
*.history
*.key
*.shm/
```

## 11. The command to remember

```bash
xrun -64bit -sv -f filelist.f \
  -top cpu_tb -timescale 1ns/1ps \
  -access +rwc -input waves.tcl -l xrun.log
```

Start simpler when debugging: remove `-input waves.tcl` and change `-access +rwc` to `-access +r` if you do not need full waveform/debug access.
