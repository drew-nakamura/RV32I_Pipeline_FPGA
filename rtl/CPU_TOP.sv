`timescale 1ns / 1ps


// Decsion:
// 9/2/2026: Remove the IF/ID reg, it only holds IR and P, instead, since the
//            IMEM is suynch and clocked, we can hold pc there to align the pc read and the ir.
//

// CPU_TOP (
//     .RST(),
//     .CLK(),
//     .DATA_IN(),
//     .DATA_ADDRESS(),
//     .DATA_OUT(),
//     .RDEN(),
//     .WE()
//     );

module CPU_TOP(
    input logic RST,
    input logic CLK,
    input logic [31:0] DATA_IN,
    output logic [2:0] mem_data,
    output lgoic [31:0] DATA_ADDRESS,
    output logic [31:0] DATA_OUT,
    output logic RDEN,
    output logic WE
    );

    //===Structs====
    id_ex_t id_ex_d;  // Next value
    id_ex_t id_ex_q;  // Registered/current value 
    ex_mem_t ex_mem_d;
    ex_mem_t ex_mem_q;
    mem_wb_t mem_wb_d;
     mem_wb_t mem_wb_q;

    //====ENUMS=====
    instr_name_e instruction;
    stage_e stage;

    //===CPU WIRE/BUFFERS===
    logic reset;
    
    //===PC Wires===
    logic [31:0] PC;

    //===IMEM Wires==
    logic [31:0] ir;
    logic [31:0] PC_USED;

    //==Reg File Wires===
    logic [31:0] rs1, rs2, write_data;

    //===Branch Cond Gen Wires===
    logic br_lt, br_eq, br_ltu;

    //===ALU WIRES====
    logic [31:0] srcA, srcB, ALU_out;

    //===IO_Formater Wires===
    loigc [31:0] IO_write_data;
    logic [31:0] IO_read_data;
    //========== FETCH ===============================
    Program_Counter PC(
        .reset(RST),
        .PC_SEL(PC_SEL), //Comes from ID stage
        .PC_PLUS_FOUR(PC_USED + 4),//Comes from ID stage
        .JALR_ADDR(jalr),
        .BRANCH_ADDR(branch),
        .JAL_ADDR(jal),
        .PC(PC)
    );

    IMEM IMEM(
        .CLK(CLK),
        .PC(PC),
        .instruction(ir),
        .PC_USED(PC_USED)
    );

    //========== DECODE ===============================
    
    assign instruction = decode_instr_name(ir);
    assign stage = FETCH;


    REG_FILE (
        .CLK(CLK),
        .en(mem_wb_q.RF_WE),      //WB
        .adr1(ir[19:15]),   //ID
        .adr2(ir[24:20]),    //ID
        .w_adr(mem_wb_q.),   //WB
        .w_data(),  //WB
        .rs1(id_ex_d.rs1),  //ID
        .rs2(id_ex_d.rs2)   //ID
    );

    Control_Unit_Decoder Control_Unit_Decoder(
        .opcode(ir[6:0]),
        .func3(ir[14:12]),
        .ir30(ir[30]),
        .srcA_SEL(srcA_SEL),
        .RF_WE(RF_WE),
        .memWE(memWE),
        .memRDEN(memRDEN),
        .branch_i(branch_i),
        .jal_i(jal_i),
        .jalr_i(jalr_i),
        .srcB_SEL(srcB_SEL),
        .RF_SEL(RF_SEL),
        .ALU_FUN(ALU_FUN)
    );

    Immediate_Generator (
        .imm(ir[31:7]),
        .U_TYPE(U_Type),
        .I_TYPE(I_Type),
        .S_TYPE(S_Type),
        .B_TYPE(B_Type),
        .J_TYPE(J_Type)
    );

    always_comb begin
        id_ex_d.PC = PC_USED;
        id_ex_d.func3 = ir[14:12];
        id_ex_d.srcA_SEL = srcA_SEL;
        id_ex_d.RF_WE = RF_WE;
        id_ex_d.memWE = memWE;
        id_ex_d.memRDEN = memRDEN;
        id_ex_d.branch_i = branch_i;
        id_ex_d.jal_i = jal_i;
        id_ex_d.jalr_i = jalr_i;
        id_ex_d.mem_sign = ir[14];
        id_ex_d.mem_size = ir[13:12];
        id_ex_d.srcB_SEL = srcB_SEL;
        id_ex_d.RF_SEL = RF_SEL;
        id_ex_d.reg_write_addr = ir[11:7];
        id_ex_d.ALU_FUN = ALU_FUN;
        id_ex_d.U_Type = U_Type;
        id_ex_d.I_Type = I_Type;
        id_ex_d.S_Type = S_Type;
        id_ex_d.B_Type = B_Type;
        id_ex_d.J_Type = J_Type;
        id_ex_d.instruction = instruction;
        id_ex_d.stage = DECODE;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            id_ex_q <= '0;
        end
        else begin
            id_ex_q <= id_ex_d;
        end
    end

//=========EX STAGE ========================
    Branch_Condition_Generator (
        .rs1(id_ex_q.rs1),
        .rs2(id_ex_q.rs2),
        .br_lt(br_lt),
        .br_eq(br_eq),
        .br_ltu(br_ltu)
    );

    PC_Decoder (
        .br_lt(br_lt),
        .br_eq(br_eq),
        .br_ltu(br_ltu),
        .branch_i(id_ex_q.branch_i),
        .jal_i(id_ex_q.jal_i),
        .jalr_i(id_ex_q.jalr_i),
        .func3(id_ex_q.func3),
        .PC_SEL(PC_SEL)
    );

    Jump_Branch_Address_Generator (
        .PC(PC),
        .J_Type(id_ex_q.J_Type),
        .B_Type(id_ex_q.B_Type),
        .I_Type(id_ex_q.I_Type),
        .rs1(id_ex_q.rs1),
        .jalr(jalr),
        .branch(branch),
        .jal(jal)
    );

    TWO_TO_ONE_MUX srcA_MUX(
        .A(id_ex_q.rs1),
        .B(id_ex_q.U_Type),
        .SEL(id_ex_q.srcA_SEL),
        .OUT(srcA)
    );

    FOUR_TO_ONE_MUX srcB_MUX(
        .A(id_ex_q.rs2),
        .B(id_ex_q.I_Type),
        .C(id_ex_q.S_Type),
        .D(id_ex_q.PC),
        .SEL(id_ex_q.srcB_SEL),
        .OUT(srcB)
   );

   ALU Arithmatic_Logical_Unit(
        .srcA(srcA),
        .srcB(srcB),
        .alu_func(id_ex_q.ALU_FUN),
        .result(ALU_result)
   );

    always_comb begin
        ex_mem_d.PC = id_ex_q.PC;
        ex_mem_d.RF_WE = id_ex_q.RF_WE;
        ex_mem_d.RF_SEL = id_ex_q.RF_SEL;
        ex_mem_d.reg_write_addr = id_ex_q.reg_write_addr;
        ex_mem_d.ALU_result = ALU_result;
        //FUCK IT LETS DO IT, data is caught by the psoedge to read/write dmem, as data should be ready by the ned of EX
        mem_data = [{id_ex_q.mem_size, id_ex_q.mem_sign}]
        DATA_ADDRESS = ALU_result;
        DATA_OUT = id_ex_q.rs2;
        RDEN = id_ex_q.memRDEN;
        WE = id_ex_q.memWE;
    
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            ex_mem_q <= '0;
        end
        else begin
            ex_mem_q <= ex_mem_d;
        end
    end
   //===Memory Stage====
   //Simialr to the IMEM, vaddress, and signals will be waiting due to
   // the BRAM sync read, so this stage is just a buffer in here.
    //Nothing combinational realy happens in this stage, 
    //  The values are settled in EX/MEm and will read/wrtie on this posedge
  

    always_comb begin
        mem_wb_d.PC = ex_mem_q.PC;
        mem_wb_d.RF_WE = ex_mem_q.RF_WE;
        mem_wb_d.memWE = ex_mem_q.memWE;
        mem_wb_d.memRDEN = ex_mem_q.memRDEN;
        mem_wb_d.mem_sign = ex_mem_q.mem_sign;
        mem_wb_d.mem_size = ex_mem_q.mem_size;
        mem_wb_d.RF_SEL = ex_mem_q.RF_SEL;
        mem_wb_d.reg_write_addr = ex_mem_q.reg_write_addr;
    end
    assign
    always_ff @(posedge clk) begin
        if (reset) begin
            mem_wb_q <= '0;
        end
        else begin
            mem_wb_q <= mem_wb_d;
        end
    end

    //===Write back stage====

    //Same thing as DMEM, this data should be ready by pos edge trasnition into WB stage
    FOUR_TO_ONE_MUX reg_MUX(
        .A(ex_mem_q.PC + 4),
        .B('X),
        .C(IO_read_data), // should have come back from mem stage
        .D(ex_mem_q.ALU_result),
        .SEL(ex_mem_q.RF_SEL),
        .OUT(write_data)
    );