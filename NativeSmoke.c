// Native arm64e iOS executable. Run only in a separate device process.
// It loads the diagnostic library and exercises only its synthetic self-test.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int wait_for_injection = argc == 3 && strcmp(argv[1], "--wait-for-injection") == 0;
    if (argc != 2 && !wait_for_injection) return 2;
    const char *path = argv[wait_for_injection ? 2 : 1];
    void *library = NULL;
    if (wait_for_injection) {
        // This mode never loads the library itself: it only detects a library
        // injected into this disposable, dedicated CLI process by the tester.
        puts("{\"native_arm64e_injection_target_ready\":true}");
        fflush(stdout);
        for (unsigned int attempt = 0; attempt < 600; ++attempt) {
            library = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
            if (library) break;
            usleep(100000);
        }
    } else {
        library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    }
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
