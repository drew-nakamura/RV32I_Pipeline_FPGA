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
// Decsion:
//  9/2/2026: Will act as the IF/ID register to align PC with ir, and
//      it sounds liek it wil solve the weird sync timing bugs with PC mod, IF/ID reg, and IMEM.
//============================================================

// IMEM (
//     .CLK(),
//     .PC(),
//     .instruction()
//     );

module IMEM(
    input logic CLK,
    input logic [31:0] PC,
    output logic [31:0] instruction
    );

    logic [12:0] wordAddress;
    (* rom_style="{distributed | block}" *)
    (* ram_decomp = "power " *)
    logic [31:0] instruction_memory[0:8191];

    //Read from loaded imem file!!
    initial begin
        $readmemh("imem.mem", instruction_memory, 0, 8191);
    end

    //no non word read
    assign wordAddress ={PC[12:2]};

    always_ff @(posedge CLK) begin
        instruction <= instruction_memory[wordAddress];
    end
endmodule
