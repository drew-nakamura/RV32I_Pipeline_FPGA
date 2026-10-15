`timescale 1ns / 1ps
//============================================================
// Module: IMEM (Instruction Memory)
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//   Instruction ROM. Loads a hex file and returns the word
//   at PC. Stall holds the fetch; flush forces a nop.
//============================================================

// IMEM (
//     .CLK(),
//     .PC(),
//     .STALL(),
//     .FLUSH(),
//     .instruction(),
//     .PC_USED()
//     );

module IMEM #(
    parameter string MEM_FILE = "Test_All_imem.mem"
    )
    (
    input logic CLK,
    input logic [31:0] PC,
    input logic STALL,
    input logic FLUSH,
    input logic freeze,
    output logic [31:0] instruction,
    output logic [31:0] PC_USED
    );

    logic [12:0] wordAddress;
    (* rom_style="{distributed | block}" *)
    (* ram_decomp = "power " *)
    logic [31:0] instruction_memory[0:8191];

    initial begin
        $readmemh(MEM_FILE, instruction_memory);
    end

    // Word-aligned: drop PC[1:0]
    assign wordAddress ={PC[14:2]};

    always_ff @(posedge CLK) begin
        if(FLUSH && !STALL) begin
            instruction <= instruction_memory[wordAddress];
            PC_USED <= PC;
        end
        else if(STALL) begin
            instruction <= instruction;
            PC_USED <= PC_USED;
        end
        else if(freeze) begin
            instruction <= 32'b0;
            PC_USED <= PC_USED;
        end
        else begin
            instruction <= instruction_memory[wordAddress];
            PC_USED <= PC;
        end
    end
endmodule
