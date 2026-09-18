`timescale 1ns / 1ps

module Interconnect(
    input logic [31:0] address,
    input logic WE,
    input logic [31:0] CPU_DATA,
    input logic IOBUS_RDEN,
    input logic DMEM_DATA,
    input logic [31:0] SWITCHES,
    input logic [31:0] BUTTONS,
    output logic DMEM_RDEN,
    output logic DMEM_WE,
    output logic LEDS_WE,
    output logic SSEG_WE,
    output logic [31:0] IOBUS_in
    );

    always_comb begin
        IOBUS_in = 32'b0;
        DMEM_RDEN = 1'b0;
        DMEM_WE = 1'b0;
        LEDS_WE = 1'b0;
        SSEG_WE = 1'b0;
        if(address >= 32'h11000000) begin
            case(address)
                32'h11000000: if(IOBUS_RDEN) IOBUS_in = SWITCHES; //SWITCHES 
            
                32'h11000020: LEDS_WE = WE; //LEDS
                
                32'h11000040: if(WE) SSEG_WE = 1'b1;//SSEG
                32'h11000080: if(IOBUS_RDEN) IOBUS_in = BUTTONS; //BUTTONS
            endcase
        end else
        if(address > 32'h0009FFF) begin
            //nothing happens yet... reserved space for other stuff.
        end else
        if(address > 32'h7FFF)begin
            DMEM_RDEN = IOBUS_RDEN;
            DMEM_WE = WE;
            if(IOBUS_RDEN) begin
                IOBUS_in = DMEM_DATA;
            end
        end else begin
            //Nothing happens this is IMEM.
        end
    end
endmodule
