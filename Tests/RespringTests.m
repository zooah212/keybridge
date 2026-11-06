// Data-only regression cases. No preferences, filesystem writes or process actions.
// This subtask only syntax-checks this file; running it needs a later authorized
// native test build (and signing). Do not mistake syntax checks for runtime tests.
#import "../Injector/KBRespring.h"
#include <assert.h>

static NSString *const Session = @"10000000-0000-0000-0000-000000000000";
static NSString *const Nonce = @"20000000-0000-0000-0000-000000000000";
static NSString *const Other = @"30000000-0000-0000-0000-000000000000";

static NSMutableDictionary *Request(void) {
    return [@{@"version": @1, @"action": @2, @"id": Other,
        @"session": Session, @"nonce": Nonce, @"createdAt": @1005} mutableCopy];
}
static NSString *Check(id request) {
    return KBRespringRequestFailure(request, Session, Nonce, 1000, 100, 1005, 105);
}

int main(void) {
    @autoreleasepool {
        assert(Check(Request()) == nil);
        assert(Check(nil) != nil);
        assert(Check(@[]) != nil);
        NSMutableDictionary *request = Request();
        request[@"command"] = @"anything";
        assert(Check(request) != nil); // Extra fields cannot smuggle a command.
        request = Request(); request[@"path"] = @"/tmp/anything";
        assert(Check(request) != nil);
        request = Request(); request[@"action"] = @1;
        assert(Check(request) != nil);
        request = Request(); request[@"action"] = @1.5;
        assert(Check(request) != nil);
        request = Request(); request[@"action"] = @YES;
        assert(Check(request) != nil);
        request = Request(); request[@"version"] = @2;
        assert(Check(request) != nil);
        request = Request(); request[@"id"] = @"invalid";
        assert(Check(request) != nil);
        request = Request(); request[@"id"] = @"ABCDEF00-0000-0000-0000-000000000000";
        assert(Check(request) == nil);
        request[@"id"] = [request[@"id"] lowercaseString];
        assert(Check(request) != nil); // Reject a second spelling of the same ID.
        request = Request(); [request removeObjectForKey:@"createdAt"];
        assert(Check(request) != nil);
        request = Request(); request[@"createdAt"] = @"1005";
        assert(Check(request) != nil);
        request = Request(); request[@"createdAt"] = @(NAN);
        assert(Check(request) != nil);
        request = Request(); request[@"createdAt"] = @1006;
        assert(Check(request) != nil); // Future date.
        request = Request(); request[@"createdAt"] = @999;
        assert(Check(request) != nil); // Before this challenge was issued.
        assert(KBRespringRequestFailure(Request(), Other, Nonce, 1000, 100, 1005, 105) != nil);
        assert(KBRespringRequestFailure(Request(), Session, Other, 1000, 100, 1005, 105) != nil);
        assert(KBRespringRequestFailure(Request(), Session, nil, 1000, 100, 1005, 105) != nil);
        assert(KBRespringRequestFailure(Request(), Session, Nonce, 1000, 100, 1015, 115) == nil);
        assert(KBRespringRequestFailure(Request(), Session, Nonce, 1000, 100, 1015.001, 115) != nil);
        request = Request(); request[@"createdAt"] = @1030;
        assert(KBRespringRequestFailure(request, Session, Nonce, 1000, 100, 1030, 130) == nil);
        assert(KBRespringRequestFailure(request, Session, Nonce, 1000, 100, 1030.001, 130) != nil);
        assert(KBRespringRequestFailure(Request(), Session, Nonce, 1000, 100, 1005, 131) != nil);
        assert(KBRespringRequestFailure(Request(), Session, Nonce, 1000, 100, 1005, 99) != nil);
        assert(KBRespringRequestFailure(Request(), Session, Nonce, 1000, 100, 999, 105) != nil);

        NSDictionary *importKeys = @{@"pendingZipAt": @"zipAt", @"convertRequest": @"convertAt",
            @"switchAt": @"switchAt", @"deleteAt": @"deleteAt", @"renameAt": @"renameAt",
            @"excludeAt": @"excludeAt", @"customAt": @"customAt", @"disableAt": @"disableAt",
            @"scanAt": @"scanAt", @"downloadAt": @"downloadAt"};
        assert(!KBRespringHasPendingLibraryCommand(@{}, @{}));
        for (NSString *key in importKeys) {
            assert(KBRespringHasPendingLibraryCommand(@{key: @10}, @{}));
            assert(!KBRespringHasPendingLibraryCommand(@{key: @10}, @{importKeys[key]: @10}));
            assert(KBRespringHasPendingLibraryCommand(@{key: @10}, @{importKeys[key]: @9}));
            assert(KBRespringHasPendingLibraryCommand(@{key: @"10"}, @{}));
        }
        assert(KBRespringHasPendingLibraryCommand(@{}, @{@"zipAt": @(INFINITY)}));

        NSMutableDictionary *state = [@{@"version": @1, @"session": Session, @"nonce": Nonce,
            @"issuedAt": @1000, @"expiresAt": @1030, @"updatedAt": @1004, @"ready": @YES} mutableCopy];
        assert(KBRespringStateFailure(state, 1005) == nil);
        assert(KBRespringStateFailure(nil, 1005) != nil);
        assert(KBRespringStateFailure(state, 1003) != nil);
        assert(KBRespringStateFailure(state, 1011) != nil);
        state[@"updatedAt"] = @1030;
        assert(KBRespringStateFailure(state, 1030) != nil);
        state[@"updatedAt"] = @1004; state[@"ready"] = @NO;
        assert(KBRespringStateFailure(state, 1005) != nil);
        state[@"ready"] = @YES; state[@"nonce"] = @"";
        assert(KBRespringStateFailure(state, 1005) != nil);
    }
    return 0;
}
