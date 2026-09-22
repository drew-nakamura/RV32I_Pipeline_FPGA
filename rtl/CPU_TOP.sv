`timescale 1ns / 1ps
// CPU_TOP (
//     .RST(),
//     .CLK(),
//     .DATA_IN(),
//     .DATA_ADDRESS(),
//     .DATA_OUT(),
//     .RDEN(),
//     .WE()
//     );
import CPU_pkg::*;


module CPU_TOP(
    input logic RST,
    input logic CLK,
    input logic [31:0] DATA_IN,
    output logic [2:0] mem_data,
    output logic [31:0] DATA_ADDRESS,
    output logic [31:0] DATA_OUT,
    output logic IOBUS_RDEN,
    output logic IOBUS_WE
    );

    //===Structs====
    if_id_t if_id_d;
    if_id_t if_id_q;
    id_ex_t id_ex_d;  // Next value
    id_ex_t id_ex_q;  // Registered/current value 
    ex_mem_t ex_mem_d;
    ex_mem_t ex_mem_q;
    mem_wb_t mem_wb_d;
    mem_wb_t mem_wb_q;

    //====ENUMS=====
    instr_name_e instruction;

    //===CPU WIRE/BUFFERS===
    logic reset;
    
    //===PC Wires===
    logic [31:0] PC;

    //===IMEM Wires==
    logic [31:0] ir;
    logic [31:0] PC_USED;

    //==Reg File Wires===
    logic [31:0] rs1, rs2, write_data;

    //===Control Unit Wires===
    logic srcA_SEL, RF_WE, memWE, memRDEN, branch_i, jal_i, jalr_i;
    logic [1:0] srcB_SEL;
    logic [1:0] RF_SEL;
    logic [3:0] ALU_FUN;
    logic rs1_used;
    logic rs2_used;

    //===Branch Cond Gen Wires===
    logic br_lt, br_eq, br_ltu;

    //===PC Decoder Wires===
    logic [1:0] PC_SEL;
    logic [31:0] jalr, branch, jal;

    //===Immediate Generator Wires===
    logic [31:0] U_Type, I_Type, S_Type, B_Type, J_Type;

    //===ALU WIRES====
    logic [31:0] srcA, srcB, ALU_out;
    logic [31:0] srcA_REAL, srcB_REAL;
    logic [31:0] ALU_result;

    //===HAZARD WIRES===
    logic FORW_FLUSH_EX_MEM, FORW_STALL_ID_EX, FORW_STALL_IF_ID;
    logic Hazard_FLUSH_IF_ID, Hazard_FLUSH_ID_EX;
    logic [1:0] srcA_FORWARD_SEL, srcB_FORWARD_SEL;

    //========== FETCH ===============================
    Program_Counter Program_Counter(
        .reset(RST),
        .PC_SEL(PC_SEL), //Comes from EX stage
        .PC_PLUS_FOUR(PC_USED + 4),//smacked in from IMEM, as the latch will be the same as the insturciton
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
    assign instruction = decode_instr_name(ir);

    always_comb begin
        if_id_d.PC = PC;// latch will aligh with ir, if PC_USEd is dont then it will be a cycle behind
        if_id_d.ir = ir;
        if_id_d.instruction = instruction;
    end

    always_ff @(posedge CLK) begin
        if (RST || Hazard_FLUSH_IF_ID) begin
            if_id_q <= '0;
        end
        else if (FORW_STALL_IF_ID) begin
            if_id_q <= if_id_q;
        end
        else begin
            if_id_q <= if_id_d;
        end
    end
    //========== DECODE ===============================
    
   //ASSUME ALL REGISTERS OTHER THAN x0 are JUNK AT START!!!!
    REG_FILE REG_FILE(
        .CLK(CLK),
        .en(ex_mem_q.RF_WE),      
        .adr1(ir[19:15]),   
        .adr2(ir[24:20]),    
        .w_adr(ex_mem_q.reg_write_addr),  
        .w_data(write_data),  
        .rs1(rs1),  //ID
        .rs2(rs2)   //ID
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
        .ALU_FUN(ALU_FUN),
        .rs1_used(rs1_used),
        .rs2_used(rs2_used)
    );

    Immediate_Generator Immediate_Generator(
        .imm(ir[31:7]),
        .U_TYPE(U_Type),
        .I_TYPE(I_Type),
        .S_TYPE(S_Type),
        .B_TYPE(B_Type),
        .J_TYPE(J_Type)
    );

    always_comb begin
        id_ex_d.PC = if_id_q.PC;
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
        id_ex_d.rs1_addr = ir[19:15];
        id_ex_d.rs2_addr = ir[24:20];
        id_ex_d.rs1 = rs1;
        id_ex_d.rs2 = rs2;
        id_ex_d.rs1_used = rs1_used;
        id_ex_d.rs2_used = rs2_used;
        id_ex_d.instruction = if_id_q.instruction;
    end

    always_ff @(posedge CLK) begin
        if (RST || Hazard_FLUSH_ID_EX) begin
            id_ex_q <= '0;
        end
        else if (FORW_STALL_ID_EX) begin
            id_ex_q <= id_ex_q;
        end
        else if (FORW_STALL_ID_EX) begin
            //If we dont stall EX but ID stalls, this shouldnt really get anything.
            //This should really do anything bad, but if some weird stuff happens its probably from this
            id_ex_q <= '0; //
        end
        else begin
            id_ex_q <= id_ex_d;
        end
    end

//=========EX STAGE ========================
    Branch_Condition_Generator Branch_Condition_Generator(
        .rs1(srcA_REAL),
        .rs2(srcB_REAL),
        .br_lt(br_lt),
        .br_eq(br_eq),
        .br_ltu(br_ltu)
    );

    PC_Decoder PC_Decoder(
        .br_lt(br_lt),
        .br_eq(br_eq),
        .br_ltu(br_ltu),
        .branch_i(id_ex_q.branch_i),
        .jal_i(id_ex_q.jal_i),
        .jalr_i(id_ex_q.jalr_i),
        .func3(id_ex_q.func3),
        .PC_SEL(PC_SEL)
    );

    Jump_Branch_Address_Generator Jump_Branch_Address_Generator(
        .PC(id_ex_q.PC),
        .J_Type(id_ex_q.J_Type),
        .B_Type(id_ex_q.B_Type),
        .I_Type(id_ex_q.I_Type),
        .rs1(srcA_REAL), //GET THE FORWARDED RS1 
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

    FOUR_TO_ONE_MUX Forwarding_srcA_MUX(
       .A(srcA),
       .B(ex_mem_q.ALU_result),
       .C(mem_wb_q.REG_write_data),
       .D('0),
       .SEL(srcA_FORWARD_SEL),
       .OUT(srcA_REAL)
    );

    FOUR_TO_ONE_MUX srcB_MUX(
        .A(id_ex_q.rs2),
        .B(id_ex_q.I_Type),
        .C(id_ex_q.S_Type),
        .D(id_ex_q.PC),
        .SEL(id_ex_q.srcB_SEL),
        .OUT(srcB)
   );

   FOUR_TO_ONE_MUX Forwarding_srcB_MUX(
       .A(srcB),
       .B(ex_mem_q.ALU_result),
       .C(mem_wb_q.REG_write_data),
       .D('0),
       .SEL(srcB_FORWARD_SEL),
       .OUT(srcB_REAL)
    );

   ALU Arithmatic_Logical_Unit(
        .srcA(srcA_REAL),
        .srcB(srcB_REAL),
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
        ex_mem_d.mem_size = id_ex_q.mem_size;
        ex_mem_d.mem_sign = id_ex_q.mem_sign;
        ex_mem_d.memRDEN = id_ex_q.memRDEN;
        ex_mem_d.memWE = id_ex_q.memWE;
        mem_data = {id_ex_q.mem_size, id_ex_q.mem_sign};
        DATA_ADDRESS = ALU_result;
        DATA_OUT = srcB_REAL; //Shold only be valid data when rs2 is used... forwarded or not... but defiently could be buggy so!!!!!!!
        IOBUS_RDEN = id_ex_q.memRDEN;
        IOBUS_WE = id_ex_q.memWE;
        ex_mem_d.instruction = id_ex_q.instruction;
    end

    always_ff @(posedge CLK) begin
        if (RST) begin
            ex_mem_q <= '0;
        end
        else if (FORW_FLUSH_EX_MEM) begin
            //Like the earlier one, if EX stalls then mem shouldnt really update, 
            // and i dont really wanna add a valid bit for this so we just gonna 
            // make it 0.
            ex_mem_q <= '0;
        end else begin
            ex_mem_q <= ex_mem_d;
        end
    end
   //===Memory Stage====
   //Simialr to the IMEM, vaddress, and signals will be waiting due to
    //the BRAM sync read, so this stage is just a buffer in here.
    //Nothing combinational realy happens in this stage, 
    //The values are settled in EX/MEm and will read/wrtie on this posedge
  

    always_comb begin
        mem_wb_d.PC = ex_mem_q.PC;
        mem_wb_d.RF_WE = ex_mem_q.RF_WE;
        mem_wb_d.memWE = ex_mem_q.memWE;
        mem_wb_d.memRDEN = ex_mem_q.memRDEN;
        mem_wb_d.mem_sign = ex_mem_q.mem_sign;
        mem_wb_d.mem_size = ex_mem_q.mem_size;
        mem_wb_d.RF_SEL = ex_mem_q.RF_SEL;
        mem_wb_d.reg_write_addr = ex_mem_q.reg_write_addr;
        mem_wb_d.instruction = ex_mem_q.instruction;
        mem_wb_d.REG_write_data = write_data;
    end

    always_ff @(posedge CLK) begin
        if (RST) begin
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
        .C(DATA_IN), // should have come back from mem stage
        .D(ex_mem_q.ALU_result),
        .SEL(ex_mem_q.RF_SEL),
        .OUT(write_data)
    );

    //=====================Hazard Units========================
    Forwarding_Unit Forwarding_Unit(
        .EX_RS1_READ_ADDR(id_ex_q.rs1_addr),
        .EX_RS2_READ_ADDR(id_ex_q.rs2_addr),
        .EX_RS1_Used(id_ex_q.rs1_used),
        .EX_RS2_Used(id_ex_q.rs2_used),
        .MEM_REG_WRITE_ADDR(ex_mem_q.reg_write_addr),
        .WB_REG_WRITE_ADDR(mem_wb_q.reg_write_addr),
        .MEM_REG_WE(ex_mem_q.RF_WE),
        .MEM_DMEM_RDEN(ex_mem_q.memRDEN),
        .WB_DMEM_RDEN(mem_wb_q.memRDEN),
        .WB_REG_WE(mem_wb_q.RF_WE),
        .FLUSH_EX_MEM(FORW_FLUSH_EX_MEM),//THis flushes the next write of data, not what is currently in EX/MEM reg
        .STALL_IF_ID(FORW_STALL_IF_ID),
        .STALL_ID_EX(FORW_STALL_ID_EX),
        .srcA_FORWARD_SEL(srcA_FORWARD_SEL),
        .srcB_FORWARD_SEL(srcB_FORWARD_SEL)
    );
    //If custom insturciton is added, ensure we dont accidently forward/hazard because of rs1 rs2 stuff.

    //And now thinking about the x0 thing, we could literally ignore the latency thing if its written to x0,
    // and with x0 commonly being used to do nothing or some other sutff, this could portentialy save many
    // clock cycles. SO note to self to fix this later!

    HazardUnit Hazard_Unit(
        .branch_i(id_ex_q.branch_i),
        .jal_i(id_ex_q.jal_i),
        .jalr_i(id_ex_q.jalr_i),
        .PC_SEL(PC_SEL),
        .Hazard_FLUSH_IF_ID(Hazard_FLUSH_IF_ID),
        .Hazard_FLUSH_ID_EX(Hazard_FLUSH_ID_EX)
    );

endmodule