#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "MWHTTPServer.h"
#import "MWDatabase.h"
#import "MWContacts.h"
#import "MWIMBridge.h"
#import "MWLog.h"

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/dev.sillyangel.meowtxt.plist";
static NSString *const kWebRoot = @"/var/jb/usr/share/meowd/web";
static NSString *const kCacheDir = @"/var/mobile/Library/Caches/meowd";
static const uint16_t kDefaultPort = 8737;

static NSString *gToken;
static BOOL gEnabled = YES;
static BOOL gVerbose = YES;
static BOOL gRequireAuth = YES;
static NSDate *gPrefsLastMod;
static NSMutableDictionary<NSString *, NSNumber *> *gNotificationEvents;
static NSMutableArray<NSString *> *gNotificationWebhooks;
static NSMutableDictionary<NSString *, NSNumber *> *gNotifiedStateByGUID;

#pragma mark - log helpers

static NSString *MWClientDesc(MWRequest *req) {
    NSString *ip = req.remoteAddress ?: @"127.0.0.1";
    NSString *ua = req.headers[@"user-agent"];
    if (!ua.length) return ip;
    if ([ua containsString:@"iPhone"] || [ua containsString:@"iPad"]) {
        return [NSString stringWithFormat:@"%@ [iOS Client]", ip];
    } else if ([ua containsString:@"Macintosh"] && [ua containsString:@"Safari"] && ![ua containsString:@"Chrome"]) {
        return [NSString stringWithFormat:@"%@ [Mac Safari]", ip];
    } else if ([ua containsString:@"Chrome"] || [ua containsString:@"CriOS"]) {
        return [NSString stringWithFormat:@"%@ [Chrome]", ip];
    } else if ([ua containsString:@"Firefox"]) {
        return [NSString stringWithFormat:@"%@ [Firefox]", ip];
    } else if ([ua containsString:@"curl"]) {
        return [NSString stringWithFormat:@"%@ [curl]", ip];
    }
    if (ua.length > 36) {
        return [NSString stringWithFormat:@"%@ [%@...]", ip, [ua substringToIndex:33]];
    }
    return [NSString stringWithFormat:@"%@ [%@]", ip, ua];
}

static NSString *MWSnippet(NSString *text, NSUInteger maxLen) {
    if (![text isKindOfClass:NSString.class] || !text.length) return @"";
    NSString *clean = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    clean = [clean stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    if (clean.length <= maxLen) return clean;
    return [NSString stringWithFormat:@"%@...", [clean substringToIndex:maxLen]];
}

static NSString *MWTimestampString(long long ms) {
    if (ms <= 0) return @"";
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:(double)ms / 1000.0];
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    @synchronized (df) {
        return [df stringFromDate:d];
    }
}

#pragma mark - config

static NSString *MWGenerateHexToken(void) {
    uint8_t raw[16];
    arc4random_buf(raw, sizeof(raw));
    NSMutableString *hex = [NSMutableString string];
    for (size_t i = 0; i < sizeof(raw); i++) [hex appendFormat:@"%02x", raw[i]];
    return hex;
}

static NSDictionary *MWLoadConfig(void) {
    NSMutableDictionary *cfg = [[NSDictionary dictionaryWithContentsOfFile:kPrefsPath] mutableCopy] ?: [NSMutableDictionary dictionary];
    BOOL dirty = NO;
    if ([cfg[@"regenerateToken"] boolValue]) {
        cfg[@"token"] = MWGenerateHexToken();
        cfg[@"regenerateToken"] = @NO;
        dirty = YES;
    }
    if (![cfg[@"token"] isKindOfClass:NSString.class] || [cfg[@"token"] length] < 4) {
        cfg[@"token"] = MWGenerateHexToken();
        dirty = YES;
    }
    if (!cfg[@"port"]) { cfg[@"port"] = @(kDefaultPort); dirty = YES; }
    if (cfg[@"enabled"] == nil) { cfg[@"enabled"] = @YES; dirty = YES; }
    if (cfg[@"verboseLogging"] == nil && cfg[@"verbose"] == nil) { cfg[@"verboseLogging"] = @YES; dirty = YES; }
    if (cfg[@"requireAuth"] == nil) { cfg[@"requireAuth"] = @YES; dirty = YES; }

    gToken = [cfg[@"token"] description];
    gEnabled = cfg[@"enabled"] ? [cfg[@"enabled"] boolValue] : YES;
    gVerbose = cfg[@"verboseLogging"] != nil ? [cfg[@"verboseLogging"] boolValue] : (cfg[@"verbose"] != nil ? [cfg[@"verbose"] boolValue] : YES);
    gRequireAuth = cfg[@"requireAuth"] ? [cfg[@"requireAuth"] boolValue] : YES;

    NSDictionary *savedNotifs = [cfg[@"notifications"] isKindOfClass:NSDictionary.class] ? cfg[@"notifications"] : @{};
    NSDictionary *savedEvents = [savedNotifs[@"events"] isKindOfClass:NSDictionary.class] ? savedNotifs[@"events"] : @{};
    BOOL evRec = cfg[@"notifReceived"] != nil ? [cfg[@"notifReceived"] boolValue] : (savedEvents[@"received"] != nil ? [savedEvents[@"received"] boolValue] : YES);
    BOOL evSent = cfg[@"notifSent"] != nil ? [cfg[@"notifSent"] boolValue] : (savedEvents[@"sent"] != nil ? [savedEvents[@"sent"] boolValue] : YES);
    BOOL evDel = cfg[@"notifDelivered"] != nil ? [cfg[@"notifDelivered"] boolValue] : (savedEvents[@"delivered"] != nil ? [savedEvents[@"delivered"] boolValue] : YES);
    BOOL evRead = cfg[@"notifRead"] != nil ? [cfg[@"notifRead"] boolValue] : (savedEvents[@"read"] != nil ? [savedEvents[@"read"] boolValue] : YES);

    if (!gNotificationEvents) gNotificationEvents = [NSMutableDictionary dictionary];
    @synchronized (gNotificationEvents) {
        gNotificationEvents[@"received"] = @(evRec);
        gNotificationEvents[@"sent"] = @(evSent);
        gNotificationEvents[@"delivered"] = @(evDel);
        gNotificationEvents[@"read"] = @(evRead);
        if (!gNotificationWebhooks) gNotificationWebhooks = [NSMutableArray array];
        [gNotificationWebhooks removeAllObjects];
        if ([savedNotifs[@"webhooks"] isKindOfClass:NSArray.class]) {
            for (id u in savedNotifs[@"webhooks"]) {
                if ([u isKindOfClass:NSString.class] && [u length]) [gNotificationWebhooks addObject:u];
            }
        }
    }
    if (!gNotifiedStateByGUID) gNotifiedStateByGUID = [NSMutableDictionary dictionary];

    if (dirty) {
        cfg[@"notifReceived"] = @(evRec);
        cfg[@"notifSent"] = @(evSent);
        cfg[@"notifDelivered"] = @(evDel);
        cfg[@"notifRead"] = @(evRead);
        [cfg writeToFile:kPrefsPath atomically:YES];
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kPrefsPath error:nil];
    gPrefsLastMod = attrs[NSFileModificationDate];
    return cfg;
}

static void MWReloadConfigIfChanged(void) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kPrefsPath error:nil];
    NSDate *mod = attrs[NSFileModificationDate];
    if (mod && (!gPrefsLastMod || ![mod isEqualToDate:gPrefsLastMod])) {
        MWLoadConfig();
        MWLog(@"reloaded preferences from Settings (enabled=%d, verbose=%d, requireAuth=%d)", gEnabled, gVerbose, gRequireAuth);
    }
}

