.global _fltused
.section .rdata,"dr"
_fltused:
    .long 0x9875

.text
.weak __chkstk
.global __chkstk
__chkstk:
    jmp ___chkstk_ms

.weak __extendhfsf2
.global __extendhfsf2
.weak __gnu_h2f_ieee
.global __gnu_h2f_ieee
__extendhfsf2:
__gnu_h2f_ieee:
    vmovd %ecx, %xmm0
    vcvtph2ps %xmm0, %xmm0
    ret

.weak __truncsfhf2
.global __truncsfhf2
.weak __gnu_f2h_ieee
.global __gnu_f2h_ieee
__truncsfhf2:
__gnu_f2h_ieee:
    vcvtps2ph $0, %xmm0, %xmm0
    vmovd %xmm0, %eax
    ret
