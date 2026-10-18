`timescale 1ns/1ps
//============================================================================
// Testbench: riscv_test_CPU_TOP_tb
// DUT:       CPU_TOP, plus the data path the riscv-tests images use
//            (Interconnect + DMEM).
//
// The program under test is a riscv-tests RV32I image.
//   imem word 0 is address 0.
//   dmem word 0 is address 0x3F60. tohost is 0x3F80.
// Pass is a store of 1 to tohost. Fail is a store of (test_number << 1) | 1.
// halt_sig is the core's trap freeze. These programs exit with a normal
// store and a spin, so a pass does not require halt_sig.
//
// Module names cannot contain '-'. The file name is the readable form of
// riscv-test-CPU_TOP.
//
// The makefile passes each test's hex file with xrun -defparam.
// A defparam in this file overrides that switch on Xcelium, so there is
// none here. Without the switch, IMEM and DMEM open their own defaults.
//============================================================================

module riscv_test_CPU_TOP_tb;

    localparam int unsigned CLK_PERIOD  = 20;
    localparam int unsigned RESET_CYCLES = 8;
    localparam int unsigned WATCHDOG    = 200000;
    localparam logic [31:0] TOHOST_ADDR = 32'h0000_3F80;

    logic        RST;
    logic        CLK;
    logic [31:0] DATA_IN;
    logic [2:0]  mem_data;
    logic [31:0] DATA_ADDRESS;
    logic [31:0] DATA_OUT;
    logic        IOBUS_RDEN;
    logic        IOBUS_WE;
    logic        halt_sig;
    logic        DMEM_RDEN;
    logic        DMEM_WE;
    logic [31:0] DMEM_DATA;

    int unsigned cycle_i;
    bit          tohost_seen;
    bit          halt_seen;
    bit          timed_out;
    logic [31:0] tohost_data;

    CPU_TOP dut (
        .RST          (RST),
        .CLK          (CLK),
        .DATA_IN      (DATA_IN),
        .mem_data     (mem_data),
        .DATA_ADDRESS (DATA_ADDRESS),
        .DATA_OUT     (DATA_OUT),
        .IOBUS_RDEN   (IOBUS_RDEN),
        .IOBUS_WE     (IOBUS_WE),
        .halt_sig     (halt_sig)
    );

    // Addresses >= 0x3F60 reach DMEM. Switches and buttons are unused.
    Interconnect io_bus (
        .address   (DATA_ADDRESS),
        .WE        (IOBUS_WE),
        .RDEN      (IOBUS_RDEN),
        .DMEM_DATA (DMEM_DATA),
        .SWITCHES  (32'b0),
        .BUTTONS   (32'b0),
        .DMEM_RDEN (DMEM_RDEN),
        .DMEM_WE   (DMEM_WE),
        .LEDS_WE   (),
        .SSEG_WE   (),
        .IOBUS_in  (DATA_IN)
    );

    DMEM data_memory (
        .CLK      (CLK),
        .WE       (DMEM_WE),
        .RDEN     (DMEM_RDEN),
        .address  (DATA_ADDRESS),
        .data_in  (DATA_OUT),
        .mem_data (mem_data),
        .data_out (DMEM_DATA)
    );

    initial CLK = 1'b0;
    always #(CLK_PERIOD/2) CLK = ~CLK;

    initial begin
        int unsigned i;
        tohost_seen = 1'b0;
        halt_seen   = 1'b0;
        timed_out   = 1'b0;
        cycle_i     = 0;
        RST         = 1'b1;

        $display("===== riscv_test_CPU_TOP_tb =====");
        $display("IMEM file = %s", dut.IMEM.MEM_FILE);
        $display("DMEM file = %s", data_memory.MEM_FILE);

        for (i = 0; i < RESET_CYCLES; i++)
            @(posedge CLK);
        @(negedge CLK);
        RST = 1'b0;
        $display("[%0t] RST released; halt_sig=%b", $time, halt_sig);

        while (!tohost_seen && !halt_seen && !timed_out) begin
            @(posedge CLK);
            #1;

            if ((halt_sig === 1'b1) && !halt_seen) begin
                halt_seen = 1'b1;
                $display("[%0t] halt_sig rose at cycle %0d  PC=0x%08h",
                         $time, cycle_i, dut.PC);
            end

            if ((IOBUS_WE === 1'b1) && (DATA_ADDRESS === TOHOST_ADDR)) begin
                tohost_seen = 1'b1;
                tohost_data = DATA_OUT;
                $display("[%0t] tohost store = 0x%08h", $time, tohost_data);
            end

            cycle_i++;
            if (cycle_i >= WATCHDOG)
                timed_out = 1'b1;
        end

        if (tohost_seen && (tohost_data === 32'h1)) begin
            $display("RISCV-TEST PASS");
            $finish;
        end
        else if (tohost_seen && (tohost_data[0] === 1'b1)) begin
            $fatal(1, "RISCV-TEST FAIL: case %0d  tohost=0x%08h",
                   tohost_data[31:1], tohost_data);
        end
        else if (halt_seen) begin
            $fatal(1, "RISCV-TEST FAIL: halt_sig with no tohost store. A trap froze the pipe before the mailbox write.");
        end
        else begin
            $fatal(1, "RISCV-TEST FAIL: no tohost store after %0d cycles. PC=0x%08h halt_sig=%b",
                   cycle_i, dut.PC, halt_sig);
        end
    end

endmodule

// ---------------------------------------------------------------------------
// Cadence: from the repo root, `make` or `make gui`.
// ---------------------------------------------------------------------------