static void MWSaveNotificationConfig(void) {
    @synchronized (gNotificationEvents) {
        NSMutableDictionary *cfg = [[NSDictionary dictionaryWithContentsOfFile:kPrefsPath] mutableCopy] ?: [NSMutableDictionary dictionary];
        cfg[@"notifications"] = @{
            @"events": [gNotificationEvents copy],
            @"webhooks": [gNotificationWebhooks copy],
        };
        cfg[@"notifReceived"] = gNotificationEvents[@"received"] ?: @YES;
        cfg[@"notifSent"] = gNotificationEvents[@"sent"] ?: @YES;
        cfg[@"notifDelivered"] = gNotificationEvents[@"delivered"] ?: @YES;
        cfg[@"notifRead"] = gNotificationEvents[@"read"] ?: @YES;
        [cfg writeToFile:kPrefsPath atomically:YES];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kPrefsPath error:nil];
        gPrefsLastMod = attrs[NSFileModificationDate];
    }
}

#pragma mark - event hub (SSE)

@interface MWSubscriber : NSObject
@property (nonatomic, strong) NSMutableArray<NSData *> *pending;
@property (nonatomic, strong) dispatch_semaphore_t signal;
@end
@implementation MWSubscriber
@end

static NSMutableSet<MWSubscriber *> *gSubscribers;

