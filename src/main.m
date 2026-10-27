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

#pragma mark - config

static NSDictionary *MWLoadConfig(void) {
    NSMutableDictionary *cfg = [[NSDictionary dictionaryWithContentsOfFile:kPrefsPath] mutableCopy] ?: [NSMutableDictionary dictionary];
    BOOL dirty = NO;
    if (![cfg[@"token"] isKindOfClass:NSString.class] || [cfg[@"token"] length] < 8) {
        uint8_t raw[16];
        arc4random_buf(raw, sizeof(raw));
        NSMutableString *hex = [NSMutableString string];
        for (size_t i = 0; i < sizeof(raw); i++) [hex appendFormat:@"%02x", raw[i]];
        cfg[@"token"] = hex;
        dirty = YES;
    }
    if (!cfg[@"port"]) { cfg[@"port"] = @(kDefaultPort); dirty = YES; }
    if (dirty) [cfg writeToFile:kPrefsPath atomically:YES];
    return cfg;
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

#pragma mark - change poller

static void MWBroadcastPinnedUpdate(void) {
    NSArray<NSString *> *pins = [[MWIMBridge shared] pinnedIdentifiers];
    MWBroadcast(@"pinned", @{@"pinnedIdentifiers": pins});
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
            if ([[MWIMBridge shared] reloadPinnedFromDiskIfChanged]) {
                MWBroadcastPinnedUpdate();
            }
            if (![[MWDatabase shared] hasChanged]) return;
            long long now = [MWDatabase appleTimeNow];

            NSArray *fresh = [[MWDatabase shared] messagesAfterROWID:lastRowid limit:200];
            NSMutableSet *touchedChats = [NSMutableSet set];
            for (NSDictionary *m in fresh) {
                lastRowid = MAX(lastRowid, [m[@"id"] longLongValue]);
                if (!MWIsIMessageChat(m[@"chat"])) continue;
                [touchedChats addObject:m[@"chat"]];
                MWBroadcast(@"message", @{
                    @"message": m,
                    @"names": MWNamesForMessages(@[m]),
                    @"avatars": MWAvatarsForMessages(@[m]),
                });
            }

            NSArray *updated = [[MWDatabase shared] messagesUpdatedSince:lastCheck - 2000000000LL];
            lastCheck = now;
            for (NSDictionary *m in updated) {
                if (!MWIsIMessageChat(m[@"chat"])) continue;
                MWBroadcast(@"updated", @{
                    @"message": m,
                    @"names": MWNamesForMessages(@[m]),
                    @"avatars": MWAvatarsForMessages(@[m]),
                });
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
    UTType *t = [UTType typeWithFilenameExtension:path.pathExtension];
    return t.preferredMIMEType ?: @"application/octet-stream";
}

// Transcodes HEIC/HEIF/TIFF (or generates fast 640px thumbnails when `thumb` is YES) into cached JPEGs.
static NSString *MWBrowserFriendlyImage(NSString *path, long long rowid, BOOL thumb) {
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL needsTranscode = [@[@"heic", @"heif", @"tif", @"tiff"] containsObject:ext];
    if (!needsTranscode && !thumb) return nil;
    if (thumb && ![@[@"heic", @"heif", @"tif", @"tiff", @"jpg", @"jpeg", @"png"] containsObject:ext]) return nil;

    NSString *suffix = thumb ? @"_thumb.jpg" : @".jpg";
    NSString *out = [kCacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld%@", rowid, suffix]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:out]) return out;
    [[NSFileManager defaultManager] createDirectoryAtPath:kCacheDir withIntermediateDirectories:YES attributes:nil error:nil];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return nil;
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: thumb ? @640 : @1800,
    };
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!img) return nil;
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:out],
                                                                (__bridge CFStringRef)@"public.jpeg", 1, NULL);
    BOOL ok = NO;
    if (dst) {
        CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: thumb ? @0.78 : @0.85});
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(img);
    return ok ? out : nil;
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
    NSString *auth = req.headers[@"authorization"];
    NSString *tok = nil;
    if ([auth.lowercaseString hasPrefix:@"bearer "]) tok = [auth substringFromIndex:7];
    if (!tok) tok = req.headers[@"x-meow-token"];
    if (!tok) tok = req.query[@"token"];
    return tok && [tok isEqualToString:gToken];
}

