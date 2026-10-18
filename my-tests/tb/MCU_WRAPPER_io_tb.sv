`timescale 1ns/1ps
//============================================================================
// Testbench: MCU_WRAPPER_io_tb
// DUT:       ../rtl/MCU_WRAPPER.sv
// Stage:     board pins (not a pipeline stage)
// Date:      10/9/2026
//
// Role in system:
//   MCU_WRAPPER is the Basys3 pin surface: BTNC is core reset, BTNS and
//   SWITCHES are MMIO inputs, LEDS / CATHODES / ANODES are registered /
//   scanned outputs. This bench does not score a program. It only proves
//   the pins you will wiggle on the board actually reach the wrapper the
//   way the XDC thinks they do.
//
// Verification strategy:
//   Assert reset, release it, press two buttons, flip two switches. Check
//   the wiring the RTL itself claims (BTNC -> s_reset, clk_50 frozen in
//   reset, BTNS/SWITCHES on the Interconnect ports). LEDS stay whatever
//   the image in IMEM writes -- they are not combinational from the pins.
//============================================================================

//----------------------------------------------------------------------------
// CONTRACT UNDER TEST
//----------------------------------------------------------------------------
// FUNC-1  BTNC is wired straight to s_reset. A high BTNC must show up as
//         s_reset === 1; a low BTNC as s_reset === 0.  [MCU_WRAPPER assign]
// FUNC-2  SWITCHES is zero-extended onto Interconnect.SWITCHES[15:0].
//         A pin flip that does not appear there is a port-name / hookup
//         bug, not an MMIO decode bug.
// FUNC-3  BTNS is zero-extended onto Interconnect.BUTTONS[3:0]. Same idea.
//
// TIME-1  Wrapper CLK is 100 MHz (10 ns). The core sees clk_50, which is
//         inverted on each wrapper posedge once reset is down.
// TIME-2  While s_reset is high, clk_50 is held at 0. The divider's
//         reset arm does that so the core does not tick during BTNC.
// TIME-3  Reset is released on a wrapper negedge so the first clk_50
//         edge is a clean, full period later.                   [INVENTED]
// TIME-4  Button and switch changes are driven on a wrapper negedge so
//         they are stable before the next posedge sample.
//
// ASSUME-1 Hierarchical probes of dut.s_reset, dut.clk_50,
//          dut.Interconnect.SWITCHES, dut.Interconnect.BUTTONS are
//          legal under -access +rwc.                            [INVENTED]
// ASSUME-2 IMEM.MEM_FILE (default io_poll.mem) exists so the run
//          elaborates. This bench does not check that the program
//          paints LEDS or the seven-seg -- those writes take many
//          core cycles and depend on the image.                 [INVENTED]
// ASSUME-3 LEDS has no reset. After BTNC it may be X until the core
//          stores to 0x11000020. An X LED bus right after reset is
//          not a FUNC fail.                                     [INVENTED]
//----------------------------------------------------------------------------

module MCU_WRAPPER_io_tb;

    localparam int unsigned CLK_NS      = 10;
    localparam int unsigned RESET_CYC   = 20;
    localparam int unsigned SETTLE_CYC  = 80;

    logic        CLK;
    logic        BTNC;
    logic [3:0]  BTNS;
    logic [15:0] SWITCHES;
    logic [15:0] LEDS;
    logic [7:0]  CATHODES;
    logic [3:0]  ANODES;

    int checks = 0;
    int errors = 0;

    MCU_WRAPPER dut (
        .CLK      (CLK),
        .BTNC     (BTNC),
        .BTNS     (BTNS),
        .SWITCHES (SWITCHES),
        .LEDS     (LEDS),
        .CATHODES (CATHODES),
        .ANODES   (ANODES)
    );

    initial CLK = 1'b0;
    always #(CLK_NS/2) CLK = ~CLK;

    //------------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------------
    task automatic wait_wrapper(input int unsigned n);
        repeat (n) @(posedge CLK);
    endtask

    task automatic hold_reset();
        BTNC = 1'b1;
        wait_wrapper(RESET_CYC);
    endtask

    // Negedge release: TIME-3. The divider's next posedge then starts clk_50.
    task automatic release_reset();
        @(negedge CLK);
        BTNC = 1'b0;
        @(posedge CLK);
    endtask

    task automatic press_btn(input logic [3:0] mask);
        @(negedge CLK);
        BTNS = mask;
        @(posedge CLK);
    endtask

    task automatic flip_sw(input logic [15:0] value);
        @(negedge CLK);
        SWITCHES = value;
        @(posedge CLK);
    endtask

    //------------------------------------------------------------------------
    // Checker
    //------------------------------------------------------------------------
    task automatic check(
        input string        tag,
        input string        note,
        input logic         pass
    );
        checks++;
        if (pass !== 1'b1) begin
            errors++;
            $error("[%0t] FAIL [%s] %s | BTNC=%0b BTNS=%04b SW=0x%04h LEDS=0x%04h",
                   $time, tag, note, BTNC, BTNS, SWITCHES, LEDS);
        end
    endtask

    //------------------------------------------------------------------------
    // Directed board wiggle
    //------------------------------------------------------------------------
    initial begin
        // $shm_open("waves.shm");
        // $shm_probe("AS");

        BTNC     = 1'b1;
        BTNS     = 4'b0000;
        SWITCHES = 16'h0000;

        $display("===== MCU_WRAPPER_io_tb =====");

        hold_reset();
        check("FUNC-1", "BTNC high must be s_reset",
              dut.s_reset === 1'b1);
        check("TIME-2", "clk_50 stays 0 for the whole reset pulse",
              dut.clk_50 === 1'b0);

        release_reset();
        check("FUNC-1", "BTNC low must drop s_reset",
              dut.s_reset === 1'b0);

        begin
            logic saw_clk50_high;
            saw_clk50_high = 1'b0;
            repeat (4) begin
                @(posedge CLK);
                if (dut.clk_50 === 1'b1) saw_clk50_high = 1'b1;
            end
            check("TIME-1", "clk_50 must go high at least once after reset",
                  saw_clk50_high === 1'b1);
        end

        // Two buttons, one at a time, so a stuck-together OR is visible.
        press_btn(4'b0001);
        check("FUNC-3", "BTNS[0] must reach Interconnect.BUTTONS[0]",
              dut.Interconnect.BUTTONS[3:0] === 4'b0001);

        press_btn(4'b0010);
        check("FUNC-3", "BTNS[1] must reach Interconnect.BUTTONS[1]",
              dut.Interconnect.BUTTONS[3:0] === 4'b0010);

        press_btn(4'b0000);

        flip_sw(16'h0001);
        check("FUNC-2", "SWITCHES[0] must reach Interconnect",
              dut.Interconnect.SWITCHES[15:0] === 16'h0001);

        flip_sw(16'h0009);
        check("FUNC-2", "SWITCHES[0] and [3] must both stick",
              dut.Interconnect.SWITCHES[15:0] === 16'h0009);

        wait_wrapper(SETTLE_CYC);
        $display("[%0t] NOTE [ASSUME-3] after settle LEDS=0x%04h CATHODES=0x%02h ANODES=0b%04b -- LEDS is X until the core stores 0x11000020",
                 $time, LEDS, CATHODES, ANODES);

        $display("=========================================");
        $display(" %0d / %0d checks passed", checks - errors, checks);
        $display("=========================================");

        if (errors) $fatal(1, "MCU_WRAPPER_io_tb: %0d check(s) failed", errors);
        $finish;
    end

endmodule

// ---------------------------------------------------------------------------
// XCELIUM RUN NOTES  (run from the repo root)
// ---------------------------------------------------------------------------
// scripts/MCU_list.f still names the old files (PIPELINE_REG_STRUCT_PKG,
// 2_To_1_MUX, BCDMod, ...). Until that list is updated, pass the RTL
// explicitly. io_poll.mem must sit in the launch directory (or retarget
// IMEM.MEM_FILE).
//
//   xrun -sv -timescale 1ns/1ps -access +rwc -l MCU_WRAPPER_io_tb.log \
//        rtl/CPU_pkg.sv \
//        rtl/TWO_TO_ONE_MUX.sv \
//        rtl/FOUR_TO_ONE_MUX.sv \
//        rtl/ALU.sv \
//        rtl/Branch_Condition_Generator.sv \
//        rtl/Program_Counter.sv \
//        rtl/IMEM.sv \
//        rtl/REG_FILE.sv \
//        rtl/Control_Unit_Decoder.sv \
//        rtl/Immediate_Generator.sv \
//        rtl/PC_Decoder.sv \
//        rtl/Jump_Branch_Address_Generator.sv \
//        rtl/Forwarding_Unit.sv \
//        rtl/HazardUnit.sv \
//        rtl/CPU_TOP.sv \
//        rtl/DMEM.sv \
//        rtl/Interconnect.sv \
//        rtl/BCD.sv \
//        rtl/CathodeDriver.sv \
//        rtl/SevSegDisp.sv \
//        rtl/MCU_WRAPPER.sv \
//        tb/MCU_WRAPPER_io_tb.sv \
//        -defparam MCU_WRAPPER_io_tb.dut.CPU_TOP.IMEM.MEM_FILE=\"sw/io_poll.mem\"
//
// Elaborate only:
//   xrun -sv -elaborate -timescale 1ns/1ps <same file list>
//
// Waves:
//   uncomment $shm_open / $shm_probe above, or add -gui
//   Probe: BTNC, BTNS, SWITCHES, LEDS, dut.s_reset, dut.clk_50,
//          dut.Interconnect.SWITCHES, dut.Interconnect.BUTTONS,
//          dut.CPU_TOP.DATA_ADDRESS, dut.CPU_TOP.IOBUS_RDEN
//
//   grep -c FAIL MCU_WRAPPER_io_tb.log
// ---------------------------------------------------------------------------