static void MWBroadcast(NSString *event, id payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    NSMutableData *frame = [NSMutableData data];
    [frame appendData:[[NSString stringWithFormat:@"event: %@\ndata: ", event] dataUsingEncoding:NSUTF8StringEncoding]];
    [frame appendData:json];
    [frame appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    @synchronized (gSubscribers) {
        for (MWSubscriber *s in gSubscribers) {
            @synchronized (s) {
                if (s.pending.count < 500) [s.pending addObject:frame];
            }
            dispatch_semaphore_signal(s.signal);
        }
    }
}

#pragma mark - enrichment

static NSDictionary *MWNamesForMessages(NSArray<NSDictionary *> *messages) {
    NSMutableSet *handles = [NSMutableSet set];
    for (NSDictionary *m in messages) {
        if ([m[@"sender"] isKindOfClass:NSString.class]) [handles addObject:m[@"sender"]];
        if ([m[@"otherHandle"] isKindOfClass:NSString.class]) [handles addObject:m[@"otherHandle"]];
    }
    return [[MWContacts shared] namesForHandles:handles.allObjects];
}

static NSDictionary *MWAvatarsForMessages(NSArray<NSDictionary *> *messages) {
    NSMutableSet *handles = [NSMutableSet set];
    for (NSDictionary *m in messages) {
        if ([m[@"sender"] isKindOfClass:NSString.class]) [handles addObject:m[@"sender"]];
    }
    return [[MWContacts shared] avatarsForHandles:handles.allObjects];
}

static NSInteger MWPinIndexForChat(NSDictionary *chat, NSArray<NSString *> *pinnedIDs) {
    if (!pinnedIDs.count) return NSNotFound;
    NSMutableSet<NSString *> *candidates = [NSMutableSet set];
    if ([chat[@"identifier"] isKindOfClass:NSString.class]) {
        NSString *ident = chat[@"identifier"];
        [candidates addObject:ident.lowercaseString];
        if (![chat[@"isGroup"] boolValue]) {
            for (NSString *sib in [[MWContacts shared] siblingHandlesForHandle:ident]) {
                [candidates addObject:sib.lowercaseString];
                if (sib.length == 10 && ![sib containsString:@"@"]) {
                    [candidates addObject:[@"+1" stringByAppendingString:sib]];
                }
            }
        }
    }
    if ([chat[@"groupID"] isKindOfClass:NSString.class]) [candidates addObject:[chat[@"groupID"] lowercaseString]];
    if ([chat[@"originalGroupID"] isKindOfClass:NSString.class]) [candidates addObject:[chat[@"originalGroupID"] lowercaseString]];

    for (NSUInteger i = 0; i < pinnedIDs.count; i++) {
        NSString *p = [pinnedIDs[i] lowercaseString];
        if ([candidates containsObject:p]) return (NSInteger)i;
        if (p.length > 10 && ![p containsString:@"@"]) {
            NSString *last10 = [p substringFromIndex:p.length - 10];
            if ([candidates containsObject:last10]) return (NSInteger)i;
        }
    }
    return NSNotFound;
}

static NSDictionary *MWDecorateChatWithPins(NSDictionary *chat, NSArray<NSString *> *pinnedIDs) {
    NSMutableDictionary *c = [chat mutableCopy];
    NSArray *participants = chat[@"participants"];
    NSDictionary *names = [[MWContacts shared] namesForHandles:participants];
    NSDictionary *avatars = [[MWContacts shared] avatarsForHandles:participants];
    c[@"names"] = names;
    c[@"avatars"] = avatars;
    NSString *title = [chat[@"displayName"] isKindOfClass:NSString.class] ? chat[@"displayName"] : nil;
    if (!title.length) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *h in participants) [parts addObject:names[h] ?: h];
        title = parts.count ? [parts componentsJoinedByString:@", "] : chat[@"identifier"];
    }
    c[@"title"] = title ?: @"";

    NSString *avatarUrl = nil;
    if ([chat[@"groupPhotoAttachmentID"] isKindOfClass:NSNumber.class] && [chat[@"groupPhotoAttachmentID"] longLongValue] > 0) {
        avatarUrl = [NSString stringWithFormat:@"/api/attachment?id=%lld&thumb=1", [chat[@"groupPhotoAttachmentID"] longLongValue]];
    } else if (![chat[@"isGroup"] boolValue]) {
        NSString *h = participants.firstObject ?: ([chat[@"identifier"] isKindOfClass:NSString.class] ? chat[@"identifier"] : nil);
        if (h && (avatars[h] || [[MWContacts shared] hasAvatarForHandle:h])) {
            NSString *enc = [[h stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]
                             stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
            avatarUrl = [NSString stringWithFormat:@"/api/avatar?handle=%@", enc];
        }
    }
    c[@"avatarUrl"] = avatarUrl ?: [NSNull null];

    NSInteger pinIdx = MWPinIndexForChat(chat, pinnedIDs);
    c[@"pinned"] = @(pinIdx != NSNotFound);
    c[@"pinIndex"] = pinIdx != NSNotFound ? @(pinIdx) : [NSNull null];

    BOOL dnd = [[MWIMBridge shared] isDNDActiveForChat:chat[@"guid"]
                                            identifier:[chat[@"identifier"] isKindOfClass:NSString.class] ? chat[@"identifier"] : nil];
    if (!dnd && [chat[@"lastMessage"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *lm = chat[@"lastMessage"];
        long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        if ([lm[@"wasDeliveredQuietly"] boolValue] && ![lm[@"didNotifyRecipient"] boolValue] &&
            (nowMs - [lm[@"date"] longLongValue]) < 3600000LL) {
            dnd = YES;
        }
    }
    c[@"dnd"] = @(dnd);
    return c;
}

static NSDictionary *MWDecorateChat(NSDictionary *chat) {
    return MWDecorateChatWithPins(chat, [[MWIMBridge shared] pinnedIdentifiers]);
}

static BOOL MWIsIMessageChat(id guid) {
    return [guid isKindOfClass:NSString.class] && [guid hasPrefix:@"iMessage;"];
}

static NSString *MWChatLabel(NSString *chatGUID) {
    if (![chatGUID isKindOfClass:NSString.class] || !chatGUID.length) return @"(unknown)";
    NSDictionary *c = [[MWDatabase shared] chatWithGUID:chatGUID];
    if (c) {
        NSDictionary *dec = MWDecorateChat(c);
        if ([dec[@"title"] isKindOfClass:NSString.class] && [dec[@"title"] length]) {
            return [NSString stringWithFormat:@"'%@' (%@)", dec[@"title"], chatGUID];
        }
    }
    if ([chatGUID hasPrefix:@"iMessage;-;"]) {
        NSString *handle = [chatGUID substringFromIndex:11];
        NSString *name = [[MWContacts shared] nameForHandle:handle];
        if (name.length) return [NSString stringWithFormat:@"'%@' (%@)", name, handle];
        return handle;
    }
    return chatGUID;
}

#pragma mark - change poller

static void MWBroadcastPinnedUpdate(void) {
    NSArray<NSString *> *pins = [[MWIMBridge shared] pinnedIdentifiers];
    MWBroadcast(@"pinned", @{@"pinnedIdentifiers": pins});
}

static NSDictionary *MWEmitNotification(NSString *type, NSString *title, NSString *body,
                                        NSString *chatGUID, NSString *avatarUrl, NSDictionary *msg, BOOL force) {
    BOOL enabled = YES;
    NSArray<NSString *> *webhooks = nil;
    @synchronized (gNotificationEvents) {
        if (!force && gNotificationEvents[type] != nil) {
            enabled = [gNotificationEvents[type] boolValue];
        }
        webhooks = [gNotificationWebhooks copy];
    }
    long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    NSString *msgGuid = [msg[@"guid"] isKindOfClass:NSString.class] ? msg[@"guid"] : [[NSUUID UUID] UUIDString];
    NSDictionary *payload = @{
        @"id": [NSString stringWithFormat:@"notif-%@-%@", msgGuid, type],
        @"type": type ?: @"received",
        @"title": title ?: @"meowtxt",
        @"body": body ?: @"",
        @"chat": chatGUID ?: [NSNull null],
        @"avatarUrl": avatarUrl ?: [NSNull null],
        @"icon": avatarUrl ?: @"/icon-192.png",
        @"tag": [NSString stringWithFormat:@"meow-%@-%@", chatGUID ?: @"general", type],
        @"message": msg ?: [NSNull null],
        @"timestamp": @(nowMs),
    };
    if (enabled || force) {
        MWBroadcast(@"notification", payload);
        if (webhooks.count) {
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
            for (NSString *urlStr in webhooks) {
                NSURL *u = [NSURL URLWithString:urlStr];
                if (!u) continue;
                NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
                req.HTTPMethod = @"POST";
                [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                [req setValue:[NSString stringWithFormat:@"meowtxt-%@", type] forHTTPHeaderField:@"X-Meow-Event"];
                req.HTTPBody = jsonData;
                [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
            }
        }
    }
    return payload;
}

static void MWStartPoller(void) {
    dispatch_queue_t q = dispatch_queue_create("meow.poller", DISPATCH_QUEUE_SERIAL);
    __block long long lastRowid = [[MWDatabase shared] maxMessageROWID];
    __block long long lastCheck = [MWDatabase appleTimeNow];
    [[MWDatabase shared] hasChanged];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 400 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            MWReloadConfigIfChanged();
            if ([[MWIMBridge shared] reloadPinnedFromDiskIfChanged]) {
                MWBroadcastPinnedUpdate();
            }
            if (![[MWDatabase shared] hasChanged]) return;
            long long now = [MWDatabase appleTimeNow];
            long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);

            NSArray *fresh = [[MWDatabase shared] messagesAfterROWID:lastRowid limit:200];
            NSMutableSet *touchedChats = [NSMutableSet set];
            for (NSDictionary *m in fresh) {
                lastRowid = MAX(lastRowid, [m[@"id"] longLongValue]);
                if (!MWIsIMessageChat(m[@"chat"])) continue;
                NSString *chatGUID = m[@"chat"];
                [touchedChats addObject:chatGUID];
                NSDictionary *names = MWNamesForMessages(@[m]);
                NSDictionary *avatars = MWAvatarsForMessages(@[m]);
                MWBroadcast(@"message", @{
                    @"message": m,
                    @"names": names,
                    @"avatars": avatars,
                });

                if ([m[@"itemType"] intValue] == 0 && [m[@"guid"] isKindOfClass:NSString.class]) {
                    NSString *guid = m[@"guid"];
                    BOOL fromMe = [m[@"fromMe"] boolValue];
                    int mask = 1 | ([m[@"delivered"] boolValue] ? 2 : 0) | ([m[@"read"] boolValue] ? 4 : 0);
                    gNotifiedStateByGUID[guid] = @(mask);

                    NSDictionary *chatObj = [[MWDatabase shared] chatWithGUID:chatGUID];
                    NSDictionary *decChat = chatObj ? MWDecorateChat(chatObj) : nil;
                    NSString *chatTitle = [decChat[@"title"] isKindOfClass:NSString.class] && [decChat[@"title"] length]
                        ? decChat[@"title"]
                        : ([m[@"sender"] isKindOfClass:NSString.class] ? (names[m[@"sender"]] ?: m[@"sender"]) : chatGUID);
                    NSString *avatarUrl = [decChat[@"avatarUrl"] isKindOfClass:NSString.class] ? decChat[@"avatarUrl"] : nil;
                    NSString *textPreview = [m[@"text"] isKindOfClass:NSString.class] && [m[@"text"] length]
                        ? m[@"text"]
                        : ([m[@"attachments"] count] ? @"📎 Attachment" : @"iMessage");

                    if (fromMe) {
                        if (gVerbose) {
                            MWLog(@"[OUTGOING] Sent message in %@: guid=%@ text='%@'",
                                  MWChatLabel(chatGUID), guid, MWSnippet(textPreview, 80));
                        }
                        MWEmitNotification(@"sent",
                                           [NSString stringWithFormat:@"Sent to %@", chatTitle],
                                           textPreview, chatGUID, avatarUrl, m, NO);
                    } else {
                        NSString *sender = [m[@"sender"] isKindOfClass:NSString.class] ? (names[m[@"sender"]] ?: m[@"sender"]) : chatTitle;
                        if (gVerbose) {
                            MWLog(@"[INCOMING] New message from '%@' in %@: guid=%@ text='%@'%@",
                                  sender, MWChatLabel(chatGUID), guid, MWSnippet(textPreview, 80),
                                  [m[@"attachments"] count] ? [NSString stringWithFormat:@" [%lu attachments]", (unsigned long)[m[@"attachments"] count]] : @"");
                        }
                        MWEmitNotification(@"received",
                                           sender,
                                           textPreview, chatGUID, avatarUrl, m, NO);
                    }
                }
            }

            NSArray *updated = [[MWDatabase shared] messagesUpdatedSince:lastCheck - 2000000000LL];
            lastCheck = now;
            for (NSDictionary *m in updated) {
                if (!MWIsIMessageChat(m[@"chat"])) continue;
                NSString *chatGUID = m[@"chat"];
                NSDictionary *names = MWNamesForMessages(@[m]);
                NSDictionary *avatars = MWAvatarsForMessages(@[m]);
                MWBroadcast(@"updated", @{
                    @"message": m,
                    @"names": names,
                    @"avatars": avatars,
                });

                if ([m[@"itemType"] intValue] == 0 && [m[@"fromMe"] boolValue] && [m[@"guid"] isKindOfClass:NSString.class]) {
                    NSString *guid = m[@"guid"];
                    int prevMask = [gNotifiedStateByGUID[guid] intValue];
                    BOOL isRead = [m[@"read"] boolValue];
                    BOOL isDelivered = [m[@"delivered"] boolValue];
                    long long dateRead = [m[@"dateRead"] longLongValue];
                    long long dateDelivered = [m[@"dateDelivered"] longLongValue];

                    NSDictionary *chatObj = [[MWDatabase shared] chatWithGUID:chatGUID];
                    NSDictionary *decChat = chatObj ? MWDecorateChat(chatObj) : nil;
                    NSString *chatTitle = [decChat[@"title"] isKindOfClass:NSString.class] && [decChat[@"title"] length]
                        ? decChat[@"title"] : chatGUID;
                    NSString *avatarUrl = [decChat[@"avatarUrl"] isKindOfClass:NSString.class] ? decChat[@"avatarUrl"] : nil;
                    NSString *textPreview = [m[@"text"] isKindOfClass:NSString.class] && [m[@"text"] length]
                        ? m[@"text"] : @"iMessage";

                    if (isRead && !(prevMask & 4) && (prevMask != 0 || (dateRead > 0 && (nowMs - dateRead) < 15000LL))) {
                        gNotifiedStateByGUID[guid] = @(prevMask | 1 | 2 | 4);
                        if (gVerbose) {
                            MWLog(@"[READ-RECEIPT] Message read by recipient in %@: guid=%@ text='%@' (read at: %@)",
                                  MWChatLabel(chatGUID), guid, MWSnippet(textPreview, 60), MWTimestampString(dateRead));
                        }
                        MWEmitNotification(@"read",
                                           [NSString stringWithFormat:@"Read by %@", chatTitle],
                                           textPreview, chatGUID, avatarUrl, m, NO);
                    } else if (isDelivered && !isRead && !(prevMask & 2) && (prevMask != 0 || (dateDelivered > 0 && (nowMs - dateDelivered) < 15000LL))) {
                        gNotifiedStateByGUID[guid] = @(prevMask | 1 | 2);
                        if (gVerbose) {
                            MWLog(@"[DELIVERY-RECEIPT] Message delivered to %@: guid=%@ (quietly=%d)",
                                  MWChatLabel(chatGUID), guid, [m[@"wasDeliveredQuietly"] boolValue]);
                        }
                        NSString *delivTitle = [m[@"wasDeliveredQuietly"] boolValue]
                            ? [NSString stringWithFormat:@"Delivered Quietly to %@ 🌙", chatTitle]
                            : [NSString stringWithFormat:@"Delivered to %@", chatTitle];
                        MWEmitNotification(@"delivered",
                                           delivTitle,
                                           textPreview, chatGUID, avatarUrl, m, NO);
                    } else if (prevMask == 0) {
                        gNotifiedStateByGUID[guid] = @(1 | (isDelivered ? 2 : 0) | (isRead ? 4 : 0));
                    }
                }
            }

            NSArray<NSString *> *pins = [[MWIMBridge shared] pinnedIdentifiers];
            for (NSString *guid in touchedChats) {
                NSDictionary *chat = [[MWDatabase shared] chatWithGUID:guid];
                if (chat) MWBroadcast(@"chat", MWDecorateChatWithPins(chat, pins));
            }
        }
    });
    dispatch_resume(timer);
    static dispatch_source_t keep;
    keep = timer;
    (void)keep;
}

