`timescale 1ns / 1ps


// module Control_Unit_Decoder(
//     .opcode(),
//     .func3(),
//     .ir30(),
//     .srcA_SEL(),
//     .RF_WE(),
//     .memWE(),
//     .memRDEN(),
//     .branch_i(),
//     .jal_i(),
//     .jalr_i(),
//     .srcB_SEL(),
//     .RF_SEL(),
//     .ALU_FUN()
// );

import CPU_pkg::*;
module Control_Unit_Decoder(
    input logic [6:0] opcode,
    input logic [2:0] func3,
    input logic ir30, //for ADD/SUB & SRL/SRA
    output logic srcA_SEL, RF_WE, memWE, memRDEN, branch_i, jal_i, jalr_i,
    output logic [1:0] srcB_SEL, RF_SEL,
    output logic [3:0] ALU_FUN
    );

    always_comb begin
        //===Base Cases===
        ALU_FUN = alu_ADD;
        srcA_SEL =  srca_rs1;
        srcB_SEL = srcb_rs2;
        RF_SEL = WB_PC4;
        RF_WE = 1'b0;
        memWE = 1'b0;
        memRDEN = 1'b0;
        branch_i = 1'b0;
        jal_i = 1'b0;
        
        case(opcode)
        7'b0110111://==U-Type -> LUI====================
        begin
            ALU_FUN = alu_LUI_COPY;
            srcA_SEL = srca_U_TYPE;
            RF_SEL = WB_ALU;
            RF_WE = 1'b1;
        end
            
        7'b0010111://==U-Type -> AUPIC====================
        begin
            srcA_SEL =  srca_U_TYPE;
            srcB_SEL = srcb_PC;
            RF_SEL = WB_ALU;
            memRDEN = 0;
            memWE = 0;
            RF_WE = 1'b1;
        end
    
        7'b1101111://==J-Type -> JAL====================
        begin
            srcA_SEL = srca_U_TYPE;
            srcB_SEL = srcb_PC;
            RF_SEL = WB_PC4;
            jal_i = 1'b1;

            memRDEN = 0;
            memWE = 0;
            RF_WE = 1'b1;
        end

        7'b1100111://==I-Type -> JALR====================
        begin
            //Address is calculated in the Jump_Branch_Address_Generator
            RF_SEL = WB_PC4;
            jalr_i = 1'b1;
            RF_WE = 1'b1;
        end

        7'b0000011://==I-Type -> LOADS=====================
        begin
            //Size difference is detemrined in the memory module
            srcA_SEL =  srca_rs1;
            srcB_SEL = srcb_I_TYPE;
            RF_SEL = WB_DATA_IN; //Write back stage will load from mem
            memRDEN = 1;
            RF_WE = 1'b1;
        end
        
        7'b0010011://==I-Type -> ALU STUFF=====================
        begin
            //Base case covers ADDI,
            ALU_FUN = alu_ADD;
            srcA_SEL =  srca_rs1;
            srcB_SEL = srcb_I_TYPE;
            RF_SEL = WB_ALU;

            RF_WE = 1'b1;
            
            case(func3)
                3'b000: ALU_FUN = alu_ADD; //ADD
                3'b010: ALU_FUN = alu_SLT;//SLTI            
                3'b011: ALU_FUN = alu_SLTU;//SLTIU
                3'b110: ALU_FUN = alu_OR;//ORI
                3'b100: ALU_FUN = alu_XOR; //XORI
                3'b111: ALU_FUN = alu_AND;//ANDI
                3'b001: ALU_FUN = alu_SLL;//SLLI
                3'b101: ALU_FUN = ir30 ? alu_SRA : alu_SRL;//SRA and SRL
                default: ALU_FUN = 'X;
            endcase
        end

        7'b0110011://==R-Type=====================
        begin
            RF_WE = 1'b1;
            //All other defaults work for R type
            RF_SEL = WB_ALU;
            case(func3)
            3'b000: ALU_FUN = ir30 ? alu_SUB : alu_ADD;
            3'b001: ALU_FUN = alu_SLL;//SLL
            3'b010: ALU_FUN = alu_SLT;//SLT
            3'b011: ALU_FUN = alu_SLTU;//SLTU
            3'b100: ALU_FUN = alu_XOR;//XOR
            3'b101: ALU_FUN = ir30 ? alu_SRA : alu_SRL; // SRA/SRL
            3'b110: ALU_FUN = alu_OR;//OR
            3'b111: ALU_FUN = alu_AND;//AND
            default: ALU_FUN = 'X;
            endcase
        end

        7'b0100011://S-Type
        begin
            srcB_SEL = srcb_S_TYPE;
            memWE = 1'b1;
        end

        7'b1100011: //B-Type
        begin
            branch_i = 1'b1;
        end
        default: begin
                ALU_FUN = 'X;
                srcA_SEL =  'X;
                srcB_SEL = 'X;
                RF_SEL = 'X;
                RF_WE = 'X;
                memWE = 'X;
                memRDEN = 'X;
                branch_i = 'X;
                jalr_i = 'X;
                jal_i = 'X;
        end
        endcase
    end

endmodule