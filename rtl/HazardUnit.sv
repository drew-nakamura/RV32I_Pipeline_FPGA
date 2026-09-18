`timescale 1ns / 1ps


// HazardUnit (
//     .branch_i(branch_i),
//     .jal_i(jal_i),
//     .jalr_i(jalr_i),
//     .PC_SEL(PC_SEL),
//     .Hazard_FLUSH_ID_EX(Hazard_FLUSH_ID_EX),
//     .Hazard_FLUSH_EX_MEM(Hazard_FLUSH_EX_MEM)
// )
module HazardUnit(
    input logic branch_i,
    input logic jal_i,
    input logic jalr_i,
    input logic [1:0] PC_SEL,
    output logic Hazard_FLUSH_IF_ID, 
    output logic Hazard_FLUSH_ID_EX
    );
    //Lowkey a little confusing, but these signals will be sitting and executed
    // on the posedge, so it will prevent its update not remove the current stuff.

    always_comb begin
        if (jal_i || jalr_i) begin
            Hazard_FLUSH_IF_ID = 1;
            Hazard_FLUSH_ID_EX = 1;
        end
        else if (branch_i && PC_SEL == 2'b10) begin
            Hazard_FLUSH_IF_ID = 1;
            Hazard_FLUSH_ID_EX = 1;
        end
        else begin
            Hazard_FLUSH_IF_ID = 0;
            Hazard_FLUSH_ID_EX = 0;
        end
    end

endmodule