#pragma mark - attachments

static NSString *MWMimeForPath(NSString *path, NSString *fallback) {
    if (fallback.length) return fallback;
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"webmanifest"]) return @"application/manifest+json; charset=utf-8";
    if ([ext isEqualToString:@"svg"]) return @"image/svg+xml";
    if ([ext isEqualToString:@"ico"]) return @"image/x-icon";
    if ([ext isEqualToString:@"json"]) return @"application/json; charset=utf-8";
    if ([ext isEqualToString:@"otf"]) return @"font/otf";
    if ([ext isEqualToString:@"ttf"]) return @"font/ttf";
    if ([ext isEqualToString:@"woff2"]) return @"font/woff2";
    if ([ext isEqualToString:@"woff"]) return @"font/woff";
    UTType *t = [UTType typeWithFilenameExtension:ext];
    return t.preferredMIMEType ?: @"application/octet-stream";
}

// Transcodes HEIC/HEIF/AVCI/TIFF/BMP (or generates fast 640px thumbnails when `thumb` is YES) into cached JPEGs/PNGs.
static NSString *MWBrowserFriendlyImage(NSString *path, long long rowid, BOOL thumb, NSString *uti, NSString *mime, NSString **outMime) {
    NSString *ext = path.pathExtension.lowercaseString ?: @"";
    NSString *utiLow = uti.lowercaseString ?: @"";
    NSString *mimeLow = mime.lowercaseString ?: @"";

    BOOL isHeicOrTiff = [@[@"heic", @"heif", @"heics", @"avci", @"tif", @"tiff", @"bmp"] containsObject:ext] ||
                        [utiLow containsString:@"heic"] || [utiLow containsString:@"heif"] ||
                        [utiLow containsString:@"avci"] || [utiLow containsString:@"tiff"] ||
                        [mimeLow containsString:@"heic"] || [mimeLow containsString:@"heif"] ||
                        [mimeLow containsString:@"tiff"];
    BOOL isStandardImage = [@[@"jpg", @"jpeg", @"png", @"gif", @"webp"] containsObject:ext] ||
                           [utiLow containsString:@"jpeg"] || [utiLow containsString:@"png"] ||
                           [mimeLow hasPrefix:@"image/"];

    if (!isHeicOrTiff && !(thumb && isStandardImage)) return nil;
    if ([ext isEqualToString:@"gif"] || [mimeLow isEqualToString:@"image/gif"]) return nil;

    NSString *jpgOut = [kCacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"v2_%lld%@", rowid, thumb ? @"_thumb.jpg" : @".jpg"]];
    NSString *pngOut = [kCacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"v2_%lld%@", rowid, thumb ? @"_thumb.png" : @".png"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:pngOut]) {
        if (outMime) *outMime = @"image/png";
        return pngOut;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:jpgOut]) {
        if (outMime) *outMime = @"image/jpeg";
        return jpgOut;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:kCacheDir withIntermediateDirectories:YES attributes:nil error:nil];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return nil;
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: thumb ? @640 : @1800,
    };
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    if (!img) {
        img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)@{
            (id)kCGImageSourceCreateThumbnailFromImageIfAbsent: @YES,
            (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        });
    }
    CFRelease(src);
    if (!img) return nil;

    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(img);
    BOOL hasAlpha = (alpha == kCGImageAlphaPremultipliedLast || alpha == kCGImageAlphaPremultipliedFirst ||
                     alpha == kCGImageAlphaLast || alpha == kCGImageAlphaFirst);
    NSString *targetPath = hasAlpha ? pngOut : jpgOut;
    CFStringRef targetUTI = hasAlpha ? (__bridge CFStringRef)@"public.png" : (__bridge CFStringRef)@"public.jpeg";

    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:targetPath],
                                                                targetUTI, 1, NULL);
    BOOL ok = NO;
    if (dst) {
        NSDictionary *destOpts = hasAlpha ? @{} : @{(id)kCGImageDestinationLossyCompressionQuality: thumb ? @0.80 : @0.88};
        CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)destOpts);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(img);
    if (ok && outMime) *outMime = hasAlpha ? @"image/png" : @"image/jpeg";
    return ok ? targetPath : nil;
}

static MWResponse *MWServeFile(NSString *path, NSString *mime, MWRequest *req, NSString *downloadName) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return [MWResponse error:@"file not available on the phone (maybe still in iCloud)" status:404];
    MWResponse *r = [MWResponse data:data type:mime];
    r.headers[@"Accept-Ranges"] = @"bytes";
    r.headers[@"Cache-Control"] = @"private, max-age=86400";
    if (downloadName.length) {
        NSString *enc = [downloadName stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        r.headers[@"Content-Disposition"] = [NSString stringWithFormat:@"inline; filename*=UTF-8''%@", enc];
    }
    NSString *range = req.headers[@"range"];
    if ([range hasPrefix:@"bytes="]) {
        NSArray *p = [[range substringFromIndex:6] componentsSeparatedByString:@"-"];
        long long total = (long long)data.length;
        long long start = [p[0] length] ? [p[0] longLongValue] : -1;
        long long end = p.count > 1 && [p[1] length] ? [p[1] longLongValue] : total - 1;
        if (start < 0) { start = total - end; end = total - 1; }
        end = MIN(end, total - 1);
        if (start >= 0 && start <= end) {
            r.status = 206;
            r.body = [data subdataWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start + 1))];
            r.headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, total];
        }
    }
    return r;
}

