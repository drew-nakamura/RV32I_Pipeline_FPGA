`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Company: Cal Poly
// Engineer: Paul Hummel
//
// Create Date: 06/29/2018 12:58:25 AM
// Module Name: SevSegDisp
// Target Devices: Basys3 - 4 digit 7 segment, common anode, common cathode
// Description: Display driver for a 4 digit 7 segment with common anode and
//              common cathode. The 16-bit input can be displayed as decimal or
//              hex value using the mode input, 0 for hex, 1 for decimal.
//              In decimal mode, the full 16-bit range of values cannot be
//              displayed due to the output being limited to 4 digits. Decimal
//              values over 4 digits are truncated, 12345 is displayed as 2345
//
// Revision:
// Revision 0.01 - File Created
////////////////////////////////////////////////////////////////////////////////


module SevSegDisp(
    input logic CLK,            // 100 MHz
    input logic MODE,           // 0 - Hex, 1 - Decimal
    input logic s_reset,
    input logic [15:0] DATA_IN,
    output logic [7:0] CATHODES,
    output logic [3:0] ANODES
    );

    logic [15:0] BCD_Val;
    logic [15:0] Hex_Val;
    
    // decimal values are converted to binary code decimal for displaying
    BCD BCDMod (
        .HEX(DATA_IN),
        .THOUSANDS(BCD_Val[15:12]),
        .HUNDREDS(BCD_Val[11:8]),
        .TENS(BCD_Val[7:4]),
        .ONES(BCD_Val[3:0])
    );
    
    // Cathode driver displays all values as 4-bit hex
    CathodeDriver CathMod (
        .HEX(Hex_Val),
        .CLK(CLK),
        .s_reset(s_reset),
        .CATHODES(CATHODES),
        .ANODES(ANODES)
    );
    
    // MUX to switch between HEX and BCD input for Hex and Decimal display
    always_comb begin
        if (MODE == 1'b1)
            Hex_Val = BCD_Val;
        else
            Hex_Val = DATA_IN;
    end
    
    
endmodule
