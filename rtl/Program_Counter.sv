
// Program_Counter (
//     .reset(),
//     .PC_SEL(),
//     .PC_PLUS_FOUR(),
//     .JALR_ADDR(),
//     .BRANCH_ADDR(),
//     .JAL_ADDR(),
//     .PC()
//     );

module Program_Counter(
    input reset,
    input [1:0] PC_SEL,
    input [31:0] PC_PLUS_FOUR,
    input [31:0] JALR_ADDR,
    input [31:0] BRANCH_ADDR,
    input [31:0] JAL_ADDR,
    output [31:0] PC
    )

    always_comb begin
        case(reset)
        1'b0: begin
            case(PC_SEL)
            2'b00: PC = PC_PLUS_FOUR;
            2'b01: PC = JALR_ADDR;
            2'b10: PC = BRANCH_ADDR;
            2'b11: PC = JAL;
            default:
                PC = 0';
        end
            
        1'b1:       PC = 0';
        default:    PC = 0';
        endcase
    end