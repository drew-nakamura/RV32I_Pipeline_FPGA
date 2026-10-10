`timescale 1ns / 1ps
//============================================================
// Module: Immediate Generator
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   Unpacks instruction bits into the five RISC-V immediates:
//   I, S, B, U, and J. U-type is already shifted up 12 bits.
//============================================================
//Immediate_Generator (
//    .imm(),
//    .U_TYPE(),
//    .I_TYPE(),
//    .S_TYPE(),
//    .B_TYPE(),
//    .J_TYPE()
//    );

module Immediate_Generator(
    input logic [24:0] imm,
    output logic [31:0] U_TYPE, I_TYPE, S_TYPE, B_TYPE, J_TYPE
    );
    assign I_TYPE = {{21{imm[24]}}, imm[23:18], imm[17:14], imm[13]};
    assign S_TYPE = {{21{imm[24]}}, imm[23:18], imm[4:1], imm[0]};
    assign B_TYPE = {{20{imm[24]}}, imm[0], imm[23:18], imm[4:1], 1'b0};
    assign U_TYPE = {imm[24:5], 12'b0};
    assign J_TYPE = {{12{imm[24]}}, imm[12:5], imm[13], imm[23:14], 1'b0};
endmodule