#pragma mark - routing

static NSArray<NSString *> *MWAddressList(id v) {
    if ([v isKindOfClass:NSArray.class]) return v;
    if ([v isKindOfClass:NSString.class] && [v length]) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *s in [v componentsSeparatedByString:@","]) {
            NSString *t = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (t.length) [out addObject:t];
        }
        return out;
    }
    return nil;
}

static NSString *MWStr(id v) { return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }

static BOOL MWAuthorized(MWRequest *req) {
    if (!gRequireAuth) return YES;
    NSString *auth = req.headers[@"authorization"];
    NSString *tok = nil;
    if ([auth.lowercaseString hasPrefix:@"bearer "]) tok = [auth substringFromIndex:7];
    if (!tok) tok = req.headers[@"x-meow-token"];
    if (!tok) tok = req.query[@"token"];
    return tok && [tok isEqualToString:gToken];
}

static MWResponse *MWStatic(MWRequest *req) {
    NSString *rel = [req.path isEqualToString:@"/"] ? @"index.html" : [req.path substringFromIndex:1];
    if ([rel isEqualToString:@".well-known/manifest.webmanifest"]) {
        rel = @"manifest.webmanifest";
    }
    if ([rel containsString:@".."]) return nil;
    NSString *path = [kWebRoot stringByAppendingPathComponent:rel];
    BOOL dir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir] || dir) return nil;
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSString *mime = MWMimeForPath(path, nil);
    if (([mime hasPrefix:@"text/"] || [mime containsString:@"javascript"]) && ![mime containsString:@"charset"]) {
        mime = [mime stringByAppendingString:@"; charset=utf-8"];
    }
    if (gVerbose && ([req.path isEqualToString:@"/"] || [rel isEqualToString:@"index.html"])) {
        MWLog(@"[VIEW] %@ loaded Web Client (/) [%@]", MWClientDesc(req), req.headers[@"user-agent"] ?: @"unknown");
    }
    MWResponse *r = [MWResponse data:d type:mime];
    if ([@[@"otf", @"ttf", @"woff", @"woff2"] containsObject:path.pathExtension.lowercaseString]) {
        r.headers[@"Cache-Control"] = @"public, max-age=31536000, immutable";
    } else {
        r.headers[@"Cache-Control"] = @"no-cache";
    }
    r.headers[@"Service-Worker-Allowed"] = @"/";
    return r;
}

static NSDictionary *MWOpenAPISpec(void) {
    return @{
        @"openapi": @"3.1.0",
        @"info": @{
            @"title": @"meowtxt iMessage REST & SSE API",
            @"version": @"0.2.0",
            @"description": @"On-device iOS 16 iMessage REST + Server-Sent Events (SSE) API exposed by meowd (dev.sillyangel.meowtxt). Designed for building custom web, PWA, Chrome Isolated Web App (IWA), Next.js, React, desktop, and AI agent clients.",
        },
        @"components": @{
            @"securitySchemes": @{
                @"BearerAuth": @{@"type": @"http", @"scheme": @"bearer"},
                @"MeowTokenHeader": @{@"type": @"apiKey", @"in": @"header", @"name": @"X-Meow-Token"},
                @"QueryToken": @{@"type": @"apiKey", @"in": @"query", @"name": @"token"},
            },
        },
        @"security": @[@{@"BearerAuth": @[]}, @{@"MeowTokenHeader": @[]}, @{@"QueryToken": @[]}],
        @"paths": @{
            @"/api/status": @{@"get": @{@"summary": @"Daemon & iMessage account health"}},
            @"/api/chats": @{@"get": @{@"summary": @"List iMessage conversations (with avatars, pins, DND state, and lastMessage)"}},
            @"/api/chat": @{@"get": @{@"summary": @"Get a single conversation by GUID"}},
            @"/api/messages": @{@"get": @{@"summary": @"List messages in a conversation (newest first, cursor pagination via ?before=<ms>)"}},
            @"/api/message": @{@"get": @{@"summary": @"Get a single message by GUID"}},
            @"/api/attachment": @{@"get": @{@"summary": @"Stream attachment (auto-transcodes HEIC/TIFF to JPEG; supports ?thumb=1, ?raw=1, and HTTP Range)"}},
            @"/api/avatar": @{@"get": @{@"summary": @"Stream contact avatar photo by handle"}},
            @"/api/search": @{@"get": @{@"summary": @"Search message text across all iMessage conversations"}},
            @"/api/contacts": @{@"get": @{@"summary": @"Search iOS AddressBook contacts and handles"}},
            @"/api/dnd": @{@"get": @{@"summary": @"Query and subscribe to Focus / Do Not Disturb status for a chat"}},
            @"/api/notifications": @{
                @"get": @{@"summary": @"Get push/webhook notification preferences (received, sent, delivered, read)"},
                @"post": @{@"summary": @"Update notification event toggles (received, sent, delivered, read) and webhook URLs"},
            },
            @"/api/notifications/test": @{@"post": @{@"summary": @"Emit a test notification event over SSE and registered webhooks"}},
            @"/api/pin": @{@"post": @{@"summary": @"Pin or unpin a conversation (two-way synced with native iOS Messages)"}},
            @"/api/send": @{@"post": @{@"summary": @"Send an iMessage (supports subject, bubble/screen effects, inline replies, and notifyAnyway DND override)"}},
            @"/api/send-file": @{@"post": @{@"summary": @"Upload and send a binary file/photo/video/audio attachment"}},
            @"/api/notify": @{@"post": @{@"summary": @"Manually override Focus / Do Not Disturb ('Notify Anyway') for a quietly-delivered message"}},
            @"/api/edit": @{@"post": @{@"summary": @"Edit a recently sent iMessage (iOS 16+)"}},
            @"/api/unsend": @{@"post": @{@"summary": @"Unsend / retract a recently sent iMessage (iOS 16+)"}},
            @"/api/react": @{@"post": @{@"summary": @"Send or remove a tapback reaction (love, like, dislike, laugh, emphasize, question)"}},
            @"/api/read": @{@"post": @{@"summary": @"Mark a conversation as read"}},
            @"/api/typing": @{@"post": @{@"summary": @"Start or stop outgoing typing indicator"}},
            @"/api/events": @{@"get": @{@"summary": @"Server-Sent Events stream (hello, message, updated, chat, typing, pinned, dnd, notification)"}},
        },
    };
}

