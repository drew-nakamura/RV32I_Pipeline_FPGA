`timescale 1ns / 1ps
//============================================================
// Module: Jump / Branch Address Generator
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   Builds the three possible next-PC targets: jal = PC+J,
//   branch = PC+B, and jalr = (rs1+I) with bit 0 cleared.
//============================================================
//Jump_Branch_Address_Generator (
//    .PC(),
//    .J_Type(),
//    .B_Type(),
//    .I_Type(),
//    .rs1(),
//    .jalr(),
//    .branch(),
//    .jal()
//    );

module Jump_Branch_Address_Generator(
    input logic [31:0] PC, J_Type, B_Type, I_Type, rs1,
    output logic [31:0] jalr, branch, jal
    );
    
    assign jalr = (I_Type + rs1) & 32'hFFFFFFFE; // ISA: jalr target LSB must be 0
    assign branch = PC + B_Type;
    assign jal = PC + J_Type;
endmodule
