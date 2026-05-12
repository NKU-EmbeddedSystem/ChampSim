# Build the mini test binary for functional tests.
# -no-pie ensures fixed addresses matching objdump output.
# -O0 prevents optimization that would elide loads/stores.
CFLAGS = -no-pie -O0

func_test_mini: func_test_mini.c
	gcc $(CFLAGS) -o $@ $<

clean:
	rm -f func_test_mini
