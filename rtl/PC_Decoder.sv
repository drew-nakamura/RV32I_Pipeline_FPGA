`timescale 1ns / 1ps


// PC_Decoder (
//     .br_lt(),
//     .br_eq(),
//     .br_ltu(),
//     .branch_i(),
//     .jal_i(),
//     .jalr_i(),
//     .func3(),
//     .PC_SEL()
// )

module PC_Decoder(
    input logic br_lt,
    input logic br_eq,
    input logic br_ltu,
    input logic branch_i,
    input logic jal_i,
    input logic jalr_i,
    input logic [2:0]func3,
    output logic [1:0] PC_SEL
    );
    
    always_comb begin
        unique case([{branch_i, jal_i, jalr_i}])
            3'b000: PC_SEL = pc_PC4;
            3'b100: begin
                case(func3)
                3'b000: begin PC_SEL = br_eq  ? pc_BRANCH : pc_PC4; end // BEQ
                3'b001: begin PC_SEL = ~br_eq ? pc_BRANCH : pc_PC4; end // BNE
                3'b100: begin PC_SEL = br_lt  ? pc_BRANCH : pc_PC4; end // BLT
                3'b101: begin PC_SEL = ~br_lt ? pc_BRANCH : pc_PC4; end // BGE
                3'b110: begin PC_SEL = br_ltu ? pc_BRANCH : pc_PC4; end // BLTU
                3'b111: begin PC_SEL = ~br_ltu? pc_BRANCH : pc_PC4; end // BGEU
                default: PC_SEL = pc_PC4;
            endcase
            end
            3'b010: PC_SEL = pc_JAL;
            3'b001: PC_SEL = pc_JALR;
        default: PC_SEL = 'X;
    end

