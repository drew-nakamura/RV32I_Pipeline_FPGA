`timescale 1ns / 1ps
//============================================================
// Module: 2_TO_1_MUX
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   Takes in two 32 bit balues and outputs one depending on
//   the input SEL.
//
// Notes:
//   - Educational use only
//   - Not an original architecture design
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
