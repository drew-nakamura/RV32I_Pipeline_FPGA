`timescale 1ns / 1ps
package CPU_pkg;

//======ENUMS=======
typedef enum logic [5:0] {
    LUI, AUIPC, JAL, JALR, LB, LH, LW, LBU,
    LHU, ADDI, SLTI, SLTIU, ORI, XORI, ANDI, 
    SLLI, SRLI, SRAI, BEQ, BNE, BLT, BGE, BLTU,
    BGEU, SB, SH, SW, ADD, SUB, SLL, SLT, SLTU,
    XOR, SRL, SRA, OR, AND, UNKNOWN
} instr_name_e;

typedef enum logic [2:0]{
    FETCH = 3'b000,
    DECODE = 3'b001,
    EXECUTE = 3'b010,
    MEMORY = 3'b011,
    WRITE_BACK = 3'b100
} stage_e;

typedef enum logic [3:0] {
    alu_ADD = 4'b0000,
    alu_SUB = 4'b1000,
    alu_AND = 4'b0111,
    alu_OR = 4'b0110,
    alu_XOR = 4'b0100,
    alu_SLL = 4'b0001,
    alu_SRL = 4'b0101,
    alu_SRA = 4'b1101,
    alu_SLT = 4'b0010,
    alu_SLTU = 4'b0011,
    alu_LUI_COPY = 4'b1001
  } alu_op_e;

  typedef enum logic {
    srca_rs1 = 1'b0,
    srca_U_TYPE = 1'b1
  } srca_sel_e;

  typedef enum logic [1:0]{
    srcb_rs2 = 2'b00,
    srcb_I_TYPE = 2'b01,
    srcb_S_TYPE = 2'b10,
    srcb_PC = 2'b11
  } srcb_sel_e;

  typedef enum logic [1:0] {
    WB_PC4 = 2'b00,
    WB_CSR = 2'b01,
    WB_DATA_IN = 2'b10,
    WB_ALU = 2'b11
  } WB_sel_e;

  typedef enum logic [1:0] {
    pc_PC4 = 2'b00,
    pc_JALR = 2'b01,
    pc_BRANCH= 2'b10,
    pc_JAL = 2'b11
  } pc_sel_e;

//======Structures====

typedef struct packed {
    logic [31:0] PC;
    logic [2:0] func3;
    logic srcA_SEL;
    logic RF_WE;
    logic memWE;
    logic memRDEN;
    logic branch_i;
    logic jal_i;
    logic jalr_i;
    logic mem_sign;
    logic [1:0] mem_size;
    logic [1:0] srcB_SEL;
    logic [1:0] RF_SEL;
    logic [4:0] reg_write_addr;
    logic [3:0] ALU_FUN;
    logic [31:0] U_Type;
    logic [31:0] I_Type;
    logic [31:0] S_Type;
    logic [31:0] B_Type;
    logic [31:0] J_Type;
    logic [4:0] rs1_addr;
    logic [4:0] rs2_addr;
    logic [31:0] rs1;
    logic [31:0] rs2;
    instr_name_e instruction;
} id_ex_t;

typedef struct packed {
    logic [31:0] PC;
    logic RF_WE;
    logic memWE;
    logic memRDEN;
    logic mem_sign;
    logic [1:0] mem_size;
    logic [1:0] RF_SEL;
    logic [4:0] reg_write_addr;
    logic [31:0] ALU_result;
    logic [31:0] IO_write_data;
    instr_name_e instruction;
} ex_mem_t;

typedef struct packed {
    logic [31:0] PC;
    logic RF_WE;
    logic memWE;
    logic memRDEN;
    logic mem_sign;
    logic [1:0] mem_size;
    logic [1:0] RF_SEL;
    logic [4:0] reg_write_addr;
    logic [31:0] REG_write_data;
    instr_name_e instruction;
} mem_wb_t;

    //======Functions======
    function automatic instr_name_e decode_instr_name(input logic [31:0] ir);
        logic [6:0] opcode = ir[6:0];
        logic [2:0] funct3 = ir[14:12];
        logic [6:0] funct7 = ir[31:25];

        case (opcode)
            7'b0110111: decode_instr_name = LUI;
            7'b0010111: decode_instr_name = AUIPC;
            7'b1101111: decode_instr_name = JAL;
            7'b1100111: decode_instr_name = JALR;

            7'b0000011: case (funct3)
                3'b000: decode_instr_name = LB;
                3'b001: decode_instr_name = LH;
                3'b010: decode_instr_name = LW;
                3'b100: decode_instr_name = LBU;
                3'b101: decode_instr_name = LHU;
                default: decode_instr_name = UNKNOWN;
            endcase

            7'b0010011: case (funct3)
                3'b000: decode_instr_name = ADDI;
                3'b010: decode_instr_name = SLTI;
                3'b011: decode_instr_name = SLTIU;
                3'b110: decode_instr_name = ORI;
                3'b100: decode_instr_name = XORI;
                3'b111: decode_instr_name = ANDI;
                3'b001: decode_instr_name = SLLI;
                3'b101: begin
                    case (funct7)
                        7'b0000000: decode_instr_name = SRLI;
                        7'b0100000: decode_instr_name = SRAI;
                        default:    decode_instr_name = UNKNOWN;
                    endcase
                end
                default: decode_instr_name = UNKNOWN;
            endcase

            7'b1100011: case (funct3)
                3'b000: decode_instr_name = BEQ;
                3'b001: decode_instr_name = BNE;
                3'b100: decode_instr_name = BLT;
                3'b101: decode_instr_name = BGE;
                3'b110: decode_instr_name = BLTU;
                3'b111: decode_instr_name = BGEU;
                default: decode_instr_name = UNKNOWN;
            endcase

            7'b0100011: case (funct3)
                3'b000: decode_instr_name = SB;
                3'b001: decode_instr_name = SH;
                3'b010: decode_instr_name = SW;
                default: decode_instr_name = UNKNOWN;
            endcase

            7'b0110011: case (funct3)
                3'b000: decode_instr_name = (funct7 == 7'b0100000) ? SUB : ADD;
                3'b001: decode_instr_name = SLL;
                3'b010: decode_instr_name = SLT;
                3'b011: decode_instr_name = SLTU;
                3'b100: decode_instr_name = XOR;
                3'b101: decode_instr_name = (funct7 == 7'b0100000) ? SRA : SRL;
                3'b110: decode_instr_name = OR;
                3'b111: decode_instr_name = AND;
                default: decode_instr_name = UNKNOWN;
            endcase

            default: decode_instr_name = UNKNOWN;
        endcase
    endfunction
endpackage