`timescale 1ns / 1ps
//============================================================
// Module: Hazard Unit
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   Flushes IF/ID and ID/EX when EX takes a jal, jalr, or
//   taken branch. Does nothing while the pipeline is stalled.
//============================================================
// HazardUnit (
//     .branch_i(),
//     .jal_i(),
//     .jalr_i(),
//     .PC_SEL(),
//     .IF_ID_Stall(),
//     .Hazard_FLUSH_IF_ID(),
//     .Hazard_FLUSH_ID_EX()
//     );

module HazardUnit(
    input logic branch_i,
    input logic jal_i,
    input logic jalr_i,
    input logic [1:0] PC_SEL,
    input logic IF_ID_Stall,
    input logic trap,
    output logic Hazard_FLUSH_IF_ID, 
    output logic Hazard_FLUSH_ID_EX
    );
    // Flush is sampled on posedge: it blocks the next register update.
    // It does not erase the instruction already sitting in the flop

    always_comb begin
        if(IF_ID_Stall) begin
            Hazard_FLUSH_IF_ID = 0;
            Hazard_FLUSH_ID_EX = 0;
        end
        else if (jal_i || jalr_i) begin
            Hazard_FLUSH_IF_ID = 1;
            Hazard_FLUSH_ID_EX = 1;
        end
        else if (branch_i && PC_SEL == 2'b10) begin
            Hazard_FLUSH_IF_ID = 1;
            Hazard_FLUSH_ID_EX = 1;
        end
        else if (trap) begin
            Hazard_FLUSH_IF_ID = 1;
            Hazard_FLUSH_ID_EX = 1;
        end
        else begin
            Hazard_FLUSH_IF_ID = 0;
            Hazard_FLUSH_ID_EX = 0;
        end
    end

endmodule
