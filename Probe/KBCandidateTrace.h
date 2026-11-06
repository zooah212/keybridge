// Include once from KeyBridgeProbe.m. Diagnostic only; no candidate refresh calls.
#pragma once
#ifndef KB_CANDIDATE_TRACE
#define KB_CANDIDATE_TRACE 0
#endif

#import <objc/runtime.h>

#if KB_CANDIDATE_TRACE
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <os/log.h>
#include <stdatomic.h>
#include <pthread.h>
#include <string.h>
#include <time.h>

#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "unknown"
#endif

// A single 15-second window, at most 256 events; never reuses a slot.
// No strings, candidate objects, keyboard states or object addresses are recorded.
enum { KBCTCapacity = 256 };
typedef enum {
    KBCTGenerateEnter = 1, KBCTGenerateLeave,
    KBCTCompletionEnter, KBCTCompletionLeave,
    KBCTOpenEnter, KBCTOpenLeave, KBCTCloseEnter, KBCTCloseLeave
} KBCTEvent;
typedef struct {
    uint64_t time, request, thread;
    unsigned event;
    int detail;
    BOOL main;
} KBCTRow;
static KBCTRow KBCTRows[KBCTCapacity];
static _Atomic(bool) KBCTReady[KBCTCapacity];
static _Atomic(bool) KBCTAccepting;
static _Atomic(bool) KBCTStarted;
static _Atomic(unsigned) KBCTNextSlot;
static _Atomic(uint64_t) KBCTNextRequest;
// Only a synchronous scope, NOT a persistent manager/request association.
static _Thread_local uint64_t KBCTScope;
static IMP KBCTOriginalGenerate, KBCTOriginalOpen, KBCTOriginalClose;
static os_log_t KBCTLog;
static dispatch_queue_t KBCTExportQueue;
static uint64_t KBCTStart;

static void KBCTRecord(KBCTEvent event, uint64_t request, int detail) {
    if (!atomic_load_explicit(&KBCTAccepting, memory_order_relaxed) ||
        !atomic_load_explicit(&KBCTStarted, memory_order_acquire)) return;
    unsigned slot = atomic_fetch_add_explicit(&KBCTNextSlot, 1, memory_order_relaxed);
    if (slot >= KBCTCapacity) return;
    uint64_t thread = 0;
    pthread_threadid_np(NULL, &thread);
    KBCTRows[slot] = (KBCTRow){
        .time = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), .request = request,
        .thread = thread, .event = event, .detail = detail, .main = pthread_main_np() != 0
    };
    atomic_store_explicit(&KBCTReady[slot], true, memory_order_release);
}

static void KBCTExport(void) {
    atomic_store_explicit(&KBCTAccepting, false, memory_order_relaxed);
    unsigned reserved = atomic_load_explicit(&KBCTNextSlot, memory_order_relaxed);
    unsigned count = MIN(reserved, (unsigned)KBCTCapacity), emitted = 0;
    os_log(KBCTLog, "trace begin build=%{public}s capacity=%u", APELIN_BUILD_ID, KBCTCapacity);
    for (unsigned i = 0; i < count; i++) {
        // A slow in-flight writer is skipped, never waited for or raced.
        if (!atomic_load_explicit(&KBCTReady[i], memory_order_acquire)) continue;
        KBCTRow row = KBCTRows[i];
        os_log(KBCTLog, "trace slot=%u us=%llu request=%llu thread=%llu main=%d event=%u detail=%d",
               i, (unsigned long long)((row.time - KBCTStart) / 1000),
               (unsigned long long)row.request, (unsigned long long)row.thread,
               row.main, row.event, row.detail);
        emitted++;
    }
    os_log(KBCTLog, "trace end emitted=%u overflow=%u unfinished=%u",
           emitted, reserved > KBCTCapacity ? reserved - KBCTCapacity : 0, count - emitted);
}

static void KBCTStartWindow(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        KBCTStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        atomic_store_explicit(&KBCTStarted, true, memory_order_release);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), KBCTExportQueue, ^{
            KBCTExport();
        });
    });
}

