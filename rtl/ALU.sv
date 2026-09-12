`timescale 1ns / 1ps
//============================================================
// Module: Arithmatic Logical Unit
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   The Arithmatic Logical Unit is designed to handle most of the 
//   bitwise modifications such
//   as addition, subtraction, or, and, exclusive or, shirft right 
//   logical, shift left logical shift left logical, shift right arthmatic, 
//   set if less than, set if less than unsigned, and finally .
//
// Notes:
//   - Educational use only
//   - Not an original architecture design
//=============================
//ALU(
//    .srcA(),
//    .srcB(),
//    .alu_func(),
//    .result()
//    );


module ALU(
    input logic [31:0] srcA, srcB,
    input logic [3:0] alu_func,
    output logic [31:0] result
    );

    always_comb
    begin
        case(alu_func)
            4'b0000: result = srcA + srcB;//add
            4'b1000: result = srcA - srcB;//sub
            4'b0110: result = srcA | srcB;//or
            4'b0111: result = srcA & srcB;//and
            4'b0100: result = srcA ^ srcB;//xor
            4'b0101: result = srcA >> srcB[4:0];//srl
            4'b0001: result = srcA << srcB[4:0];//sll
            4'b1101: result = $signed(srcA) >>> srcB[4:0];//sra
            4'b0010: result = ($signed(srcA) < $signed(srcB)) ? 32'd1 : 32'd0;// slt 
            4'b0011: result = (srcA < srcB) ? 32'd1 : 32'd0;//sltu
            4'b1001: result = srcA;//lui-copy The U-Type Imm already shifts it 12
            default: result = 32'b0;
         endcase
    end
    
endmodule
