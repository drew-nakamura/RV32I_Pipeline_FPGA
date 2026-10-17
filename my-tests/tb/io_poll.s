# Board poll loop.  Assembled for IMEM at 0, I/O at 0x1100_0000.
# Switches -> seven-seg (hex).  Any button bit -> all 16 LEDs.
#
# Wrapper today only puts BTNC2 in bit 0 of the button word; BTNC is reset.
# If you OR BTNU/BTND/BTNL/BTNR into 0x11000080, this same loop covers all of
# them -- it only tests "word != 0".
#
#   riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 tb/io_poll.s -o io_poll.o
#   riscv64-unknown-elf-objcopy -O verilog io_poll.o sw/io_poll.mem
#   (or dump 32-bit words, one per line, no @address records)

    .equ SWITCHES, 0x11000000
    .equ LEDS,     0x11000020
    .equ SSEG,     0x11000040
    .equ BUTTONS,  0x11000080

    .text
    .globl _start
_start:
    lui  x11, %hi(SWITCHES)
    addi x12, x11, 0x20
    addi x13, x11, 0x40
    addi x14, x11, 0x80

loop:
    lw   x5, 0(x11)
    nop
    nop
    sw   x5, 0(x13)

    lw   x6, 0(x14)
    nop
    nop
    beq  x6, x0, leds_off
    lui  x7, 0x10
    addi x7, x7, -1
    sw   x7, 0(x12)
    jal  x0, loop

leds_off:
    sw   x0, 0(x12)
    jal  x0, loop
