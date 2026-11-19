extern int joltffi_dep_marker(void);
int joltffi_unloadable_probe(void) { return joltffi_dep_marker(); }
