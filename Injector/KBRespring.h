// Shared, data-only protocol for the Settings -> root daemon respring request.
#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

static NSString *const KBRespringRequestKey = @"respringRequest";
static NSString *const KBRespringStateFile = @"respring-state.json";
static const char *const KBRespringNotification = "com.wm0104.keybridge.respring-request";
static const NSTimeInterval KBRespringRequestLifetime = 10.0;
static const NSTimeInterval KBRespringChallengeLifetime = 30.0;
static const NSTimeInterval KBRespringHeartbeatLifetime = 6.0;

typedef NS_ENUM(NSInteger, KBRespringAction) {
    KBRespringActionReloadDesktop = 2,
};

static inline BOOL KBRespringNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]);
}

static inline BOOL KBRespringUUID(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 36) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
    // NSUUID.UUIDString is canonical uppercase; one UUID must not have two seen-ID keys.
    return uuid != nil && [uuid.UUIDString isEqualToString:value];
}

// Nonce authority belongs to the running daemon; published values are never restored.
// Both clocks are checked: changing wall time cannot extend a challenge's life.
static inline NSString *KBRespringRequestFailure(id value, NSString *session, NSString *nonce,
        NSTimeInterval issuedAt, NSTimeInterval issuedUptime,
        NSTimeInterval now, NSTimeInterval uptime) {
    if (![value isKindOfClass:NSDictionary.class]) return @"重载请求格式无效";
    NSDictionary *request = value;
    NSSet *keys = [NSSet setWithArray:@[@"version", @"action", @"id", @"session", @"nonce", @"createdAt"]];
    if (request.count != keys.count || ![[NSSet setWithArray:request.allKeys] isEqualToSet:keys] ||
        !KBRespringNumber(request[@"version"]) || [request[@"version"] doubleValue] != 1 ||
        !KBRespringNumber(request[@"action"]) ||
        [request[@"action"] doubleValue] != KBRespringActionReloadDesktop ||
        !KBRespringUUID(request[@"id"]) || !KBRespringUUID(request[@"session"]) ||
        !KBRespringUUID(request[@"nonce"]) || !KBRespringNumber(request[@"createdAt"]))
        return @"只接受固定的桌面注销请求，请重新打开设置";
    if (![request[@"session"] isEqual:session] || !nonce.length || ![request[@"nonce"] isEqual:nonce])
        return @"后台会话或一次性凭据已变化，请重新确认";
    double createdAt = [request[@"createdAt"] doubleValue];
    if (!isfinite(now) || !isfinite(uptime) || !isfinite(issuedAt) || !isfinite(issuedUptime) ||
        createdAt < issuedAt || createdAt > now || now - createdAt > KBRespringRequestLifetime ||
        now < issuedAt || now - issuedAt > KBRespringChallengeLifetime ||
        uptime < issuedUptime || uptime - issuedUptime > KBRespringChallengeLifetime)
        return @"重载请求已过期或时间无效，请重新确认";
    return nil;
}

// Match the existing importer queue, including the two differently named receipts.
static inline BOOL KBRespringHasPendingLibraryCommand(NSDictionary *prefs, NSDictionary *handled) {
    NSDictionary *keys = @{@"pendingZipAt": @"zipAt", @"convertRequest": @"convertAt",
        @"switchAt": @"switchAt", @"deleteAt": @"deleteAt", @"renameAt": @"renameAt",
        @"excludeAt": @"excludeAt", @"customAt": @"customAt", @"disableAt": @"disableAt",
        @"scanAt": @"scanAt", @"downloadAt": @"downloadAt"};
    for (NSString *key in keys) {
        id value = prefs[key], receipt = handled[keys[key]];
        if ((value && !KBRespringNumber(value)) || (receipt && !KBRespringNumber(receipt))) return YES;
        if ([value doubleValue] > [receipt doubleValue]) return YES;
    }
    return NO;
}

static inline NSDictionary *KBRespringReadState(NSString *directory) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:KBRespringStateFile]];
    id state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [state isKindOfClass:NSDictionary.class] ? state : nil;
}

static inline NSString *KBRespringStateFailure(NSDictionary *state, NSTimeInterval now) {
    if (!KBRespringNumber(state[@"version"]) || [state[@"version"] doubleValue] != 1 ||
        !KBRespringUUID(state[@"session"]) || !KBRespringNumber(state[@"updatedAt"]) ||
        !isfinite(now) || now < [state[@"updatedAt"] doubleValue] ||
        now - [state[@"updatedAt"] doubleValue] > KBRespringHeartbeatLifetime)
        return @"后台未就绪或状态已过期，请稍后再试";
    if (![state[@"ready"] isEqual:@YES])
        return [state[@"reason"] isKindOfClass:NSString.class] ? state[@"reason"] : @"后台正忙，请稍后再试";
    if (!KBRespringUUID(state[@"nonce"]) || !KBRespringNumber(state[@"issuedAt"]) ||
        !KBRespringNumber(state[@"expiresAt"]) || now < [state[@"issuedAt"] doubleValue] ||
        now >= [state[@"expiresAt"] doubleValue]) return @"确认已过期，请重新点按重载";
    return nil;
}