static void KBCTGenerate(id self, SEL cmd, id state, NSRange range, void (^completion)(id)) {
    void (*original)(id, SEL, id, NSRange, void (^)(id)) = (void *)KBCTOriginalGenerate;
    if (!atomic_load_explicit(&KBCTAccepting, memory_order_relaxed)) {
        original(self, cmd, state, range, completion);
        return;
    }
    KBCTStartWindow();
    uint64_t request = atomic_fetch_add_explicit(&KBCTNextRequest, 1, memory_order_relaxed) + 1;
    uint64_t previous = KBCTScope;
    KBCTScope = request;
    KBCTRecord(KBCTGenerateEnter, request, completion != nil);
    // Preserve nil and call the original completion only when Apple calls us.
    // This wrapper changes block identity/lifetime; it is diagnostic, not transparent.
    void (^observed)(id) = nil;
    if (completion) observed = ^(id result) {
        uint64_t saved = KBCTScope;
        KBCTScope = request;
        KBCTRecord(KBCTCompletionEnter, request, 0);
        @try { completion(result); }
        @finally {
            KBCTRecord(KBCTCompletionLeave, request, 0);
            KBCTScope = saved;
        }
    };
    @try { original(self, cmd, state, range, observed); }
    @finally {
        KBCTRecord(KBCTGenerateLeave, request, 0);
        KBCTScope = previous;
    }
}

static void KBCTOpen(id self, SEL cmd, void (^completion)(id)) {
    KBCTRecord(KBCTOpenEnter, KBCTScope, completion != nil);
    @try { ((void (*)(id, SEL, void (^)(id)))KBCTOriginalOpen)(self, cmd, completion); }
    @finally { KBCTRecord(KBCTOpenLeave, KBCTScope, 0); }
}

static BOOL KBCTClose(id self, SEL cmd, id results) {
    KBCTRecord(KBCTCloseEnter, KBCTScope, 0);
    BOOL closed = ((BOOL (*)(id, SEL, id))KBCTOriginalClose)(self, cmd, results);
    KBCTRecord(KBCTCloseLeave, KBCTScope, closed);
    return closed;
}

static BOOL KBCTSignature(Class cls, SEL selector, const char *result,
                          const char *const *arguments, NSUInteger count) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!signature || strcmp(signature.methodReturnType, result) || signature.numberOfArguments != count) return NO;
    for (NSUInteger i = 0; i < count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i], arguments[i])) return NO;
    }
    return YES;
}

// Call only after the Pinyin class and hook function are available. No constructor.
static void KBCandidateTraceInstall(void (*hook)(Class, SEL, IMP, IMP *), Class pinyinClass) {
    if (!hook || !pinyinClass) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        KBCTLog = os_log_create("com.wm0104.keybridge.probe", "candidate-trace");
        SEL generate = NSSelectorFromString(@"generateCandidatesWithKeyboardState:candidateRange:completionHandler:");
        SEL open = NSSelectorFromString(@"openCandidateGenerationContextWithCompletionHandler:");
        SEL close = NSSelectorFromString(@"closeCandidateGenerationContextWithResults:");
        const char *generateArgs[] = {"@", ":", "@", @encode(NSRange), "@?"};
        const char *openArgs[] = {"@", ":", "@?"};
        const char *closeArgs[] = {"@", ":", "@"};
        if (!KBCTSignature(pinyinClass, generate, "v", generateArgs, 5) ||
            !KBCTSignature(pinyinClass, open, "v", openArgs, 3) ||
            !KBCTSignature(pinyinClass, close, @encode(BOOL), closeArgs, 3)) {
            os_log(KBCTLog, "trace refused: missing method or ABI mismatch build=%{public}s", APELIN_BUILD_ID);
            return;
        }
        KBCTExportQueue = dispatch_queue_create("com.wm0104.keybridge.candidate-trace",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        // Activate only after all original IMP slots have been populated.
        hook(pinyinClass, open, (IMP)KBCTOpen, &KBCTOriginalOpen);
        hook(pinyinClass, close, (IMP)KBCTClose, &KBCTOriginalClose);
        hook(pinyinClass, generate, (IMP)KBCTGenerate, &KBCTOriginalGenerate);
        atomic_store_explicit(&KBCTAccepting, true, memory_order_relaxed);
        os_log(KBCTLog, "trace armed build=%{public}s window=15 capacity=256", APELIN_BUILD_ID);
    });
}
#else
// Macro 0 compiles no diagnostic storage, hooks, logging, timers or network code.
static inline void KBCandidateTraceInstall(void (*hook)(Class, SEL, IMP, IMP *), Class pinyinClass) {
    (void)hook;
    (void)pinyinClass;
}
#endif
