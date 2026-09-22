`timescale 1ns / 1ps
//============================================================
// Module: Branch Address Generator
// Author: Drew Nakamura
// Project:  OTTER_multi_Cycle
//
// Description:
//   The branch address generator takes in PC, immediates made by
//   immediate generator, and rs1 to computer possible branch values
//   for the PC Next.
//
// Notes:
//   - Educational use only
//   - Not an original architecture design
//=============================
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
    
    assign jalr = (I_Type + rs1) & 32'hFFFFFFFE; 
        //previously had the mask, but while reading the ISA it states
        //"Clearing the least-significant bit when calculating the 
        //JALR target address both simplifies the hardware slightly 
        //and allows the low bit of function pointers to be used to 
        //store auxiliary information" so T added it.
    assign branch = PC + B_Type;
    assign jal = PC + J_Type;
endmodule
