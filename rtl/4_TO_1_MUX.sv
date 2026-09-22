`timescale 1ns / 1ps
//============================================================
// Module: Four To One Mux
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   Takes in 4 32 bit values and a single 2 bit vlaue. Uses
//   the 2 bit value to determine whihc of the 4 32 bit values
//   is output.
//
// Notes:
//   - Educational use only
//   - Not an original architecture design
//============================================================
//FOUR_TO_ONE_MUX(
//    .A(),
//    .B(),
//    .C(),
//    .D(),
//    .SEL(),
//    .OUT()
//    );

module FOUR_TO_ONE_MUX(
    input logic [31:0] A, B, C, D,
    input logic [1:0] SEL,
    output logic [31:0] OUT
    );
    
    always_comb
    begin
        case(SEL)
            2'b00: OUT = A;
            2'b01: OUT = B;
            2'b10: OUT = C;
            2'b11: OUT = D;
            default: OUT = 'X;
        endcase
    end
endmodule
