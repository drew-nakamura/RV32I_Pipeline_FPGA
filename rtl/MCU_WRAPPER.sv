`timescale 1ns / 1ps
/////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: J. Calllenes
//           P. Hummel
//           Additions made by: Drew Nakamura
//
// Create Date: 01/20/2019 10:36:50 AM
// Module Name: OTTER_Wrapper
// Target Devices: OTTER MCU on Basys3
// Description: OTTER_WRAPPER with Switches, LEDs, and 7-segment display
//
// Revision:
// Revision 0.01 - File Created
// Revision 0.02 - Updated MMIO Addresses, signal names
// 
// Drew's Addtion:
// Removing IOBUS inout output, creating an interconnect module to
// connect the SEV_SEG, LEDS, and Inputs from the memory mapped I/O.
/////////////////////////////////////////////////////////////////////////////


module MCU_WRAPPER(
   input logic CLK,
   input logic BTNC,
   input logic BTNC2,
   input logic[15:0] SWITCHES,
   output logic [15:0] LEDS,
   output logic [7:0] CATHODES,
   output logic [3:0] ANODES
   );
       
    // INPUT PORT IDS BASED ON MMIO//////////////////////////////////////////////
    localparam SWITCHES_AD = 32'h11000000;
    localparam LEDS_AD    = 32'h11000020; //32'h11000020
    localparam SSEG_AD    = 32'h11000040; //32'h11000040
    localparam BUTTON_AD  = 32'h11000080; //32'h11000080
    
   // Signals for connecting OTTER_MCU to OTTER_wrapper /////////////////////
    logic clk_50 = 0;
    logic [2:0] mem_data;
    logic [31:0] IOBUS_out, IOBUS_in, IOBUS_addr;
    logic s_reset, IOBUS_RDEN, IOBUS_WE, Board_WE;
   
   // Registers for buffering outputs  /////////////////////////////////////
   logic [15:0] r_SSEG;
    //=====DMEM WIRES======
    logic DMEM_RDEN, DMEM_WE;
    logic [31:0] DMEM_DATA;
    //====BOARD WIRES=====
    logic SSEG_WE, LEDS_WE;

   CPU_TOP CPU_TOP(
        .RST(s_reset),
        .CLK(clk_50),
        .DATA_IN(IOBUS_in),
        .mem_data(mem_data),
        .DATA_ADDRESS(IOBUS_addr),
        .DATA_OUT(IOBUS_out),
        .IOBUS_RDEN(IOBUS_RDEN),
        .IOBUS_WE(IOBUS_WE)
    );

   Interconnect Interconnect(
        .address(IOBUS_addr),
        .WE(IOBUS_WE),
        .CPU_DATA(IOBUS_out),
        .RDEN(IOBUS_RDEN),
        .DMEM_DATA(DMEM_DATA),
        .SWITCHES({16'b0,SWITCHES}),
        .BUTTONS({31'b0, BTNC2}),
        .DMEM_RDEN(DMEM_RDEN),
        .DMEM_WE(DMEM_WE),
        .LEDS_WE(LEDS_WE),
        .SSEG_WE(SSEG_WE),
        .IOBUS_in(IOBUS_in)
   );

   DMEM DATA_MEMORY(
        .CLK(CLK),
        .WE(DMEM_WE),
        .RDEN(DMEM_RDEN),
        .address(IOBUS_addr),
        .data_in(IOBUS_out),
        .mem_data(mem_data), //Meta data for half, byte, and word
        .data_out(DMEM_DATA)
    );

   // Declare Seven Segment Display /////////////////////////////////////////
   SevSegDisp SSG_DISP (
       .DATA_IN(r_SSEG),
       .CLK(CLK),
       .MODE(1'b0),
       .CATHODES(CATHODES),
       .ANODES(ANODES)
   );
                            
   // Clock Divider to create 50 MHz Clock //////////////////////////////////
   always_ff @(posedge CLK) begin
       clk_50 <= ~clk_50;
   end
   
   // Connect Signals ///////////////////////////////////////////////////////
   assign s_reset = BTNC;

   endmodule
