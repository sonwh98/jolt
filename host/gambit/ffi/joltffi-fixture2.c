/* joltffi-fixture2.c — the duplicate-symbol fixture (P1b-stage1 loader smoke).
 *
 * Exports the SAME symbol as joltffi-fixture.c (joltffi_fx_dup_symbol) with a
 * DIFFERENT return value, so the gate can pin the duplicate-definers
 * detection: two distinct ADDRESSES across two declared libraries, resolved
 * against the first in declaration order (issue #731 semantics).
 */

int joltffi_fx_dup_symbol (void) { return 222; }
