`timescale 1ns / 1ps
//============================================================
// Module: DRAN(Data Memory)
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//    CPU uses to store information 
//    
// 
// Notes:
//   - Educational use only
//   - Not an original architecture design
// Currently 8 KB of Ram, specially should be installed as BRAM on FPGA
//============================================================
//WE should probably make sutffl ike address width auto calcualte based on ram size, rembeer to maunally change when we change stuff

// DMEM(
//     .CLK(),
//     .WE(),
//     .RDEN(),
//     .address(),
//     .data_in(),
//     .mem_data(),
//     .data_out()
// );
module DMEM(
    parameter string MEM_FILE = "dmem.mem",
    input logic CLK,
    input logic WE,
    input logic RDEN,
    input logic [31:0] address,
    input logic [31:0] data_in,
    input logic [2:0] mem_data,
    output logic [31:0] data_out
)   ;

    logic [31:0] memReadWord;
    logic [10:0] wordAddress;
    logic [1:0] mem_size, byteOffset;
    logic mem_sign;


    (* ram_style="{distributed | block}" *)
    (* ram_decomp = "power " *)
    logic [31:0] memory[0:2047];

    //Read from loaded w_ramS file!!
    initial begin
        $readmemh(MEM_FILE, memory);
    end

    assign mem_size = mem_data[2:1];
    assign mem_sign = mem_data[0];
    assign byteOffset = address[1:0];

    assign wordAddress = address[10:2]; // non word read

    always_ff @(posedge CLK) begin
        //=====================================WRITE=============
        if (WE) begin     // write enable and valid address space
            case({mem_size, byteOffset})
                4'b0000: memory[wordAddress][7:0]   <= data_in[7:0];     // sb at byte offsets
                4'b0001: memory[wordAddress][15:8]  <= data_in[7:0];
                4'b0010: memory[wordAddress][23:16] <= data_in[7:0];
                4'b0011: memory[wordAddress][31:24] <= data_in[7:0];
                4'b0100: memory[wordAddress][15:0]  <= data_in[15:0];    // sh at byte offsets
                4'b0101: memory[wordAddress][23:8]  <= data_in[15:0];
                4'b0110: memory[wordAddress][31:16] <= data_in[15:0];
                4'b1000: memory[wordAddress]        <= data_in;          // sw
            endcase
        end

        if (RDEN)// Read word from memory, to be edited based on load size
            memReadWord <= memory[wordAddress];
        end
        // Change the data word into sized bytes and sign extend
        always_comb begin
        case({mem_sign, mem_size,byteOffset})
            5'b00011: data_out = {{24{memReadWord[31]}},memReadWord[31:24]};  // signed byte
            5'b00010: data_out = {{24{memReadWord[23]}},memReadWord[23:16]};
            5'b00001: data_out = {{24{memReadWord[15]}},memReadWord[15:8]};
            5'b00000: data_out = {{24{memReadWord[7]}},memReadWord[7:0]};
                                        
            5'b00110: data_out = {{16{memReadWord[31]}},memReadWord[31:16]};  // signed half
            5'b00101: data_out = {{16{memReadWord[23]}},memReadWord[23:8]};
            5'b00100: data_out = {{16{memReadWord[15]}},memReadWord[15:0]};
                
            5'b01000: data_out = memReadWord;                   // word
                
            5'b10011: data_out = {24'd0,memReadWord[31:24]};    // unsigned byte
            5'b10010: data_out = {24'd0,memReadWord[23:16]};
            5'b10001: data_out = {24'd0,memReadWord[15:8]};
            5'b10000: data_out = {24'd0,memReadWord[7:0]};
                
            5'b10110: data_out = {16'd0,memReadWord[31:16]};    // unsigned half
            5'b10101: data_out = {16'd0,memReadWord[23:8]};
            5'b10100: data_out = {16'd0,memReadWord[15:0]};
                
            default:  data_out = 32'b0;     // unsupported size, byte offset combination
        endcase
        end 
endmodule 