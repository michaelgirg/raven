`default_nettype none
// One parity bit for each byte of a bank word.
// Odd numbers of changed bits in a protected byte are detected, not corrected.
package raven_integrity_pkg;
    function automatic logic [15:0] byte_parity(input logic [127:0] data);
        for (int b = 0; b < 16; b++) byte_parity[b] = ^data[8*b +: 8];
    endfunction
endpackage
`default_nettype wire
