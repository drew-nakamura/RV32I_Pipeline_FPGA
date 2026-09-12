`timescale 1ns / 1ps
//============================================================
// Module: Branch Condition Generator
// Author: Drew Nakamura
// Project:  5_Stage_Pipeline
//
// Description:
//   The branch condition generator is incharge of the arithamtic
//   operation of comparing the two register values. Outputs the 
//   condition of each one, meaning only one is output as true
//
// Notes:
//   - Educational use only
//   - Not an original architecture design
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
