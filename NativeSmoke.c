// Diagnostic host and minimal loader. No phone numbers, keys or databases.
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef IF_STACK_STRESS_LIBRARY
static unsigned int IFStressResult;
__attribute__((noinline)) static unsigned int IFStressStack(void) {
    volatile unsigned char frame[128 * 1024];
    for (unsigned int i = 0; i < sizeof(frame); i += 4096) frame[i] = (unsigned char)(i / 4096);
    unsigned int result = 1;
    for (unsigned int i = 0; i < sizeof(frame); i += 4096)
        if (frame[i] != (unsigned char)(i / 4096)) result = 0;
    return result;
}
__attribute__((constructor)) static void IFStressStart(void) { IFStressResult = IFStressStack(); }
unsigned int IFProbeSelfTest(void) { return IFStressResult; }
#else
static unsigned int IFTestLibrary(const char *path) {
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) return 0;
    unsigned int (*test)(void) = (unsigned int (*)(void))dlsym(library, "IFProbeSelfTest");
    return test ? test() : 0;
}
struct IFThreadTest { const char *path; unsigned int result; };
static void *IFThreadMain(void *opaque) {
    struct IFThreadTest *test = opaque;
    test->result = IFTestLibrary(test->path);
    return NULL;
}
int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--thread-stack") == 0) {
        size_t size = (size_t)strtoul(argv[2], NULL, 10);
        if (size < 16384 || size > 8 * 1024 * 1024) return 2;
        pthread_attr_t attributes;
        if (pthread_attr_init(&attributes)) return 6;
        int error = pthread_attr_setstacksize(&attributes, size);
        struct IFThreadTest test = { argv[3], 0 };
        pthread_t thread;
        if (!error) error = pthread_create(&thread, &attributes, IFThreadMain, &test);
        pthread_attr_destroy(&attributes);
        if (error || pthread_join(thread, NULL)) return 6;
        printf("{\"native_arm64e_self_test\":%u,\"requested_thread_stack\":%zu}\n", test.result, size);
        return test.result == 1 ? 0 : 5;
    }
    int wait_for_injection = argc == 3 && strcmp(argv[1], "--wait-for-injection") == 0;
    if (argc != 2 && !wait_for_injection) return 2;
    const char *path = argv[wait_for_injection ? 2 : 1];
    if (wait_for_injection) {
        puts("{\"native_arm64e_injection_target_ready\":true}");
        fflush(stdout);
        void *library = NULL;
        for (unsigned int attempt = 0; attempt < 600; ++attempt) {
            library = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
            if (library) break;
            usleep(100000);
        }
        if (!library) return 3;
    }
    unsigned int result = IFTestLibrary(path);
    printf("{\"native_arm64e_self_test\":%u}\n", result);
    return result == 1 ? 0 : 5;
}
#endif
