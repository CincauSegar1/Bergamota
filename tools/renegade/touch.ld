
SECTIONS
{
  . = 0xfffffe0007581284;
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  /DISCARD/ : { *(.eh_frame*) *(.comment*) }
}
