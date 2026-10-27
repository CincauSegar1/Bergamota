	.section .payload, "a"
	.balign 4096
	.globl _payload_start, _payload_end
_payload_start:
#if defined(EMBED_PAYLOAD)
	.incbin "out/payload.bin"
#endif
	.balign 4096
_payload_end:
