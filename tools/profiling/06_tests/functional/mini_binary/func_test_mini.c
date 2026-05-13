/*
 * Mini functional test binary for profiling pipeline.
 *
 * Contains controlled loads, stores, and lea to verify
 * that parse_disassembly correctly distinguishes them.
 *
 * Compiled with: gcc -no-pie -O0 -o func_test_mini func_test_mini.c
 *
 * func_a: simple load via pointer dereference (mov from [reg])
 * func_b: load into local variable (mov from [reg])
 * func_c: read-modify-write (load + store)
 * func_d: pure store (mov to [reg]) — should NOT be classified as load
 * func_e: uses lea (address computation) — should NOT be classified as load
 * main:   calls all functions
 */

int func_a(int *p) {
    return *p + 1;             /* LOAD: mov eax, [rdi] */
}

int func_b(int *p) {
    int x = *p;                /* LOAD: mov eax, [rdi] */
    return x;
}

int func_c(int *p) {
    return (*p)++;              /* LOAD + STORE */
}

int func_d(int *p) {
    *p = 42;                    /* STORE only: mov [rdi], 42 */
    return 0;
}

int func_e(int *p) {
    int *q = p;                 /* lea or mov reg,reg — no memory access */
    return (long)q;
}

int main(void) {
    int x = 1;
    func_a(&x);
    func_b(&x);
    func_c(&x);
    func_d(&x);
    func_e(&x);
    return x;
}
