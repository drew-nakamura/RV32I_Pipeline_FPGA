//============================================================
// Module: Register File
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   32 x 32-bit registers with two read ports and one write
//   port. x0 is hardwired to 0.
//============================================================
//REG_FILE (
//    .CLK(),
//    .en(),
//    .adr1(),
//    .adr2(),
//    .w_adr(),
//    .w_data(),
//    .rs1(),
//    .rs2()
//    );

module Reg_File(
    input logic CLK, en,
    input logic [4:0] adr1, adr2, w_adr,
    input logic [31:0] w_data,
    output logic [31:0] rs1, rs2
    );
    
    (* ram_style = "distributed" *)
    logic [31:0] registers [0:31];
    // No reset: x1–x31 start as junk. x0 is forced to 0 on the output,
    // not stored as 0 in the array.

    always_ff @(posedge CLK)
    begin
        if(en &&(w_adr != 5'd0))
            registers[w_adr] <= w_data;
    end
    always_comb
    begin
        rs1 = (adr1 == 5'd0) ? 32'b0 : registers[adr1];
        rs2 = (adr2 == 5'd0) ? 32'b0 : registers[adr2];
    end
endmodule
