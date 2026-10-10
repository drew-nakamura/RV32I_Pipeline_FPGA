`timescale 1ns / 1ps
//============================================================
// Module: Forwarding Unit
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   Fixes RAW hazards in EX by forwarding from MEM or WB.
//   Also raises a load-use stall when EX needs a MEM load.
//============================================================
// Forwarding_Unit (
//     .EX_RS1_READ_ADDR(),
//     .EX_RS2_READ_ADDR(),
//     .EX_RS1_Used(),
//     .EX_RS2_Used(),
//     .MEM_REG_WRITE_ADDR(),
//     .WB_REG_WRITE_ADDR(),
//     .MEM_REG_WE(),
//     .MEM_DMEM_RDEN(),
//     .WB_REG_WE(),
//     .STALL_IF_ID(),
//     .STALL_ID_EX(),
//     .FLUSH_EX_MEM(),
//     .srcA_FORWARD_SEL(),
//     .srcB_FORWARD_SEL()
//     );

module Forwarding_Unit(
    //==RAW Hazard==
    input logic [4:0] EX_RS1_READ_ADDR,
    input logic [4:0] EX_RS2_READ_ADDR,
    input logic EX_RS1_Used,
    input logic EX_RS2_Used,
    input logic [4:0] MEM_REG_WRITE_ADDR,
    input logic [4:0] WB_REG_WRITE_ADDR,
    input logic MEM_REG_WE,
    input logic MEM_DMEM_RDEN,
    input logic WB_REG_WE,
    output logic STALL_IF_ID,
    output logic STALL_ID_EX,
    output logic FLUSH_EX_MEM,
    output logic [1:0]srcA_FORWARD_SEL,
    output logic [1:0]srcB_FORWARD_SEL
    );

    //SELS, 00 = No forwarding, 01 = Forward from MEM, 10 = Forward from WB, 11 = Force 0
    always_comb begin
        STALL_IF_ID = 0;
        STALL_ID_EX = 0;
        FLUSH_EX_MEM = 0;
        srcA_FORWARD_SEL = 2'b00;
        srcB_FORWARD_SEL = 2'b00;

        if((EX_RS1_READ_ADDR == MEM_REG_WRITE_ADDR) && MEM_REG_WE && MEM_DMEM_RDEN && EX_RS1_Used) begin
            // Case 2: EX rs1 needs a MEM load → stall
            FLUSH_EX_MEM = 1;
            STALL_ID_EX = 1;
            STALL_IF_ID = 1;
        end
        else if((EX_RS2_READ_ADDR == MEM_REG_WRITE_ADDR) && MEM_REG_WE && MEM_DMEM_RDEN && EX_RS2_Used) begin
            // Case 4: EX rs2 needs a MEM load → stall
            FLUSH_EX_MEM = 1;
            STALL_ID_EX = 1;
            STALL_IF_ID = 1;
        end

        if((EX_RS1_READ_ADDR == MEM_REG_WRITE_ADDR) && MEM_REG_WE && !MEM_DMEM_RDEN && EX_RS1_Used) begin
            // Case 1: EX rs1 needs ALU result from MEM
            // sel 11 forces 0 if the match is x0 (x0 write may not be 0 in the flop)
            if(EX_RS1_READ_ADDR == 5'b00000) srcA_FORWARD_SEL = 2'b11;
            else srcA_FORWARD_SEL = 2'b01;
        end
        else if((EX_RS1_READ_ADDR == WB_REG_WRITE_ADDR) && WB_REG_WE && EX_RS1_Used) begin
            // Case 5: EX rs1 matches WB
            if(EX_RS1_READ_ADDR == 5'b00000) srcA_FORWARD_SEL = 2'b11;
            else srcA_FORWARD_SEL = 2'b10;
        end

        if ((EX_RS2_READ_ADDR == MEM_REG_WRITE_ADDR) && MEM_REG_WE && !MEM_DMEM_RDEN && EX_RS2_Used) begin
            // Case 3: EX rs2 needs ALU result from MEM
            if(EX_RS2_READ_ADDR == 5'b00000) srcB_FORWARD_SEL = 2'b11;
            else srcB_FORWARD_SEL = 2'b01;
        end else if((EX_RS2_READ_ADDR == WB_REG_WRITE_ADDR) && WB_REG_WE  && EX_RS2_Used) begin
            // Case 6: EX rs2 matches WB
            if(EX_RS2_READ_ADDR == 5'b00000) srcB_FORWARD_SEL = 2'b11;
            else srcB_FORWARD_SEL = 2'b10;
        end
    end
endmodule