static MWResponse *MWRoute(MWRequest *req) {
    NSString *p = req.path;
    NSString *m = req.method;
    if ([m isEqualToString:@"OPTIONS"]) { MWResponse *r = [MWResponse new]; r.status = 204; r.body = [NSData data]; return r; }

    if (!gEnabled) {
        return [MWResponse error:@"meowtxt server is disabled in iOS Settings (Settings -> meowtxt)" status:503];
    }

    if ([p isEqualToString:@"/api/openapi.json"] && ([m isEqualToString:@"GET"] || [m isEqualToString:@"HEAD"])) {
        return [MWResponse json:MWOpenAPISpec()];
    }

    if (![p hasPrefix:@"/api/"]) {
        if (![m isEqualToString:@"GET"] && ![m isEqualToString:@"HEAD"]) return [MWResponse error:@"method not allowed" status:405];
        return MWStatic(req);
    }
    if (!MWAuthorized(req)) {
        MWLog(@"[AUTH-FAIL] %@ unauthorized access attempt to %@ %@", MWClientDesc(req), m, p);
        return [MWResponse error:@"unauthorized" status:401];
    }

    BOOL get = [m isEqualToString:@"GET"] || [m isEqualToString:@"HEAD"], post = [m isEqualToString:@"POST"];
    NSDictionary *q = req.query;
    NSDictionary *body = post ? ([[req JSONBody] isKindOfClass:NSDictionary.class] ? [req JSONBody] : @{}) : @{};

    if (get && [p isEqualToString:@"/api/status"]) {
        if (gVerbose) MWLog(@"[STATUS] %@ queried system & iMessage health", MWClientDesc(req));
        NSMutableDictionary *st = [[[MWIMBridge shared] status] mutableCopy];
        st[@"enabled"] = @(gEnabled);
        st[@"requireAuth"] = @(gRequireAuth);
        return [MWResponse json:st];
    }
    if (get && [p isEqualToString:@"/api/notifications"]) {
        @synchronized (gNotificationEvents) {
            return [MWResponse json:@{
                @"ok": @YES,
                @"events": [gNotificationEvents copy],
                @"webhooks": [gNotificationWebhooks copy],
            }];
        }
    }
    if (post && [p isEqualToString:@"/api/notifications"]) {
        @synchronized (gNotificationEvents) {
            if ([body[@"events"] isKindOfClass:NSDictionary.class]) {
                NSDictionary *ev = body[@"events"];
                for (NSString *k in @[@"received", @"sent", @"delivered", @"read"]) {
                    if (ev[k] != nil) gNotificationEvents[k] = @([ev[k] boolValue]);
                }
            }
            for (NSString *k in @[@"received", @"sent", @"delivered", @"read"]) {
                if (body[k] != nil) gNotificationEvents[k] = @([body[k] boolValue]);
            }
            if ([body[@"webhooks"] isKindOfClass:NSArray.class]) {
                [gNotificationWebhooks removeAllObjects];
                for (id u in body[@"webhooks"]) {
                    if ([u isKindOfClass:NSString.class] && [u length]) [gNotificationWebhooks addObject:u];
                }
            }
            if ([body[@"addWebhook"] isKindOfClass:NSString.class] && [body[@"addWebhook"] length]) {
                NSString *u = body[@"addWebhook"];
                if (![gNotificationWebhooks containsObject:u]) [gNotificationWebhooks addObject:u];
            }
            if ([body[@"removeWebhook"] isKindOfClass:NSString.class]) {
                [gNotificationWebhooks removeObject:body[@"removeWebhook"]];
            }
            MWSaveNotificationConfig();
            return [MWResponse json:@{
                @"ok": @YES,
                @"events": [gNotificationEvents copy],
                @"webhooks": [gNotificationWebhooks copy],
            }];
        }
    }
    if (post && [p isEqualToString:@"/api/notifications/test"]) {
        NSString *type = MWStr(body[@"type"]) ?: @"read";
        NSString *title = MWStr(body[@"title"]) ?: ([type isEqualToString:@"sent"] ? @"Sent via meowtxt" :
                                                    [type isEqualToString:@"delivered"] ? @"Delivered via meowtxt" :
                                                    [type isEqualToString:@"received"] ? @"New iMessage" : @"Read by Recipient");
        NSString *msgBody = MWStr(body[@"body"]) ?: @"Web notifications for sent, delivered & read messages are active!";
        NSString *chatGUID = MWStr(body[@"chat"]);
        NSDictionary *payload = MWEmitNotification(type, title, msgBody, chatGUID, nil, nil, YES);
        return [MWResponse json:@{@"ok": @YES, @"notification": payload}];
    }
    if (get && [p isEqualToString:@"/api/chats"]) {
        NSInteger limit = q[@"limit"] ? MIN(MAX([q[@"limit"] integerValue], 1), 500) : 50;
        NSInteger offset = MAX([q[@"offset"] integerValue], 0);
        NSArray<NSString *> *pins = [[MWIMBridge shared] pinnedIdentifiers];
        NSMutableArray *chats = [NSMutableArray array];
        for (NSDictionary *c in [[MWDatabase shared] chatsWithLimit:limit offset:offset]) {
            [chats addObject:MWDecorateChatWithPins(c, pins)];
        }
        if (gVerbose) {
            MWLog(@"[CHATS] %@ viewed conversations list (returned %lu chats, limit=%ld, offset=%ld)",
                  MWClientDesc(req), (unsigned long)chats.count, (long)limit, (long)offset);
        }
        return [MWResponse json:@{@"ok": @YES, @"chats": chats, @"pinnedIdentifiers": pins}];
    }
    if (get && [p isEqualToString:@"/api/chat"]) {
        NSDictionary *c = MWStr(q[@"guid"]) ? [[MWDatabase shared] chatWithGUID:q[@"guid"]] : nil;
        if (gVerbose && c) {
            MWLog(@"[CHAT] %@ loaded conversation %@", MWClientDesc(req), MWChatLabel(q[@"guid"]));
        }
        return c ? [MWResponse json:@{@"ok": @YES, @"chat": MWDecorateChat(c)}] : [MWResponse error:@"chat not found" status:404];
    }
    if (get && [p isEqualToString:@"/api/messages"]) {
        NSString *chat = MWStr(q[@"chat"]);
        if (!MWIsIMessageChat(chat)) return [MWResponse error:@"chat (an iMessage chat guid) is required" status:400];
        [[MWIMBridge shared] observeDNDForChat:chat];
        NSInteger limit = q[@"limit"] ? MIN(MAX([q[@"limit"] integerValue], 1), 500) : 50;
        NSArray *msgs = [[MWDatabase shared] messagesForChat:chat before:[q[@"before"] longLongValue] limit:limit];
        BOOL dnd = [[MWIMBridge shared] isDNDActiveForChat:chat identifier:nil];
        if (!dnd && msgs.count) {
            NSDictionary *latest = msgs.firstObject;
            long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
            if ([latest[@"wasDeliveredQuietly"] boolValue] && ![latest[@"didNotifyRecipient"] boolValue] &&
                (nowMs - [latest[@"date"] longLongValue]) < 3600000LL) {
                dnd = YES;
            }
        }
        if (gVerbose) {
            NSString *summary = @"";
            if (msgs.count) {
                NSDictionary *top = msgs.firstObject;
                summary = [NSString stringWithFormat:@" (latest: guid=%@, text='%@', date=%@)",
                           top[@"guid"],
                           MWSnippet(top[@"text"], 40),
                           MWTimestampString([top[@"date"] longLongValue])];
            }
            MWLog(@"[ACCESS] %@ accessed %lu messages from %@ (before=%lld, limit=%ld)%@",
                  MWClientDesc(req), (unsigned long)msgs.count, MWChatLabel(chat), [q[@"before"] longLongValue], (long)limit, summary);
        }
        return [MWResponse json:@{
            @"ok": @YES,
            @"dnd": @(dnd),
            @"messages": msgs,
            @"names": MWNamesForMessages(msgs),
            @"avatars": MWAvatarsForMessages(msgs),
        }];
    }
    if (get && [p isEqualToString:@"/api/dnd"]) {
        NSString *chat = MWStr(q[@"chat"]);
        if (!MWIsIMessageChat(chat)) return [MWResponse error:@"chat (an iMessage chat guid) is required" status:400];
        [[MWIMBridge shared] observeDNDForChat:chat];
        NSDictionary *c = [[MWDatabase shared] chatWithGUID:chat];
        NSDictionary *dec = c ? MWDecorateChat(c) : nil;
        BOOL dnd = dec ? [dec[@"dnd"] boolValue] : [[MWIMBridge shared] isDNDActiveForChat:chat identifier:nil];
        return [MWResponse json:@{@"ok": @YES, @"chat": chat, @"dnd": @(dnd)}];
    }
    if (get && [p isEqualToString:@"/api/message"]) {
        NSDictionary *msg = MWStr(q[@"guid"]) ? [[MWDatabase shared] messageWithGUID:q[@"guid"]] : nil;
        if (gVerbose && msg) {
            MWLog(@"[ACCESS] %@ fetched single message guid=%@ in %@: '%@'",
                  MWClientDesc(req), q[@"guid"], MWChatLabel(msg[@"chat"]), MWSnippet(msg[@"text"], 50));
        }
        return msg ? [MWResponse json:@{@"ok": @YES, @"message": msg, @"names": MWNamesForMessages(@[msg]), @"avatars": MWAvatarsForMessages(@[msg])}]
                   : [MWResponse error:@"message not found" status:404];
    }
    if (get && [p isEqualToString:@"/api/search"]) {
        NSString *term = MWStr(q[@"q"]);
        if (!term) return [MWResponse error:@"q is required" status:400];
        NSArray *msgs = [[MWDatabase shared] searchMessages:term limit:MIN(MAX([q[@"limit"] integerValue], 1), 200) ?: 50];
        if (gVerbose) {
            MWLog(@"[SEARCH] %@ searched messages for query='%@' -> %lu results",
                  MWClientDesc(req), term, (unsigned long)msgs.count);
        }
        return [MWResponse json:@{@"ok": @YES, @"messages": msgs, @"names": MWNamesForMessages(msgs)}];
    }
    if (get && [p isEqualToString:@"/api/contacts"]) {
        NSArray *contacts = [[MWContacts shared] search:q[@"q"] ?: @"" limit:50];
        if (gVerbose) {
            MWLog(@"[CONTACTS] %@ searched contacts for query='%@' -> %lu results",
                  MWClientDesc(req), q[@"q"] ?: @"", (unsigned long)contacts.count);
        }
        return [MWResponse json:@{@"ok": @YES, @"contacts": contacts}];
    }
    if (get && [p isEqualToString:@"/api/avatar"]) {
        NSString *handle = MWStr(q[@"handle"]);
        if (!handle) return [MWResponse error:@"handle is required" status:400];
        NSString *mime = nil;
        NSData *img = [[MWContacts shared] avatarDataForHandle:handle mimeType:&mime];
        if (!img) return [MWResponse error:@"avatar not found" status:404];
        if (gVerbose) {
            MWLog(@"[AVATAR-ACCESS] %@ loaded avatar for '%@' (%lu bytes)", MWClientDesc(req), handle, (unsigned long)img.length);
        }
        MWResponse *r = [MWResponse data:img type:mime ?: @"image/jpeg"];
        r.headers[@"Cache-Control"] = @"private, max-age=3600";
        return r;
    }
    if (get && [p isEqualToString:@"/api/attachment"]) {
        long long rowid = [q[@"id"] longLongValue];
        NSDictionary *a = [[MWDatabase shared] attachmentWithID:rowid];
        NSString *path = MWStr(a[@"path"]);
        if (!path) return [MWResponse error:@"attachment not found" status:404];
        if (gVerbose) {
            MWLog(@"[ATTACHMENT-ACCESS] %@ accessed attachment id=%lld name='%@' mime='%@' (thumb=%@, raw=%@)",
                  MWClientDesc(req), rowid, a[@"name"] ?: @"(unknown)", a[@"mime"] ?: @"(unknown)", q[@"thumb"] ?: @"0", q[@"raw"] ?: @"0");
        }
        if (![q[@"raw"] isEqualToString:@"1"]) {
            BOOL thumb = [q[@"thumb"] isEqualToString:@"1"];
            NSString *transMime = nil;
            NSString *conv = MWBrowserFriendlyImage(path, rowid, thumb, MWStr(a[@"uti"]), MWStr(a[@"mime"]), &transMime);
            if (conv) return MWServeFile(conv, transMime ?: @"image/jpeg", req, nil);
        }
        return MWServeFile(path, MWMimeForPath(path, MWStr(a[@"mime"])), req, MWStr(a[@"name"]));
    }
    if (get && [p isEqualToString:@"/api/events"]) {
        MWResponse *r = [MWResponse new];
        r.headers[@"Content-Type"] = @"text/event-stream";
        r.stream = ^(BOOL (^write)(NSData *)) {
            MWSubscriber *sub = [MWSubscriber new];
            sub.pending = [NSMutableArray array];
            sub.signal = dispatch_semaphore_create(0);
            @synchronized (gSubscribers) { [gSubscribers addObject:sub]; }
            MWLog(@"[STREAM] %@ connected to real-time event stream (/api/events)", MWClientDesc(req));
            BOOL alive = write([@"retry: 3000\nevent: hello\ndata: {}\n\n" dataUsingEncoding:NSUTF8StringEncoding]);
            while (alive) {
                long timedOut = dispatch_semaphore_wait(sub.signal, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
                NSArray *frames;
                @synchronized (sub) { frames = [sub.pending copy]; [sub.pending removeAllObjects]; }
                for (NSData *f in frames) if (!(alive = write(f))) break;
                if (alive && timedOut) alive = write([@": ping\n\n" dataUsingEncoding:NSUTF8StringEncoding]);
            }
            @synchronized (gSubscribers) { [gSubscribers removeObject:sub]; }
            MWLog(@"[STREAM] %@ disconnected from real-time event stream", MWClientDesc(req));
        };
        return r;
    }

    if (post && [p isEqualToString:@"/api/pin"]) {
        NSString *chatGUID = MWStr(body[@"chat"]);
        if (!MWIsIMessageChat(chatGUID)) return [MWResponse error:@"chat (an iMessage chat guid) is required" status:400];
        BOOL pinned = [body[@"pinned"] boolValue];
        MWLog(@"[PIN] %@ %@ conversation %@", MWClientDesc(req), pinned ? @"pinned" : @"unpinned", MWChatLabel(chatGUID));
        NSDictionary *res = [[MWIMBridge shared] setPinned:pinned forChat:chatGUID];
        if ([res[@"ok"] boolValue]) {
            NSDictionary *chat = [[MWDatabase shared] chatWithGUID:chatGUID];
            if (chat) MWBroadcast(@"chat", MWDecorateChat(chat));
            MWBroadcastPinnedUpdate();
        }
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/send"]) {
        NSString *dest = MWStr(body[@"chat"]) ?: ([body[@"to"] isKindOfClass:NSArray.class] ? [body[@"to"] componentsJoinedByString:@","] : [body[@"to"] description]);
        MWLog(@"[SEND] %@ sending iMessage to %@: text='%@'%@%@%@%@",
              MWClientDesc(req),
              MWChatLabel(dest),
              MWSnippet(body[@"text"], 80),
              body[@"subject"] ? [NSString stringWithFormat:@" subject='%@'", body[@"subject"]] : @"",
              body[@"effect"] ? [NSString stringWithFormat:@" effect='%@'", body[@"effect"]] : @"",
              body[@"replyTo"] ? [NSString stringWithFormat:@" replyTo=%@", body[@"replyTo"]] : @"",
              [body[@"notifyAnyway"] boolValue] ? @" [Notify Anyway]" : @"");
        NSDictionary *res = [[MWIMBridge shared] sendText:MWStr(body[@"text"]) subject:MWStr(body[@"subject"])
                                                   toChat:MWStr(body[@"chat"]) addresses:MWAddressList(body[@"to"])
                                                   effect:MWStr(body[@"effect"]) replyTo:MWStr(body[@"replyTo"])
                                             notifyAnyway:[body[@"notifyAnyway"] boolValue]];
        if ([res[@"ok"] boolValue]) {
            MWLog(@"[SENT] Outbound iMessage queued successfully: guid=%@ to %@", res[@"guid"], MWChatLabel(res[@"chat"] ?: dest));
        } else {
            MWLog(@"[SEND-ERROR] Failed to send iMessage to %@: %@", MWChatLabel(dest), res[@"error"]);
        }
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/notify"]) {
        NSString *msgGUID = MWStr(body[@"message"]);
        NSString *chatGUID = MWStr(body[@"chat"]);
        if (!msgGUID || !chatGUID) return [MWResponse error:@"chat and message are required" status:400];
        MWLog(@"[NOTIFY-ANYWAY] %@ triggered Focus/DND override ('Notify Anyway') for message guid=%@ in %@",
              MWClientDesc(req), msgGUID, MWChatLabel(chatGUID));
        NSDictionary *res = [[MWIMBridge shared] notifyAnywayForMessage:msgGUID inChat:chatGUID];
        if ([res[@"ok"] boolValue]) {
            NSDictionary *m = [[MWDatabase shared] messageWithGUID:msgGUID];
            if (m) {
                NSMutableDictionary *patched = [m mutableCopy];
                patched[@"didNotifyRecipient"] = @YES;
                MWBroadcast(@"updated", @{
                    @"message": patched,
                    @"names": MWNamesForMessages(@[patched]),
                    @"avatars": MWAvatarsForMessages(@[patched]),
                });
            }
        }
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/edit"]) {
        NSString *msgGUID = MWStr(body[@"message"]);
        NSString *chatGUID = MWStr(body[@"chat"]);
        NSString *text = MWStr(body[@"text"]);
        if (!msgGUID || !chatGUID || !text) return [MWResponse error:@"chat, message, and text are required" status:400];
        MWLog(@"[EDIT] %@ edited message guid=%@ in %@: newText='%@'",
              MWClientDesc(req), msgGUID, MWChatLabel(chatGUID), MWSnippet(text, 80));
        NSDictionary *res = [[MWIMBridge shared] editMessage:msgGUID newText:text inChat:chatGUID];
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/unsend"]) {
        NSString *msgGUID = MWStr(body[@"message"]);
        NSString *chatGUID = MWStr(body[@"chat"]);
        if (!msgGUID || !chatGUID) return [MWResponse error:@"chat and message are required" status:400];
        MWLog(@"[UNSEND] %@ unsent (retracted) message guid=%@ in %@",
              MWClientDesc(req), msgGUID, MWChatLabel(chatGUID));
        NSDictionary *res = [[MWIMBridge shared] unsendMessage:msgGUID inChat:chatGUID];
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/send-file"]) {
        NSString *dest = MWStr(q[@"chat"]) ?: MWStr(q[@"to"]);
        MWLog(@"[SEND-FILE] %@ sending file '%@' (%lu bytes) to %@%@",
              MWClientDesc(req),
              q[@"filename"] ?: @"attachment",
              (unsigned long)req.body.length,
              MWChatLabel(dest),
              q[@"text"] ? [NSString stringWithFormat:@" caption='%@'", MWSnippet(q[@"text"], 60)] : @"");
        NSDictionary *res = [[MWIMBridge shared] sendFile:req.body filename:MWStr(q[@"filename"]) ?: @"attachment"
                                                   toChat:MWStr(q[@"chat"]) addresses:MWAddressList(q[@"to"])
                                                     text:MWStr(q[@"text"])];
        if ([res[@"ok"] boolValue]) {
            MWLog(@"[SENT-FILE] Outbound attachment queued successfully: guid=%@ transfer=%@ to %@",
                  res[@"guid"], res[@"transfer"], MWChatLabel(dest));
        } else {
            MWLog(@"[SEND-FILE-ERROR] Failed to send attachment to %@: %@", MWChatLabel(dest), res[@"error"]);
        }
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/react"]) {
        if (!MWStr(body[@"message"]) || !MWStr(body[@"type"])) return [MWResponse error:@"message and type are required" status:400];
        MWLog(@"[REACT] %@ %@ reaction '%@' on message guid=%@ in %@",
              MWClientDesc(req), [body[@"remove"] boolValue] ? @"removed" : @"sent",
              body[@"type"], body[@"message"], MWChatLabel(body[@"chat"]));
        NSDictionary *res = [[MWIMBridge shared] react:body[@"type"] remove:[body[@"remove"] boolValue]
                                             toMessage:body[@"message"] inChat:MWStr(body[@"chat"])];
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/read"]) {
        if (!MWStr(body[@"chat"])) return [MWResponse error:@"chat is required" status:400];
        MWLog(@"[MARK-READ] %@ marked conversation read: %@", MWClientDesc(req), MWChatLabel(body[@"chat"]));
        return [MWResponse json:[[MWIMBridge shared] markRead:body[@"chat"]]];
    }
    if (post && [p isEqualToString:@"/api/typing"]) {
        if (!MWStr(body[@"chat"])) return [MWResponse error:@"chat is required" status:400];
        if (gVerbose) {
            MWLog(@"[TYPING] %@ outgoing typing indicator set to %d in %@",
                  MWClientDesc(req), [body[@"typing"] boolValue], MWChatLabel(body[@"chat"]));
        }
        return [MWResponse json:[[MWIMBridge shared] setTyping:[body[@"typing"] boolValue] inChat:body[@"chat"]]];
    }
    return [MWResponse error:@"not found" status:404];
}

#pragma mark - main

static void MWPrefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    MWLoadConfig();
    MWLog(@"reloaded preferences via Darwin notification (enabled=%d, verbose=%d, requireAuth=%d)", gEnabled, gVerbose, gRequireAuth);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gSubscribers = [NSMutableSet set];
        NSDictionary *cfg = MWLoadConfig();
        gToken = cfg[@"token"];
        uint16_t port = (uint16_t)[cfg[@"port"] intValue] ?: kDefaultPort;
        MWLog(@"starting (pid %d, uid %d)", getpid(), getuid());

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        MWPrefsNotificationCallback,
                                        CFSTR("dev.sillyangel.meowtxt/ReloadPrefs"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        if (![[MWDatabase shared] open]) {
            MWLog(@"cannot open sms.db; exiting");
            return 1;
        }
        [[MWContacts shared] preload];

        [MWIMBridge shared].onTyping = ^(NSString *chatGUID, NSString *sender, BOOL typing) {
            NSString *name = sender.length ? [[MWContacts shared] nameForHandle:sender] : nil;
            MWBroadcast(@"typing", @{
                @"chat": chatGUID,
                @"sender": sender ?: [NSNull null],
                @"name": name ?: [NSNull null],
                @"typing": @(typing),
            });
        };
        [MWIMBridge shared].onPinnedChanged = ^{
            if ([[MWIMBridge shared] reloadPinnedFromDiskIfChanged]) {
                MWBroadcastPinnedUpdate();
            }
        };
        [MWIMBridge shared].onDNDChanged = ^(NSString *handleID, BOOL dnd) {
            NSString *chatGUID = [NSString stringWithFormat:@"iMessage;-;%@", handleID];
            MWBroadcast(@"dnd", @{
                @"handle": handleID,
                @"chat": chatGUID,
                @"dnd": @(dnd),
            });
        };

        BOOL connected = [[MWIMBridge shared] connect];
        MWLog(@"imagent connected: %d", connected);

        MWHTTPServer *server = [MWHTTPServer new];
        server.handler = ^MWResponse *(MWRequest *req) {
            MWResponse *r = MWRoute(req);
            if (gVerbose) {
                if (![req.path isEqualToString:@"/api/events"] && ![req.path isEqualToString:@"/api/avatar"]) {
                    MWLog(@"[HTTP] %@ %@ %@ -> %ld (%lu bytes)",
                          MWClientDesc(req), req.method, req.path, (long)(r ? r.status : 404), (unsigned long)r.body.length);
                }
            } else {
                if (![req.path isEqualToString:@"/api/events"] && ![req.path isEqualToString:@"/api/avatar"]) {
                    MWLog(@"%@ %@ %@ -> %ld", req.remoteAddress, req.method, req.path, (long)(r ? r.status : 404));
                }
            }
            return r;
        };
        NSError *err = nil;
        if (![server listenOnPort:port error:&err]) {
            MWLog(@"listen on %u failed: %@", port, err);
            return 1;
        }
        MWLog(@"listening on port %u", port);
        MWStartPoller();

        [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *t) {
            NSDictionary *st = [[MWIMBridge shared] status];
            if (![st[@"connected"] boolValue]) {
                MWLog(@"imagent connection lost; reconnecting");
                [[MWIMBridge shared] connect];
            }
        }];
        for (;;) [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
