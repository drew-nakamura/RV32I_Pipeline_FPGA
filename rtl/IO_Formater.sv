
`timescale 1ns / 1ps
//============================================================
// Module: IO_Formater
// Author: Drew Nakamura
// Project: 5_Stage_Pipeline
//
// Description:
//    Formats the inputs and outputs of data between the CPU and IO.
//     Speciacally for load and store inst that have 
//     byte, halfword, word, signed, and unsigned differentials.
//    
// 
// Notes:
//   - Educational use only
//   - Not an original architecture design
// Currently 8 KB of Ram, specially should be installed as BRAM on FPGA
//============================================================

module IO_Formater (
    input logic memWE,
    input logic memRDEN,
    input logic mem_SIGN,
    input logic mem_SIZE,
    input logic [31:0] DATA_IN, //YO THIS FOR WB STAGE
    input logic [31:0] ADDR,
    output logic [31:0] IO_write_data, //YO THIS FOR MEM STAGE
    output logic [31:0] IO_read_data //YO THIS FOR WB STAGE
    );

    assign [13:0] wordAddr2 = ADDR[15:2];
    assign [1:0] byteOffset = ADDR[1:0];

    always_comb begin
        if (memWE == 1) begin     // write enable and valid address space
            case({mem_SIZE,byteOffset})
                4'b0000: IO_write_data[7:0]   = DATA_IN[7:0];     // sb at byte offsets
                4'b0001: IO_write_data[15:8]  = DATA_IN[7:0];
                4'b0010: IO_write_data[23:16] = DATA_IN[7:0];
                4'b0011: IO_write_data[31:24] = DATA_IN[7:0];
                4'b0100: IO_write_data[15:0]  = DATA_IN[15:0];    // sh at byte offsets
                4'b0101: IO_write_data[23:8]  = DATA_IN[15:0];
                4'b0110: IO_write_data[31:16] = DATA_IN[15:0];
                4'b1000: IO_write_data        = DATA_IN;          // sw
            endcase
        end
        else begin
            IO_write_data = 'X;
        end
        if(memRDEN)begin
            case({mem_SIGN,mem_SIZE,byteOffset})
                5'b00011: IO_read_data = {{24{DATA_IN[31]}},DATA_IN[31:24]};  // signed byte
                5'b00010: IO_read_data = {{24{DATA_IN[23]}},DATA_IN[23:16]};
                5'b00001: IO_read_data = {{24{DATA_IN[15]}},DATA_IN[15:8]};
                5'b00000: IO_read_data = {{24{DATA_IN[7]}},DATA_IN[7:0]};
                                            
                5'b00110: IO_read_data = {{16{DATA_IN[31]}},DATA_IN[31:16]};  // signed half
                5'b00101: IO_read_data = {{16{DATA_IN[23]}},DATA_IN[23:8]};
                5'b00100: IO_read_data = {{16{DATA_IN[15]}},DATA_IN[15:0]};
                    
                5'b01000: IO_read_data = DATA_IN;                   // word
                    
                5'b10011: IO_read_data = {24'd0,DATA_IN[31:24]};    // unsigned byte
                5'b10010: IO_read_data = {24'd0,DATA_IN[23:16]};
                5'b10001: IO_read_data = {24'd0,DATA_IN[15:8]};
                5'b10000: IO_read_data = {24'd0,DATA_IN[7:0]};
                    
                5'b10110: IO_read_data = {16'd0,DATA_IN[31:16]};    // unsigned half
                5'b10101: IO_read_data = {16'd0,DATA_IN[23:8]};
                5'b10100: IO_read_data = {16'd0,DATA_IN[15:0]};
                    
                default:  IO_read_data = 'X;     // unsupported size, byte offset combination
            endcase
        end
        else begin
            IO_read_data = 'X;
        end
    end
endmodule