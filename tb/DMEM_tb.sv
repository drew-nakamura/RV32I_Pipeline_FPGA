`timescale 1ns/1ps

module DMEM_tb;

    // ------------------------------------------------------------------
    // Parameters
    // ------------------------------------------------------------------
    localparam ADDR_WIDTH = 13;
    localparam CLK_PERIOD = 10;                      // 100 MHz
    localparam [ADDR_WIDTH-1:0] TEST_ADDR = 13'h100;  // byte addr, word-aligned (0x100 = 256)
    localparam [31:0]           TEST_DATA = 32'hDEADBEEF;
    localparam NUM_WORDS  = (1 << ADDR_WIDTH) / 4;    // 2048 words in an 8KB, 13-bit byte space

    // ------------------------------------------------------------------
    // DUT signals
    // ------------------------------------------------------------------
    logic                  CLK;
    logic                  WE;
    logic                  RDEN;
    logic [ADDR_WIDTH-1:0] address;
    logic [31:0]           data_in;
    logic [31:0]           data_out;

    int errors = 0;
    int tests  = 0;

    DMEM dut (
        .CLK      (CLK),
        .WE       (WE),
        .RDEN     (RDEN),
        .address  (address),
        .data_in  (data_in),
        .data_out (data_out)
    );

    // ------------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------------
    initial CLK = 1'b0;
    always #(CLK_PERIOD/2) CLK = ~CLK;

    // ------------------------------------------------------------------
    // Clean synchronous write helper (address/data always set up well
    // ahead of the edge -- this is the "known good" way to drive a write)
    // ------------------------------------------------------------------
    task automatic write_word(input logic [ADDR_WIDTH-1:0] addr, input logic [31:0] data);
        @(negedge CLK);
        address = addr;
        data_in = data;
        WE      = 1'b1;
        RDEN    = 1'b0;
        @(posedge CLK);
        @(negedge CLK);
        WE      = 1'b0;
    endtask

    // ------------------------------------------------------------------
    // Zero every word, then drop TEST_DATA at TEST_ADDR, so the "rest of
    // memory is 0" assumption doesn't depend on how your DUT resets.
    // Comment this loop out if your memory is much bigger / already
    // self-initializes to 0.
    // ------------------------------------------------------------------
    task automatic preload_memory();
        int i;
        $display("[%0t] Zeroing %0d words, then writing 0x%08h @ addr 0x%0h",
                   $time, NUM_WORDS, TEST_DATA, TEST_ADDR);
        for (i = 0; i < NUM_WORDS; i++)
            write_word(i * 4, 32'h0000_0000);
        write_word(TEST_ADDR, TEST_DATA);
    endtask

    // ------------------------------------------------------------------
    // The actual experiment.
    //
    //   addr_early / rden_early = 1  -> signal is set at the PRECEDING
    //                                   negedge, so it's stable a full
    //                                   half period before the sampling
    //                                   (rising) edge -- the "ready
    //                                   before the clock" case.
    //
    //   addr_early / rden_early = 0  -> signal is set with a blocking
    //                                   assignment at the exact same
    //                                   posedge that DMEM uses to sample
    //                                   -- the "sent at the clock edge"
    //                                   case. NOTE: this is a genuine
    //                                   simulation race (the SystemVerilog
    //                                   LRM does not define the order in
    //                                   which processes triggered by the
    //                                   same edge execute), so the result
    //                                   can legally differ between
    //                                   simulators, or even between runs
    //                                   if you reorder always blocks.
    //                                   That unpredictability IS the
    //                                   point of this test case.
    //
    // Before every case we first park the address at a different value
    // so the transition to TEST_ADDR is a real change, not a no-op.
    // ------------------------------------------------------------------
    task automatic run_case(
        input string name,
        input bit    addr_early,
        input bit    rden_early
    );
        logic [ADDR_WIDTH-1:0] park_addr;
        logic [31:0]           observed;

        park_addr = TEST_ADDR ^ 13'h0FF0;   // guaranteed different address

        @(negedge CLK);
        address = park_addr;
        RDEN    = 1'b0;
        WE      = 1'b0;

        if (addr_early)
            @(negedge CLK);      // let this settle a half period ahead
        else
            @(posedge CLK);      // fall through to right at the edge below

        if (addr_early && rden_early) begin
            address = TEST_ADDR;
            RDEN    = 1'b1;
            @(posedge CLK);
        end
        else if (addr_early && !rden_early) begin
            address = TEST_ADDR;
            @(posedge CLK);
            RDEN = 1'b1;          // RDEN arrives after the sampling edge
        end
        else if (!addr_early && rden_early) begin
            RDEN    = 1'b1;
            address = TEST_ADDR;  // address arrives right at the edge
        end
        else begin
            address = TEST_ADDR;  // both arrive right at the edge
            RDEN    = 1'b1;
        end

        @(negedge CLK);           // give the registered output time to update
        observed = data_out;
        tests++;

        if (observed === TEST_DATA)
            $display("[%0t] PASS  %-28s addr_early=%0b rden_early=%0b -> data_out=0x%08h",
                       $time, name, addr_early, rden_early, observed);
        else begin
            $display("[%0t] FAIL  %-28s addr_early=%0b rden_early=%0b -> data_out=0x%08h (expected 0x%08h)",
                       $time, name, addr_early, rden_early, observed, TEST_DATA);
            errors++;
        end

        RDEN = 1'b0;
    endtask

    // ------------------------------------------------------------------
    // Plain, cleanly-timed read used only to confirm "everywhere else is
    // 0" -- not part of the address/RDEN race experiment itself.
    // ------------------------------------------------------------------
    task automatic check_zero(input logic [ADDR_WIDTH-1:0] addr);
        @(negedge CLK);
        address = addr;
        RDEN    = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        RDEN    = 1'b0;
        tests++;
        if (data_out === 32'h0000_0000)
            $display("[%0t] PASS  addr 0x%0h reads back 0 as expected", $time, addr);
        else begin
            $display("[%0t] FAIL  addr 0x%0h -> 0x%08h (expected 0)", $time, addr, data_out);
            errors++;
        end
    endtask

    // ------------------------------------------------------------------
    initial begin
        WE      = 1'b0;
        RDEN    = 1'b0;
        address = '0;
        data_in = '0;

        preload_memory();

        $display("\n----- sanity: everywhere but TEST_ADDR is 0 -----");
        check_zero(13'h0000);
        check_zero(13'h0004);
        check_zero(TEST_ADDR ^ 13'h0FF0);   // same "parking" address used below

        $display("\n----- address / RDEN timing sweep -----");
        run_case("addr early, RDEN early",   1, 1);
        run_case("addr early, RDEN at edge", 1, 0);
        run_case("addr at edge, RDEN early", 0, 1);
        run_case("addr at edge, RDEN at edge", 0, 0);

        $display("\n=====================================================");
        $display(" %0d / %0d checks passed", tests - errors, tests);
        $display("=====================================================");

        $finish;
    end

endmodule