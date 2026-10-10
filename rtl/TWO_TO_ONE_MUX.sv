`timescale 1ns / 1ps
//============================================================
// Module: 2-to-1 Mux
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   Picks A or B from a 1-bit SEL.
//============================================================
//TWO_TO_ONE_MUX (
//    .A(),
//    .B(),
//    .SEL(),
//    .OUT()
//    );

module TWO_TO_ONE_MUX(
    input logic [31:0] A, B,
    input logic SEL,
    output logic [31:0] OUT
    );
    
    always_comb
    begin
    case(SEL)
    1'b0:  OUT = A;
    1'b1:  OUT = B;
    default: OUT = 'X;
    endcase
    end
        
endmodule
