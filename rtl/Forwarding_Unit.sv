`timescale 1ns / 1ps

// Forwarding_Unit (
//     .EX_RS1_READ_ADDR(),
//     .EX_RS2_READ_ADDR(),
//     .MEM_REG_WRITE_ADDR(),
//     .WB_REG_WRITE_ADDR(),
//     .MEM_REG_WE(),
//     .MEM_DMEM_RDEN(),
//     .WB_DMEM_RDEN(),
//     .WB_REG_WRITE_ADDR(),
//     .STALL_IF(),
//     .STALL_ID(),
//     .STALL_EX(),
//     .srcA_FORWARD_SEL(),
//     .srcB_FORWARD_SEL()
//     );

module Forwarding_Unit(
    //==RAW Hazard==
    input logic [4:0] EX_RS1_READ_ADDR,
    input logic [4:0] EX_RS2_READ_ADDR,
    input logic [4:0] MEM_REG_WRITE_ADDR,
    input logic [4:0] WB_REG_WRITE_ADDR,
    input logic MEM_REG_WE,
    input logic MEM_DMEM_RDEN,
    input logic WB_DMEM_RDEN,
    input logic WB_REG_WE,
    output logic STALL_IF,
    output logic STALL_ID,
    output logic STALL_EX, 
    output logic [1:0]srcA_FORWARD_SEL,
    output logic [1:0]srcB_FORWARD_SEL
    );

    //SELS, 00 = No forwarding, 01 = Forward from MEM, 10 = Forward from WB
    always_comb begin
        if((EX_RS1_READ_ADDR == MEM_REG_WRITE_ADDR) && MEM_REG_WE && !MEM_DMEM_RDEN) begin
            //Case 1: EX RS1 needs ALU Result from MEM
            STALL_EX = 0;
            STALL_ID = 0;
            STALL_IF = 0;
            srcA_FORWARD_SEL = 2'b01;
            srcB_FORWARD_SEL = 2'b00;
        end
        else if((EX_RS1_READ_ADDR == MEM_REG_WRITE_ADDR) && MEM_REG_WE && MEM_DMEM_RDEN) begin
            //Case 2: EX RS1 needs Data memory, so we stall
            STALL_EX = 1;
            STALL_ID = 1;
            STALL_IF = 1;
            srcA_FORWARD_SEL = 2'b00;
            srcB_FORWARD_SEL = 2'b00;
        end
        else if ((EX_RS2_READ_ADDR == MEM_REG_WRITE_ADDR) && MEM_REG_WE && !MEM_DMEM_RDEN) begin
            //Case 3: EX RS2 needs ALU Result from MEM
            STALL_EX = 0;
            STALL_ID = 0;
            STALL_IF = 0;
            srcA_FORWARD_SEL = 2'b00;
            srcB_FORWARD_SEL = 2'b01;
        end
        else if((EX_RS2_READ_ADDR == MEM_REG_WRITE_ADDR) && MEM_REG_WE && MEM_DMEM_RDEN) begin
            //Case 4: EX RS2 needs Data memory, so we stall
            STALL_EX = 1;
            STALL_ID = 1;
            STALL_IF = 1;
            srcA_FORWARD_SEL = 2'b00;
            srcB_FORWARD_SEL = 2'b00;
        end
        else if((EX_RS1_READ_ADDR == WB_REG_WRITE_ADDR) && WB_REG_WE && WB_DMEM_RDEN) begin
            //Case 5: EX RS1 needs Data memory and its ready so we forward
            STALL_EX = 0;
            STALL_ID = 0;
            STALL_IF = 0;
            srcA_FORWARD_SEL = 2'b10;
            srcB_FORWARD_SEL = 2'b00;
        end
        else if((EX_RS2_READ_ADDR == WB_REG_WRITE_ADDR) && WB_REG_WE && WB_DMEM_RDEN) begin
            //Case 6: EX RS2 needs Data memory and its ready so we forward
            STALL_EX = 0;
            STALL_ID = 0;
            STALL_IF = 0;
            srcA_FORWARD_SEL = 2'b00;
            srcB_FORWARD_SEL = 2'b10;
        end
        else begin
            //No forwarding needed
            STALL_EX = 0;
            STALL_ID = 0;
            STALL_IF = 0;
            srcA_FORWARD_SEL = 0;
            srcB_FORWARD_SEL = 0;
        end
    end
endmodule