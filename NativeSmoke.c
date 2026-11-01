// Diagnostic host and minimal loader. No phone numbers, keys or databases.
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef IF_BOOTSTRAP_LIBRARY
#include <stdatomic.h>
#include <fcntl.h>
#include <sys/stat.h>
#ifndef IF_PROBE_TARGET_PATH
#error A fixed target path is required
#endif

static _Atomic unsigned int IFLoadResult;
static void IFRecord(const char *phase, size_t stack_size) {
    struct stat parent;
    if (lstat("/var/mobile/Library/iPhoneForward", &parent) ||
        !S_ISDIR(parent.st_mode) || parent.st_uid != geteuid() ||
        (parent.st_mode & 0077)) return;
    int fd = open("/var/mobile/Library/iPhoneForward/ringing-bootstrap-status.jsonl",
                  O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != geteuid() ||
        (info.st_mode & 0077) || info.st_size > 65536) { close(fd); return; }
    char line[256];
    int size = snprintf(line, sizeof(line),
        "{\"phase\":\"%s\",\"stack_size\":%zu,\"process_id\":%d}\n",
        phase, stack_size, getpid());
    if (size > 0 && (size_t)size < sizeof(line)) write(fd, line, (size_t)size);
    close(fd);
}

static void *IFLoadOnNormalThread(void *unused) {
    size_t stack = pthread_get_stacksize_np(pthread_self());
    IFRecord("normal_thread_started", stack);
    void *library = dlopen(IF_PROBE_TARGET_PATH, RTLD_NOW | RTLD_LOCAL);
    unsigned int result = library ? 1 : 0;
    const char *fixture = getenv("IF_BOOTSTRAP_SYNTHETIC_SELFTEST");
    if (library && fixture && strcmp(fixture, "1") == 0) {
        unsigned int (*test)(void) = (unsigned int (*)(void))dlsym(library, "IFProbeSelfTest");
        result = test ? test() : 0;
    }
    IFRecord(result ? "payload_loaded" : "payload_load_failed", stack);
    atomic_store_explicit(&IFLoadResult, result ? 1 : 2, memory_order_release);
    return NULL;
}

__attribute__((constructor)) static void IFBootstrapStart(void) {
    // Never wait for dyld/Objective-C work while its loader lock is held here.
    pthread_attr_t attributes;
    if (pthread_attr_init(&attributes)) return;
    int error = pthread_attr_setstacksize(&attributes, 1024 * 1024);
    if (!error) error = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    if (!error) error = pthread_create(&thread, &attributes, IFLoadOnNormalThread, NULL);
    pthread_attr_destroy(&attributes);
    if (error) atomic_store_explicit(&IFLoadResult, 2, memory_order_release);
}

unsigned int IFProbeSelfTest(void) {
    for (unsigned int i = 0; i < 400; ++i) {
        unsigned int result = atomic_load_explicit(&IFLoadResult, memory_order_acquire);
        if (result) return result == 1 ? 1 : 0;
        usleep(25000);
    }
    return 0;
}
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
