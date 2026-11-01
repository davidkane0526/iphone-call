// Native arm64e iOS executable. Run only in a separate device process.
// It loads the diagnostic library and exercises only its synthetic self-test.
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "native_probe_library_load_failed\n");
        return 3;
    }
    unsigned int (*test)(void) = (unsigned int (*)(void))dlsym(library, "IFProbeSelfTest");
    if (!test) return 4;
    unsigned int result = test();
    printf("{\"native_arm64e_self_test\":%u}\n", result);
    return result == 1 ? 0 : 5;
}
