`timescale 1ns / 1ps
//============================================================
// Module: IMMEDIATE GENERATOR
// Author: Drew Nakamura
// Project: OTTER_MULTICYCLE_CONTROLLER
//
// Description:
//   The immediate generator creates the immediate values for the
//   different type instructions. For example, the U_Type immediate
//   is shifted up 12 bits in this module.
//
// Context:
//   This module was implemented as part of coursework for
//   CPE 233 at California Polytechnic State University
//   (Cal Poly San Luis Obispo).
//
//   The overall processor architecture is based on the
//   "OTTER" RISC-V microcontroller developed for the course
//   by Cal Poly faculty.
//
//   This file contains my own implementation of the module
//   based on the provided specifications.
//   This is for my first implimentation of the Otter Spring 2026
//
// Notes:
//   - Educational use only
//   - Not an original architecture design
//============================================================
//Immediate_Generator (
//    .imm(),
//    .U_TYPE(),
//    .I_TYPE(),
//    .S_TYPE(),
//    .B_TYPE(),
//    .J_TYPE()
//    );

module Immediate_Generator(
    input logic [24:0] imm,
    output logic [31:0] U_TYPE, I_TYPE, S_TYPE, B_TYPE, J_TYPE
    );
    assign I_TYPE = {{21{imm[24]}}, imm[23:18], imm[17:14], imm[13]};
    assign S_TYPE = {{21{imm[24]}}, imm[23:18], imm[4:1], imm[0]};
    assign B_TYPE = {{20{imm[24]}}, imm[0], imm[23:18], imm[4:1], 1'b0};
    assign U_TYPE = {imm[24:5], 12'b0};
    assign J_TYPE = {{12{imm[24]}}, imm[12:5], imm[13], imm[23:14], 1'b0};
endmodule
