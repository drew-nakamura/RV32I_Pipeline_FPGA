OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  /* Program_Counter resets to 0. IMEM fetches PC[14:2] (0x0000..0x7FFC). */
  . = 0x00000000;
  .text.init : { *(.text.init) }
  .text      : { *(.text) }
  ASSERT(. <= 0x3F60, "code overlaps data RAM at 0x3F60")

  /* DMEM is 2048 words, 0x3F60..0x5F5F.
     riscv_test.h aligns tohost to 64 bytes (.align 6).
     0x3F80 is the first 64-byte-aligned address inside that RAM. */
  . = 0x00003F80;
  .tohost : { *(.tohost) }
  .data   : { *(.data) }
  .bss    : { *(.bss) }
  ASSERT(. <= 0x5F60, "data ran past DMEM (last byte is 0x5F5F)")
  _end = .;
}