static MWResponse *MWStatic(MWRequest *req) {
    NSString *rel = [req.path isEqualToString:@"/"] ? @"index.html" : [req.path substringFromIndex:1];
    if ([rel containsString:@".."]) return nil;
    NSString *path = [kWebRoot stringByAppendingPathComponent:rel];
    BOOL dir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir] || dir) return nil;
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSString *mime = MWMimeForPath(path, nil);
    if ([mime hasPrefix:@"text/"] || [mime containsString:@"javascript"]) mime = [mime stringByAppendingString:@"; charset=utf-8"];
    MWResponse *r = [MWResponse data:d type:mime];
    r.headers[@"Cache-Control"] = @"no-cache";
    return r;
}

static NSDictionary *MWOpenAPISpec(void) {
    return @{
        @"openapi": @"3.1.0",
        @"info": @{
            @"title": @"meowtxt iMessage REST & SSE API",
            @"version": @"0.2.0",
            @"description": @"On-device iOS 16 iMessage REST + Server-Sent Events (SSE) API exposed by meowd (dev.sillyangel.meowtxt). Designed for building custom web, Next.js, React, desktop, and AI agent clients.",
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
            @"/api/pin": @{@"post": @{@"summary": @"Pin or unpin a conversation (two-way synced with native iOS Messages)"}},
            @"/api/send": @{@"post": @{@"summary": @"Send an iMessage (supports subject, bubble/screen effects, inline replies, and notifyAnyway DND override)"}},
            @"/api/send-file": @{@"post": @{@"summary": @"Upload and send a binary file/photo/video/audio attachment"}},
            @"/api/notify": @{@"post": @{@"summary": @"Manually override Focus / Do Not Disturb ('Notify Anyway') for a quietly-delivered message"}},
            @"/api/edit": @{@"post": @{@"summary": @"Edit a recently sent iMessage (iOS 16+)"}},
            @"/api/unsend": @{@"post": @{@"summary": @"Unsend / retract a recently sent iMessage (iOS 16+)"}},
            @"/api/react": @{@"post": @{@"summary": @"Send or remove a tapback reaction (love, like, dislike, laugh, emphasize, question)"}},
            @"/api/read": @{@"post": @{@"summary": @"Mark a conversation as read"}},
            @"/api/typing": @{@"post": @{@"summary": @"Start or stop outgoing typing indicator"}},
            @"/api/events": @{@"get": @{@"summary": @"Server-Sent Events stream (hello, message, updated, chat, typing, pinned, dnd)"}},
        },
    };
}

