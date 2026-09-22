//============================================================
// Module: Register File
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   The Register File holds 32, 32 bit registers to hold
//   output of mathamatical operations, memory data, next pc
//   value, and sometimes whatvever is coming out of the 
//   interupt hardware(only if interupts included).
//
// Notes:
//   - Educational use only
//   - Not an original architecture design
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

module REG_FILE(
    input logic CLK, en,
    input logic [4:0] adr1, adr2, w_adr,
    input logic [31:0] w_data,
    output logic [31:0] rs1, rs2
    );
    
    (* ram_style = "distributed" *)
    logic [31:0] registers [0:31]; //Create our 32, 32 bit registers
    //The otter wasnt designed with a reset, so we have no real 
    //way of initializing everything to 0 if we wanted to.
    
    //ASSUME ALL REGISTERS OTHER THAN x0 are JUNK AT START!!!!
    always_ff @(posedge CLK)
    begin
        if(en &&(w_adr != 5'd0))
            registers[w_adr] <= w_data;
    end
    
    //Note:
    //This assignment means internally x0 is unititialized
    //We force the output to be zero, not the reg itself.
    always_comb
    begin
        rs1 = (adr1 == 5'd0) ? 32'b0 : registers[adr1];
        rs2 = (adr2 == 5'd0) ? 32'b0 : registers[adr2];
    end
endmodule
