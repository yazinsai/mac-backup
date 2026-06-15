/*
 * Replay FSEvents since a stored event id. Prints JSON to stdout.
 * Usage: fsevents-changes <since_event_id> <path1> [path2...]
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char **paths;
    size_t count;
    size_t cap;
    int must_scan;
    int dropped;
    uint64_t max_id;
} CollectState;

static void ensure_cap(CollectState *st, size_t need) {
    if (st->count + need <= st->cap) return;
    st->cap = st->cap ? st->cap * 2 : 256;
    st->paths = realloc(st->paths, st->cap * sizeof(char *));
    if (!st->paths) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
}

static void add_path(CollectState *st, const char *path) {
    for (size_t i = 0; i < st->count; i++) {
        if (strcmp(st->paths[i], path) == 0) return;
    }
    ensure_cap(st, 1);
    st->paths[st->count++] = strdup(path);
}

static void fsevents_callback(
    ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]) {
    CollectState *st = (CollectState *)clientCallBackInfo;
    char **paths = (char **)eventPaths;

    for (size_t i = 0; i < numEvents; i++) {
        if (eventIds[i] > st->max_id) st->max_id = eventIds[i];
        if (eventFlags[i] & kFSEventStreamEventFlagMustScanSubDirs) st->must_scan = 1;
        if (eventFlags[i] & (kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped))
            st->dropped = 1;
        if (paths[i]) add_path(st, paths[i]);
    }
}

static void json_escape(const char *s, FILE *out) {
    fputc('"', out);
    for (const char *p = s; *p; p++) {
        if (*p == '"' || *p == '\\') fputc('\\', out);
        fputc(*p, out);
    }
    fputc('"', out);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "latest") == 0) {
        printf("%llu\n", (unsigned long long)FSEventsGetCurrentEventId());
        return 0;
    }

    if (argc < 3) {
        fprintf(stderr, "usage: %s latest\n", argv[0]);
        fprintf(stderr, "       %s <since_event_id> <path> [path...]\n", argv[0]);
        return 2;
    }

    uint64_t since = strtoull(argv[1], NULL, 10);
    CollectState st = {0};
    st.max_id = since;

    CFMutableArrayRef watch = CFArrayCreateMutable(NULL, argc - 2, &kCFTypeArrayCallBacks);
    for (int i = 2; i < argc; i++) {
        CFStringRef s = CFStringCreateWithCString(NULL, argv[i], kCFStringEncodingUTF8);
        CFArrayAppendValue(watch, s);
        CFRelease(s);
    }

    FSEventStreamContext ctx = {0, &st, NULL, NULL, NULL};
    FSEventStreamRef stream = FSEventStreamCreate(
        NULL,
        &fsevents_callback,
        &ctx,
        watch,
        since,
        0.0,
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);

    CFRelease(watch);
    if (!stream) {
        fprintf(stderr, "FSEventStreamCreate failed\n");
        return 1;
    }

    FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    if (!FSEventStreamStart(stream)) {
        fprintf(stderr, "FSEventStreamStart failed\n");
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
        return 1;
    }

    /* Drain historical replay */
    for (int i = 0; i < 50; i++) {
        SInt32 rc = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, true);
        if (rc == kCFRunLoopRunFinished || rc == kCFRunLoopRunStopped) break;
    }

    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);

    uint64_t latest = FSEventsGetCurrentEventId();
    if (st.max_id < latest) st.max_id = latest;

    printf("{\"new_event_id\":%llu,\"dropped\":%s,\"must_scan\":%s,\"changed_paths\":[",
           (unsigned long long)st.max_id,
           st.dropped ? "true" : "false",
           st.must_scan ? "true" : "false");
    for (size_t i = 0; i < st.count; i++) {
        if (i) printf(",");
        json_escape(st.paths[i], stdout);
    }
    printf("]}\n");

    for (size_t i = 0; i < st.count; i++) free(st.paths[i]);
    free(st.paths);
    return 0;
}
