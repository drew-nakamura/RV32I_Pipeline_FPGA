`timescale 1ns / 1ps
//============================================================
// Module: Branch Condition Generator
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   Compares two register values and raises br_eq, signed
//   br_lt, and unsigned br_ltu. Branch decode uses these flags.
//============================================================
//Branch_Condition_Generator (
//    .rs1(),
//    .rs2(),
//    .br_lt(),
//    .br_eq(),
//    .br_ltu()
//    );

module Branch_Condition_Generator(
    input logic [31:0] rs1, rs2,
    output logic br_lt, br_eq, br_ltu
    );
    
    assign br_lt = ($signed(rs1) < $signed(rs2));
    assign br_eq = (rs1 == rs2);
    assign br_ltu = (rs1 < rs2);
endmodule