static MWResponse *MWRoute(MWRequest *req) {
    NSString *p = req.path;
    NSString *m = req.method;
    if ([m isEqualToString:@"OPTIONS"]) { MWResponse *r = [MWResponse new]; r.status = 204; r.body = [NSData data]; return r; }

    if ([p isEqualToString:@"/api/openapi.json"] && ([m isEqualToString:@"GET"] || [m isEqualToString:@"HEAD"])) {
        return [MWResponse json:MWOpenAPISpec()];
    }

    if (![p hasPrefix:@"/api/"]) {
        if (![m isEqualToString:@"GET"] && ![m isEqualToString:@"HEAD"]) return [MWResponse error:@"method not allowed" status:405];
        return MWStatic(req);
    }
    if (!MWAuthorized(req)) return [MWResponse error:@"unauthorized" status:401];

    BOOL get = [m isEqualToString:@"GET"] || [m isEqualToString:@"HEAD"], post = [m isEqualToString:@"POST"];
    NSDictionary *q = req.query;
    NSDictionary *body = post ? ([[req JSONBody] isKindOfClass:NSDictionary.class] ? [req JSONBody] : @{}) : @{};

    if (get && [p isEqualToString:@"/api/status"]) {
        return [MWResponse json:[[MWIMBridge shared] status]];
    }
    if (get && [p isEqualToString:@"/api/chats"]) {
        NSInteger limit = q[@"limit"] ? MIN(MAX([q[@"limit"] integerValue], 1), 500) : 50;
        NSInteger offset = MAX([q[@"offset"] integerValue], 0);
        NSArray<NSString *> *pins = [[MWIMBridge shared] pinnedIdentifiers];
        NSMutableArray *chats = [NSMutableArray array];
        for (NSDictionary *c in [[MWDatabase shared] chatsWithLimit:limit offset:offset]) {
            [chats addObject:MWDecorateChatWithPins(c, pins)];
        }
        return [MWResponse json:@{@"ok": @YES, @"chats": chats, @"pinnedIdentifiers": pins}];
    }
    if (get && [p isEqualToString:@"/api/chat"]) {
        NSDictionary *c = MWStr(q[@"guid"]) ? [[MWDatabase shared] chatWithGUID:q[@"guid"]] : nil;
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
        return msg ? [MWResponse json:@{@"ok": @YES, @"message": msg, @"names": MWNamesForMessages(@[msg]), @"avatars": MWAvatarsForMessages(@[msg])}]
                   : [MWResponse error:@"message not found" status:404];
    }
    if (get && [p isEqualToString:@"/api/search"]) {
        NSString *term = MWStr(q[@"q"]);
        if (!term) return [MWResponse error:@"q is required" status:400];
        NSArray *msgs = [[MWDatabase shared] searchMessages:term limit:MIN(MAX([q[@"limit"] integerValue], 1), 200) ?: 50];
        return [MWResponse json:@{@"ok": @YES, @"messages": msgs, @"names": MWNamesForMessages(msgs)}];
    }
    if (get && [p isEqualToString:@"/api/contacts"]) {
        return [MWResponse json:@{@"ok": @YES, @"contacts": [[MWContacts shared] search:q[@"q"] ?: @"" limit:50]}];
    }
    if (get && [p isEqualToString:@"/api/avatar"]) {
        NSString *handle = MWStr(q[@"handle"]);
        if (!handle) return [MWResponse error:@"handle is required" status:400];
        NSString *mime = nil;
        NSData *img = [[MWContacts shared] avatarDataForHandle:handle mimeType:&mime];
        if (!img) return [MWResponse error:@"avatar not found" status:404];
        MWResponse *r = [MWResponse data:img type:mime ?: @"image/jpeg"];
        r.headers[@"Cache-Control"] = @"private, max-age=3600";
        return r;
    }
    if (get && [p isEqualToString:@"/api/attachment"]) {
        long long rowid = [q[@"id"] longLongValue];
        NSDictionary *a = [[MWDatabase shared] attachmentWithID:rowid];
        NSString *path = MWStr(a[@"path"]);
        if (!path) return [MWResponse error:@"attachment not found" status:404];
        if (![q[@"raw"] isEqualToString:@"1"]) {
            BOOL thumb = [q[@"thumb"] isEqualToString:@"1"];
            NSString *jpg = MWBrowserFriendlyImage(path, rowid, thumb);
            if (jpg) return MWServeFile(jpg, @"image/jpeg", req, nil);
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
            MWLog(@"event stream opened from %@", req.remoteAddress);
            BOOL alive = write([@"retry: 3000\nevent: hello\ndata: {}\n\n" dataUsingEncoding:NSUTF8StringEncoding]);
            while (alive) {
                long timedOut = dispatch_semaphore_wait(sub.signal, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
                NSArray *frames;
                @synchronized (sub) { frames = [sub.pending copy]; [sub.pending removeAllObjects]; }
                for (NSData *f in frames) if (!(alive = write(f))) break;
                if (alive && timedOut) alive = write([@": ping\n\n" dataUsingEncoding:NSUTF8StringEncoding]);
            }
            @synchronized (gSubscribers) { [gSubscribers removeObject:sub]; }
            MWLog(@"event stream closed from %@", req.remoteAddress);
        };
        return r;
    }

    if (post && [p isEqualToString:@"/api/pin"]) {
        NSString *chatGUID = MWStr(body[@"chat"]);
        if (!MWIsIMessageChat(chatGUID)) return [MWResponse error:@"chat (an iMessage chat guid) is required" status:400];
        BOOL pinned = [body[@"pinned"] boolValue];
        NSDictionary *res = [[MWIMBridge shared] setPinned:pinned forChat:chatGUID];
        if ([res[@"ok"] boolValue]) {
            NSDictionary *chat = [[MWDatabase shared] chatWithGUID:chatGUID];
            if (chat) MWBroadcast(@"chat", MWDecorateChat(chat));
            MWBroadcastPinnedUpdate();
        }
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/send"]) {
        NSDictionary *res = [[MWIMBridge shared] sendText:MWStr(body[@"text"]) subject:MWStr(body[@"subject"])
                                                   toChat:MWStr(body[@"chat"]) addresses:MWAddressList(body[@"to"])
                                                   effect:MWStr(body[@"effect"]) replyTo:MWStr(body[@"replyTo"])
                                             notifyAnyway:[body[@"notifyAnyway"] boolValue]];
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/notify"]) {
        NSString *msgGUID = MWStr(body[@"message"]);
        NSString *chatGUID = MWStr(body[@"chat"]);
        if (!msgGUID || !chatGUID) return [MWResponse error:@"chat and message are required" status:400];
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
        NSDictionary *res = [[MWIMBridge shared] editMessage:msgGUID newText:text inChat:chatGUID];
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/unsend"]) {
        NSString *msgGUID = MWStr(body[@"message"]);
        NSString *chatGUID = MWStr(body[@"chat"]);
        if (!msgGUID || !chatGUID) return [MWResponse error:@"chat and message are required" status:400];
        NSDictionary *res = [[MWIMBridge shared] unsendMessage:msgGUID inChat:chatGUID];
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/send-file"]) {
        NSDictionary *res = [[MWIMBridge shared] sendFile:req.body filename:MWStr(q[@"filename"]) ?: @"attachment"
                                                   toChat:MWStr(q[@"chat"]) addresses:MWAddressList(q[@"to"])
                                                     text:MWStr(q[@"text"])];
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/react"]) {
        if (!MWStr(body[@"message"]) || !MWStr(body[@"type"])) return [MWResponse error:@"message and type are required" status:400];
        NSDictionary *res = [[MWIMBridge shared] react:body[@"type"] remove:[body[@"remove"] boolValue]
                                             toMessage:body[@"message"] inChat:MWStr(body[@"chat"])];
        return [MWResponse json:res status:[res[@"ok"] boolValue] ? 200 : 400];
    }
    if (post && [p isEqualToString:@"/api/read"]) {
        if (!MWStr(body[@"chat"])) return [MWResponse error:@"chat is required" status:400];
        return [MWResponse json:[[MWIMBridge shared] markRead:body[@"chat"]]];
    }
    if (post && [p isEqualToString:@"/api/typing"]) {
        if (!MWStr(body[@"chat"])) return [MWResponse error:@"chat is required" status:400];
        return [MWResponse json:[[MWIMBridge shared] setTyping:[body[@"typing"] boolValue] inChat:body[@"chat"]]];
    }
    return [MWResponse error:@"not found" status:404];
}

#pragma mark - main

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gSubscribers = [NSMutableSet set];
        NSDictionary *cfg = MWLoadConfig();
        gToken = cfg[@"token"];
        uint16_t port = (uint16_t)[cfg[@"port"] intValue] ?: kDefaultPort;
        MWLog(@"starting (pid %d, uid %d)", getpid(), getuid());

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
            if (![req.path isEqualToString:@"/api/events"] && ![req.path isEqualToString:@"/api/avatar"])
                MWLog(@"%@ %@ %@ -> %ld", req.remoteAddress, req.method, req.path, (long)(r ? r.status : 404));
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
