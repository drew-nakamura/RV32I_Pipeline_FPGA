`timescale 1ns / 1ps
//============================================================
// Module: IMEM(Instruction Memory)
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//    All instructions will be loaded in here, acting as read only memory(rom).
//    Will also act as the 
// 
// Notes:
//   - Educational use only
//   - Not an original architecture design
//============================================================

// IMEM (
//     .CLK(),
//     .PC(),
//     .instruction()
//     );

module IMEM #(
    parameter string MEM_FILE = "imem.mem"
    )
    (
    input logic CLK,
    input logic [31:0] PC,
    output logic [31:0] instruction,
    output logic [31:0] PC_USED
    );

    logic [12:0] wordAddress;
    (* rom_style="{distributed | block}" *)
    (* ram_decomp = "power " *)
    logic [31:0] instruction_memory[0:8191];

    //Read from loaded imem file!!
    initial begin
        $readmemh(MEM_FILE, instruction_memory);
    end

    //no non word read
    assign wordAddress ={PC[14:2]};

    always_ff @(posedge CLK) begin
        instruction <= instruction_memory[wordAddress];
        PC_USED <= PC;
    end
endmodule
