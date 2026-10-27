#import "MWIMBridge.h"
#import "MWDatabase.h"
#import "MWContacts.h"
#import "MWLog.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kPinningPlistPath = @"/var/mobile/Library/Preferences/com.apple.messages.pinning.plist";

// IMCore private API surface we use. Declared as an NSObject category so we can message the
// objects without linking against class symbols; classes are looked up at runtime.
@interface NSObject (MWIMCorePrivate)
+ (instancetype)sharedInstance;
- (BOOL)connectToDaemonWithLaunch:(BOOL)launch capabilities:(unsigned long long)caps blockUntilConnected:(BOOL)block;
- (BOOL)isConnected;
// IMAccountController / IMAccount / IMHandle
- (id)activeIMessageAccount;
- (NSArray *)accounts;
- (NSString *)login;
- (NSArray *)vettedAliases;
- (BOOL)isActive;
- (id)service;
- (NSString *)name;
- (id)imHandleWithID:(NSString *)ident;
- (NSString *)ID;
- (long long)availability;
- (void)beginObservingAvailability;
// IMHandleAvailabilityManager
- (long long)availabilityForHandle:(id)handle;
- (void)beginObservingAvailabilityForHandle:(id)handle;
- (void)fetchUpdatedStatusAndUpdateCachesForHandle:(id)handle lastKnownStatus:(id)status;
// IMChatRegistry / IMChat
- (NSArray *)allExistingChats;
- (void)_loadChatsFilteredUsingPredicate:(NSPredicate *)pred lastMessageOlderThan:(NSDate *)date limit:(unsigned long long)limit waitForReply:(BOOL)wait completionHandler:(void (^)(NSArray *))cb;
- (id)existingChatWithGUID:(NSString *)guid;
- (id)existingChatWithChatIdentifier:(NSString *)ident;
- (id)existingChatWithPinningIdentifier:(NSString *)pinID;
- (void)loadChatFromDaemonWithChatIdentifier:(NSString *)ident;
- (id)chatWithHandle:(id)handle;
- (id)chatWithHandles:(NSArray *)handles;
- (NSString *)guid;
- (NSString *)chatIdentifier;
- (NSString *)pinningIdentifier;
- (NSSet *)mergedPinningIdentifiers;
- (BOOL)isPinned;
- (id)recipient;
- (void)beginObservingHandleAvailability;
- (BOOL)shouldDisplayUnavailabilityIndicator;
- (NSArray *)chatItems;
- (NSString *)lastAddressedHandleID;
- (void)setLastAddressedHandleID:(NSString *)ident;
- (void)sendMessage:(id)message;
- (void)markAllMessagesAsRead;
- (void)setLocalUserIsTyping:(BOOL)typing;
- (void)loadMessagesUpToGUID:(NSString *)guid date:(NSDate *)date limit:(unsigned long long)limit loadImmediately:(BOOL)imm;
- (id)messageForGUID:(NSString *)guid;
- (void)markChatItemAsNotifyRecipient:(id)chatItem;
- (void)_chat:(id)chat sendNotifyRecipientCommandForMessage:(id)messageItem;
- (void)editMessage:(id)message atPartIndex:(NSInteger)partIndex withNewPartText:(NSAttributedString *)newPartText backwardCompatabilityText:(NSString *)bcText;
- (void)_chat:(id)chat sendEditedMessage:(id)edited previousMessage:(id)prev partIndex:(NSInteger)partIndex editType:(NSUInteger)editType backwardCompatabilityText:(NSString *)bcText;
// IMPinnedConversationsController
- (NSOrderedSet *)pinnedConversationIdentifierSet;
- (void)synchronizeLocalDataStore;
- (void)setPinnedChats:(NSArray *)chats withUpdateReason:(NSString *)reason;
- (void)_setPinnedConversationIdentifiers:(NSArray *)identifiers withChatMetadata:(NSDictionary *)metadata updateReason:(NSString *)reason shouldUpdateStores:(BOOL)updateStores;
- (NSDictionary *)chatMetadata;
// IMMessageItem / IMMessage / IMTranscriptChatItem
- (BOOL)isIncomingTypingMessage;
- (BOOL)isCancelTypingMessage;
- (BOOL)isIncomingTypingOrCancelTypingMessage;
- (id)_imMessageItem;
- (id)_item;
- (instancetype)initWithSender:(NSString *)sender time:(NSDate *)time guid:(NSString *)guid type:(long long)type;
+ (id)instantMessageWithText:(NSAttributedString *)text messageSubject:(NSAttributedString *)subject flags:(unsigned long long)flags expressiveSendStyleID:(NSString *)effect threadIdentifier:(NSString *)thread;
+ (id)instantMessageWithText:(NSAttributedString *)text messageSubject:(NSAttributedString *)subject fileTransferGUIDs:(NSArray *)guids flags:(unsigned long long)flags threadIdentifier:(NSString *)thread;
+ (id)instantMessageWithAssociatedMessageContent:(NSAttributedString *)content flags:(unsigned long long)flags associatedMessageGUID:(NSString *)assocGUID associatedMessageType:(long long)type associatedMessageRange:(NSRange)range messageSummaryInfo:(NSDictionary *)summary threadIdentifier:(NSString *)thread;
+ (id)editedMessageWithOriginalMessage:(id)orig editedPartIndex:(NSInteger)partIndex newPartText:(NSAttributedString *)newText;
+ (id)editedMessageWithOriginalMessage:(id)orig retractedPartIndex:(NSInteger)partIndex shouldRetractSubject:(BOOL)retractSubj;
// IMFileTransferCenter / IMFileTransfer / IMDPersistentAttachmentController
- (NSString *)guidForNewOutgoingTransferWithLocalURL:(NSURL *)url;
- (id)transferForGUID:(NSString *)guid;
- (void)registerTransferWithDaemon:(NSString *)guid;
- (void)_setLocalURL:(NSURL *)url;
- (NSString *)_persistentPathForTransfer:(id)transfer filename:(NSString *)filename highQuality:(BOOL)hq chatGUID:(NSString *)chatGUID storeAtExternalPath:(BOOL)external;
@end

static const unsigned long long kMWCapabilities = 4485895ULL;
static const unsigned long long kMWMessageFlags = 0x100005;

static id MWOnMain(id (^block)(void)) {
    if (NSThread.isMainThread) return block();
    __block id result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); });
    return result;
}

static NSDictionary *MWErr(NSString *msg) { return @{@"ok": @NO, @"error": msg}; }

static NSString *MWStripAliasPrefix(NSString *s) {
    if ([s hasPrefix:@"E:"] || [s hasPrefix:@"P:"]) return [s substringFromIndex:2];
    if ([s hasPrefix:@"mailto:"]) return [s substringFromIndex:7];
    if ([s hasPrefix:@"tel:"]) return [s substringFromIndex:4];
    return s;
}

static NSString *MWEffectID(NSString *effect) {
    if (!effect.length) return nil;
    if ([effect containsString:@"."]) return effect;
    NSDictionary *map = @{
        @"slam": @"com.apple.MobileSMS.expressivesend.impact",
        @"loud": @"com.apple.MobileSMS.expressivesend.loud",
        @"gentle": @"com.apple.MobileSMS.expressivesend.gentle",
        @"invisible": @"com.apple.MobileSMS.expressivesend.invisibleink",
        @"echo": @"com.apple.messages.effect.CKEchoEffect",
        @"spotlight": @"com.apple.messages.effect.CKSpotlightEffect",
        @"balloons": @"com.apple.messages.effect.CKHappyBirthdayEffect",
        @"confetti": @"com.apple.messages.effect.CKConfettiEffect",
        @"love": @"com.apple.messages.effect.CKHeartEffect",
        @"lasers": @"com.apple.messages.effect.CKLasersEffect",
        @"fireworks": @"com.apple.messages.effect.CKFireworksEffect",
        @"celebration": @"com.apple.messages.effect.CKSparklesEffect",
    };
    return map[effect.lowercaseString];
}

#pragma mark - Runtime hooks for capabilities, pinned chats, Focus/DND, and incoming typing indicators

static BOOL (*orig_handleIncomingItem)(id, SEL, id, BOOL, BOOL, BOOL);

static BOOL swz_returnYES(id self, SEL _cmd) {
    return YES;
}

static unsigned long long swz_processCapabilities(id self, SEL _cmd) {
    return kMWCapabilities;
}

static unsigned int swz_legacyCapabilities(id self, SEL _cmd) {
    return 17159U;
}

static BOOL swz_handleIncomingItem(id self, SEL _cmd, id item, BOOL updateRecipient, BOOL suppress, BOOL updateReplyCounts) {
    if (item && [self respondsToSelector:@selector(guid)]) {
        NSString *guid = [self guid];
        if ([guid hasPrefix:@"iMessage;"]) {
            BOOL isIncomingTyping = [item respondsToSelector:@selector(isIncomingTypingMessage)] && [item isIncomingTypingMessage];
            BOOL isCancelTyping = [item respondsToSelector:@selector(isCancelTypingMessage)] && [item isCancelTypingMessage];
            if (isIncomingTyping || isCancelTyping) {
                NSString *sender = [item respondsToSelector:@selector(sender)] ? (NSString *)[item valueForKey:@"sender"] : nil;
                MWLog(@"incoming typing indicator on %@ (sender=%@, typing=%d)", guid, sender, isIncomingTyping);
                MWTypingHandler cb = [MWIMBridge shared].onTyping;
                if (cb) cb(guid, sender, isIncomingTyping);
            }
        }
    }
    return orig_handleIncomingItem ? orig_handleIncomingItem(self, _cmd, item, updateRecipient, suppress, updateReplyCounts) : YES;
}

static void MWInstallIMCoreHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class pccCls = objc_getClass("IMPinnedConversationsController");
        if (pccCls) {
            Method m = class_getClassMethod(pccCls, NSSelectorFromString(@"processSupportsPinnedConversations"));
            if (m) method_setImplementation(m, (IMP)swz_returnYES);
        }
        Class dcCls = objc_getClass("IMDaemonController");
        if (dcCls) {
            Method m1 = class_getInstanceMethod(dcCls, NSSelectorFromString(@"processCapabilities"));
            if (m1) method_setImplementation(m1, (IMP)swz_processCapabilities);
            Method m2 = class_getInstanceMethod(dcCls, NSSelectorFromString(@"_capabilities"));
            if (m2) method_setImplementation(m2, (IMP)swz_legacyCapabilities);
        }
        Class chatCls = objc_getClass("IMChat");
        if (chatCls) {
            Method mf = class_getInstanceMethod(chatCls, NSSelectorFromString(@"isMessagesAuthorizedToAccessFocusStatus"));
            if (mf) method_setImplementation(mf, (IMP)swz_returnYES);

            SEL sel = NSSelectorFromString(@"_handleIncomingItem:updateRecipient:suppressNotification:updateReplyCounts:");
            Method m = class_getInstanceMethod(chatCls, sel);
            if (m) {
                orig_handleIncomingItem = (void *)method_getImplementation(m);
                method_setImplementation(m, (IMP)swz_handleIncomingItem);
            }
        }
    });
}

@implementation MWIMBridge {
    BOOL _connected;
    NSMutableSet<NSString *> *_currentlyTypingChats;
    NSMutableDictionary<NSString *, NSNumber *> *_dndByHandle;
    NSDate *_lastPinMtime;
    NSArray<NSString *> *_cachedPinnedIDs;
}

+ (instancetype)shared {
    static MWIMBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MWIMBridge new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _currentlyTypingChats = [NSMutableSet set];
        _dndByHandle = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)connect {
    dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/IMDPersistence.framework/IMDPersistence", RTLD_NOW);
    MWInstallIMCoreHooks();
    return [MWOnMain(^id {
        id dc = [NSClassFromString(@"IMDaemonController") sharedInstance];
        BOOL ok = [dc connectToDaemonWithLaunch:YES capabilities:kMWCapabilities blockUntilConnected:YES];
        id reg = [NSClassFromString(@"IMChatRegistry") sharedInstance];
        [NSClassFromString(@"IMAccountController") sharedInstance];
        [NSClassFromString(@"IMFileTransferCenter") sharedInstance];
        [NSClassFromString(@"IMHandleAvailabilityManager") sharedInstance];
        id pcc = [NSClassFromString(@"IMPinnedConversationsController") sharedInstance];
        if ([pcc respondsToSelector:@selector(synchronizeLocalDataStore)]) {
            [pcc synchronizeLocalDataStore];
        }
        if ([reg respondsToSelector:@selector(_loadChatsFilteredUsingPredicate:lastMessageOlderThan:limit:waitForReply:completionHandler:)]) {
            [reg _loadChatsFilteredUsingPredicate:nil lastMessageOlderThan:nil limit:200 waitForReply:NO completionHandler:^(NSArray *chats) {
                MWLog(@"preloaded %lu chats from imagent", (unsigned long)chats.count);
                id ham = [NSClassFromString(@"IMHandleAvailabilityManager") sharedInstance];
                NSUInteger count = 0;
                for (id c in chats) {
                    if (count++ >= 35) break;
                    if ([c respondsToSelector:@selector(beginObservingHandleAvailability)]) {
                        [c beginObservingHandleAvailability];
                    }
                    id rec = [c respondsToSelector:@selector(recipient)] ? [c recipient] : nil;
                    if (rec && [ham respondsToSelector:@selector(beginObservingAvailabilityForHandle:)]) {
                        [ham beginObservingAvailabilityForHandle:rec];
                    }
                }
            }];
        }
        [self registerNotifications];
        [self reloadPinnedFromDiskIfChanged];
        self->_connected = ok && [dc isConnected];
        return @(self->_connected);
    }) boolValue];
}

- (void)registerNotifications {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        Class typingCls = NSClassFromString(@"IMTypingChatItem");
        [nc addObserverForName:@"__kIMChatItemsDidChangeNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            id chat = note.object;
            if (![chat respondsToSelector:@selector(guid)] || ![[chat guid] hasPrefix:@"iMessage;"]) return;
            NSString *guid = [chat guid];
            BOOL hasTyping = NO;
            if (typingCls && [chat respondsToSelector:@selector(chatItems)]) {
                for (id ci in [chat chatItems]) {
                    if ([ci isKindOfClass:typingCls]) { hasTyping = YES; break; }
                }
            }
            BOOL wasTyping = [self->_currentlyTypingChats containsObject:guid];
            if (hasTyping != wasTyping) {
                if (hasTyping) [self->_currentlyTypingChats addObject:guid];
                else [self->_currentlyTypingChats removeObject:guid];
                if (self.onTyping) self.onTyping(guid, [chat chatIdentifier], hasTyping);
            }
        }];
        [nc addObserverForName:@"__kIMPinnedConversationsDidChangeNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (self.onPinnedChanged) self.onPinnedChanged();
        }];
        void (^availBlock)(NSNotification *) = ^(NSNotification *note) {
            id handle = note.object;
            NSString *hid = [handle respondsToSelector:@selector(ID)] ? [handle ID] : nil;
            if (!hid.length) return;
            id ham = [NSClassFromString(@"IMHandleAvailabilityManager") sharedInstance];
            long long av = [ham respondsToSelector:@selector(availabilityForHandle:)] ? [ham availabilityForHandle:handle] : 0;
            BOOL isDND = (av == 2);
            @synchronized (self->_dndByHandle) {
                self->_dndByHandle[hid.lowercaseString] = @(isDND);
            }
            if (self.onDNDChanged) self.onDNDChanged(hid, isDND);
        };
        [nc addObserverForName:@"__kIMHandleAvailabilityChangedNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:availBlock];
        [nc addObserverForName:@"__kIMHandleAvailabilityStateChangedNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:availBlock];
    });
}

#pragma mark - Focus / Do Not Disturb (StatusKit) & Notify Anyway

- (void)observeDNDForChat:(NSString *)chatGUID {
    if (!chatGUID.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        id chat = [self existingChat:chatGUID];
        if (!chat) return;
        if ([chat respondsToSelector:@selector(beginObservingHandleAvailability)]) {
            [chat beginObservingHandleAvailability];
        }
        id rec = [chat respondsToSelector:@selector(recipient)] ? [chat recipient] : nil;
        id ham = [NSClassFromString(@"IMHandleAvailabilityManager") sharedInstance];
        if (rec && [ham respondsToSelector:@selector(beginObservingAvailabilityForHandle:)]) {
            [ham beginObservingAvailabilityForHandle:rec];
        }
    });
}

- (BOOL)isDNDActiveForChat:(NSString *)chatGUID identifier:(NSString *)identifier {
    if (identifier.length) {
        @synchronized (_dndByHandle) {
            NSNumber *cached = _dndByHandle[identifier.lowercaseString];
            if (cached != nil) return cached.boolValue;
        }
    }
    return [MWOnMain(^id {
        id chat = [self existingChat:chatGUID];
        if (!chat) return @NO;
        if ([chat respondsToSelector:@selector(shouldDisplayUnavailabilityIndicator)] && [chat shouldDisplayUnavailabilityIndicator]) {
            return @YES;
        }
        id rec = [chat respondsToSelector:@selector(recipient)] ? [chat recipient] : nil;
        if (rec) {
            id ham = [NSClassFromString(@"IMHandleAvailabilityManager") sharedInstance];
            long long av = [ham respondsToSelector:@selector(availabilityForHandle:)] ? [ham availabilityForHandle:rec] : 0;
            if (av == 2) {
                if (identifier.length) {
                    @synchronized (self->_dndByHandle) { self->_dndByHandle[identifier.lowercaseString] = @YES; }
                }
                return @YES;
            }
        }
        return @NO;
    }) boolValue];
}

- (id)loadIMMessageForGUID:(NSString *)messageGUID inChat:(id)chat {
    __block id msg = nil;
    for (int attempt = 0; attempt < 6 && !msg; attempt++) {
        msg = MWOnMain(^id {
            if ([chat respondsToSelector:@selector(loadMessagesUpToGUID:date:limit:loadImmediately:)]) {
                [chat loadMessagesUpToGUID:messageGUID date:nil limit:0 loadImmediately:YES];
            }
            return [chat respondsToSelector:@selector(messageForGUID:)] ? [chat messageForGUID:messageGUID] : nil;
        });
        if (!msg) usleep(60 * 1000);
    }
    return msg;
}

- (NSDictionary *)notifyAnywayForMessage:(NSString *)messageGUID inChat:(NSString *)chatGUID {
    if (!chatGUID.length && messageGUID.length) {
        NSDictionary *m = [[MWDatabase shared] messageWithGUID:messageGUID];
        chatGUID = m[@"chat"];
    }
    if (!messageGUID.length && chatGUID.length) {
        NSArray *msgs = [[MWDatabase shared] messagesForChat:chatGUID before:0 limit:15];
        for (NSDictionary *m in msgs) {
            if ([m[@"fromMe"] boolValue] && [m[@"guid"] isKindOfClass:NSString.class]) {
                messageGUID = m[@"guid"];
                break;
            }
        }
    }
    if (!messageGUID.length || !chatGUID.length) return MWErr(@"chat and message GUID are required");

    NSString *err = nil;
    id chat = [self resolveChat:chatGUID addresses:nil error:&err];
    if (!chat) return MWErr(err);

    id imMsg = [self loadIMMessageForGUID:messageGUID inChat:chat];
    return MWOnMain(^id {
        id msgItem = (imMsg && [imMsg respondsToSelector:@selector(_imMessageItem)]) ? [imMsg _imMessageItem] : nil;
        if (!msgItem) {
            Class itemCls = NSClassFromString(@"IMMessageItem");
            if (itemCls && [itemCls instancesRespondToSelector:@selector(initWithSender:time:guid:type:)]) {
                msgItem = [[itemCls alloc] initWithSender:nil time:[NSDate date] guid:messageGUID type:0];
            }
        }
        if (!msgItem) return MWErr(@"could not load message item to notify recipient");

        // Also check if IMChat has a matching chatItem for markChatItemAsNotifyRecipient:
        BOOL markedViaChatItem = NO;
        Class notifyCls = NSClassFromString(@"IMNotifyAnywayChatItem");
        if ([chat respondsToSelector:@selector(chatItems)] && [chat respondsToSelector:@selector(markChatItemAsNotifyRecipient:)]) {
            for (id ci in [chat chatItems]) {
                if (notifyCls && [ci isKindOfClass:notifyCls]) {
                    [chat markChatItemAsNotifyRecipient:ci];
                    markedViaChatItem = YES;
                    break;
                }
            }
        }
        id reg = [NSClassFromString(@"IMChatRegistry") sharedInstance];
        if (!markedViaChatItem && [reg respondsToSelector:@selector(_chat:sendNotifyRecipientCommandForMessage:)]) {
            [reg _chat:chat sendNotifyRecipientCommandForMessage:msgItem];
        }
        MWLog(@"sent Notify Anyway (DND override) for message %@ in %@", messageGUID, [chat guid]);
        return @{@"ok": @YES, @"chat": [chat guid], @"message": messageGUID, @"didNotifyRecipient": @YES};
    });
}

#pragma mark - Edit & Unsend (iOS 16+)

- (NSDictionary *)editMessage:(NSString *)messageGUID newText:(NSString *)newText inChat:(NSString *)chatGUID {
    if (!messageGUID.length || !newText.length) return MWErr(@"message and text are required");
    NSDictionary *origDict = [[MWDatabase shared] messageWithGUID:messageGUID];
    if (!origDict) return MWErr(@"message not found");
    if (![origDict[@"fromMe"] boolValue]) return MWErr(@"can only edit messages sent by you");
    if (!chatGUID.length) chatGUID = origDict[@"chat"];

    NSString *err = nil;
    id chat = [self resolveChat:chatGUID addresses:nil error:&err];
    if (!chat) return MWErr(err);

    id imMsg = [self loadIMMessageForGUID:messageGUID inChat:chat];
    if (!imMsg) return MWErr(@"could not load original IMMessage from imagent");

    return MWOnMain(^id {
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:newText
                                                                   attributes:@{@"__kIMMessagePartAttributeName": @0}];
        NSString *bcText = [NSString stringWithFormat:@"Edited to \u201C%@\u201D", newText];
        if ([chat respondsToSelector:@selector(editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:)]) {
            [chat editMessage:imMsg atPartIndex:0 withNewPartText:attr backwardCompatabilityText:bcText];
            MWLog(@"edited message %@ in %@", messageGUID, [chat guid]);
            return @{@"ok": @YES, @"guid": messageGUID, @"chat": [chat guid]};
        }
        return MWErr(@"editMessage selector not supported");
    });
}

- (NSDictionary *)unsendMessage:(NSString *)messageGUID inChat:(NSString *)chatGUID {
    if (!messageGUID.length) return MWErr(@"message is required");
    NSDictionary *origDict = [[MWDatabase shared] messageWithGUID:messageGUID];
    if (!origDict) return MWErr(@"message not found");
    if (![origDict[@"fromMe"] boolValue]) return MWErr(@"can only unsend messages sent by you");
    if (!chatGUID.length) chatGUID = origDict[@"chat"];

    NSString *err = nil;
    id chat = [self resolveChat:chatGUID addresses:nil error:&err];
    if (!chat) return MWErr(err);

    id imMsg = [self loadIMMessageForGUID:messageGUID inChat:chat];
    if (!imMsg) return MWErr(@"could not load original IMMessage from imagent");

    return MWOnMain(^id {
        Class msgCls = NSClassFromString(@"IMMessage");
        id reg = [NSClassFromString(@"IMChatRegistry") sharedInstance];
        if ([msgCls respondsToSelector:@selector(editedMessageWithOriginalMessage:retractedPartIndex:shouldRetractSubject:)] &&
            [reg respondsToSelector:@selector(_chat:sendEditedMessage:previousMessage:partIndex:editType:backwardCompatabilityText:)]) {
            id retracted = [msgCls editedMessageWithOriginalMessage:imMsg retractedPartIndex:0 shouldRetractSubject:YES];
            [reg _chat:chat sendEditedMessage:retracted previousMessage:imMsg partIndex:0 editType:2 backwardCompatabilityText:nil];
            MWLog(@"unsent (retracted) message %@ in %@", messageGUID, [chat guid]);
            return @{@"ok": @YES, @"guid": messageGUID, @"chat": [chat guid]};
        }
        return MWErr(@"retract selector not supported");
    });
}

#pragma mark - Pinned Conversations

- (NSArray<NSString *> *)readPinnedIDsFromPlist {
    CFPreferencesAppSynchronize(CFSTR("com.apple.messages.pinning"));
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kPinningPlistPath];
    NSDictionary *pD = [plist[@"pD"] isKindOfClass:NSDictionary.class] ? plist[@"pD"] : nil;
    NSArray *pP = [pD[@"pP"] isKindOfClass:NSArray.class] ? pD[@"pP"] : nil;
    if (pP) return pP;
    NSOrderedSet *set = MWOnMain(^id {
        id pcc = [NSClassFromString(@"IMPinnedConversationsController") sharedInstance];
        return [pcc respondsToSelector:@selector(pinnedConversationIdentifierSet)] ? [pcc pinnedConversationIdentifierSet] : nil;
    });
    return set.array ?: @[];
}

- (BOOL)reloadPinnedFromDiskIfChanged {
    NSDate *mtime = [[NSFileManager defaultManager] attributesOfItemAtPath:kPinningPlistPath error:nil].fileModificationDate;
    @synchronized (self) {
        if (_cachedPinnedIDs && ((mtime && [_lastPinMtime isEqualToDate:mtime]) || (!mtime && !_lastPinMtime))) {
            return NO;
        }
        _lastPinMtime = mtime;
        NSArray<NSString *> *fresh = [self readPinnedIDsFromPlist];
        BOOL changed = !_cachedPinnedIDs || ![_cachedPinnedIDs isEqualToArray:fresh];
        _cachedPinnedIDs = fresh;
        if (changed) {
            MWOnMain(^id {
                id pcc = [NSClassFromString(@"IMPinnedConversationsController") sharedInstance];
                if ([pcc respondsToSelector:@selector(synchronizeLocalDataStore)]) [pcc synchronizeLocalDataStore];
                return nil;
            });
        }
        return changed;
    }
}

- (NSArray<NSString *> *)pinnedIdentifiers {
    [self reloadPinnedFromDiskIfChanged];
    @synchronized (self) {
        return _cachedPinnedIDs ?: @[];
    }
}

- (NSString *)pinIdentifierForChatDict:(NSDictionary *)chatDict imChat:(id)imChat {
    if (imChat && [imChat respondsToSelector:@selector(pinningIdentifier)]) {
        NSString *p = [imChat pinningIdentifier];
        if (p.length) return p;
    }
    BOOL isGroup = [chatDict[@"isGroup"] boolValue];
    if (isGroup) {
        NSString *og = [chatDict[@"originalGroupID"] isKindOfClass:NSString.class] ? chatDict[@"originalGroupID"] : nil;
        if (og.length) return og;
        NSString *g = [chatDict[@"groupID"] isKindOfClass:NSString.class] ? chatDict[@"groupID"] : nil;
        if (g.length) return g;
    }
    return [chatDict[@"identifier"] isKindOfClass:NSString.class] ? chatDict[@"identifier"] : nil;
}

- (NSDictionary *)setPinned:(BOOL)pinned forChat:(NSString *)chatGUID {
    NSDictionary *chatDict = [[MWDatabase shared] chatWithGUID:chatGUID];
    if (!chatDict) return MWErr(@"chat not found");
    NSString *err = nil;
    id imChat = [self resolveChat:chatGUID addresses:nil error:&err];
    NSString *pinID = [self pinIdentifierForChatDict:chatDict imChat:imChat];
    if (!pinID.length) return MWErr(@"could not determine pinning identifier for chat");

    NSMutableSet<NSString *> *equiv = [NSMutableSet setWithObject:pinID];
    if ([chatDict[@"identifier"] isKindOfClass:NSString.class]) {
        [equiv addObject:chatDict[@"identifier"]];
        if (![chatDict[@"isGroup"] boolValue]) {
            for (NSString *sib in [[MWContacts shared] siblingHandlesForHandle:chatDict[@"identifier"]]) {
                [equiv addObject:sib];
                if (sib.length == 10 && ![sib containsString:@"@"]) [equiv addObject:[@"+1" stringByAppendingString:sib]];
            }
        }
    }
    if ([chatDict[@"groupID"] isKindOfClass:NSString.class]) [equiv addObject:chatDict[@"groupID"]];
    if ([chatDict[@"originalGroupID"] isKindOfClass:NSString.class]) [equiv addObject:chatDict[@"originalGroupID"]];
    if (imChat) {
        NSSet *merged = MWOnMain(^id {
            return [imChat respondsToSelector:@selector(mergedPinningIdentifiers)] ? [imChat mergedPinningIdentifiers] : nil;
        });
        for (NSString *m in merged) [equiv addObject:m];
    }

    NSMutableArray<NSString *> *current = [[self readPinnedIDsFromPlist] mutableCopy];
    NSIndexSet *matchingIdxs = [current indexesOfObjectsPassingTest:^BOOL(NSString *obj, NSUInteger idx, BOOL *stop) {
        if ([equiv containsObject:obj]) return YES;
        for (NSString *e in equiv) {
            if ([e caseInsensitiveCompare:obj] == NSOrderedSame) return YES;
        }
        return NO;
    }];

    if (pinned) {
        if (matchingIdxs.count == 0) {
            if (current.count >= 9) return MWErr(@"maximum of 9 pinned conversations reached");
            [current addObject:pinID];
        }
    } else {
        [current removeObjectsAtIndexes:matchingIdxs];
    }

    MWOnMain(^id {
        id pcc = [NSClassFromString(@"IMPinnedConversationsController") sharedInstance];
        NSDictionary *meta = ([pcc respondsToSelector:@selector(chatMetadata)] ? [pcc chatMetadata] : nil) ?: @{};
        if ([pcc respondsToSelector:@selector(_setPinnedConversationIdentifiers:withChatMetadata:updateReason:shouldUpdateStores:)]) {
            [pcc _setPinnedConversationIdentifiers:current withChatMetadata:meta updateReason:@"contextMenu" shouldUpdateStores:YES];
        }
        NSMutableDictionary *plist = [[NSDictionary dictionaryWithContentsOfFile:kPinningPlistPath] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableDictionary *pD = [plist[@"pD"] isKindOfClass:NSDictionary.class] ? [plist[@"pD"] mutableCopy] : [NSMutableDictionary dictionary];
        pD[@"pP"] = current;
        pD[@"pT"] = [NSDate date];
        pD[@"pU"] = @"contextMenu";
        if (!pD[@"pV"]) pD[@"pV"] = @2;
        if (!pD[@"pR"]) pD[@"pR"] = @2;
        if (!pD[@"pZ"]) pD[@"pZ"] = meta;
        plist[@"pD"] = pD;
        [plist writeToFile:kPinningPlistPath atomically:YES];
        CFPreferencesSetAppValue(CFSTR("pD"), (__bridge CFPropertyListRef)pD, CFSTR("com.apple.messages.pinning"));
        CFPreferencesAppSynchronize(CFSTR("com.apple.messages.pinning"));
        if ([pcc respondsToSelector:@selector(synchronizeLocalDataStore)]) [pcc synchronizeLocalDataStore];
        return nil;
    });

    @synchronized (self) {
        _cachedPinnedIDs = [current copy];
        _lastPinMtime = [[NSFileManager defaultManager] attributesOfItemAtPath:kPinningPlistPath error:nil].fileModificationDate;
    }
    MWLog(@"%@ chat %@ (pinID=%@, total=%lu)", pinned ? @"pinned" : @"unpinned", chatGUID, pinID, (unsigned long)current.count);
    return @{@"ok": @YES, @"pinned": @(pinned), @"pinnedIdentifiers": current};
}

#pragma mark - accounts

- (id)iMessageAccount {
    id ac = [NSClassFromString(@"IMAccountController") sharedInstance];
    id acct = [ac activeIMessageAccount];
    if (acct) return acct;
    for (id a in [ac accounts])
        if ([[[a service] name] isEqualToString:@"iMessage"] && [a isActive]) return a;
    return nil;
}

- (NSString *)preferredAlias {
    id acct = [self iMessageAccount];
    NSMutableArray *aliases = [NSMutableArray array];
    for (id a in [acct vettedAliases] ?: @[]) [aliases addObject:MWStripAliasPrefix([a description])];
    for (NSString *a in aliases) if ([a containsString:@"@"]) return a;
    NSString *login = MWStripAliasPrefix([acct login] ?: @"");
    return login.length ? login : aliases.firstObject;
}

- (NSDictionary *)status {
    return MWOnMain(^id {
        id dc = [NSClassFromString(@"IMDaemonController") sharedInstance];
        id acct = [self iMessageAccount];
        NSMutableArray *aliases = [NSMutableArray array];
        for (id a in [acct vettedAliases] ?: @[]) [aliases addObject:MWStripAliasPrefix([a description])];
        return @{
            @"ok": @YES,
            @"connected": @([dc isConnected]),
            @"iMessageActive": @(acct != nil && [acct isActive]),
            @"account": MWStripAliasPrefix([acct login] ?: @"") ?: @"",
            @"aliases": aliases,
            @"sendingFrom": [self preferredAlias] ?: [NSNull null],
            @"loadedChats": @([[[NSClassFromString(@"IMChatRegistry") sharedInstance] allExistingChats] count]),
        };
    });
}

#pragma mark - chat resolution

- (id)existingChat:(NSString *)guid {
    id reg = [NSClassFromString(@"IMChatRegistry") sharedInstance];
    id chat = [reg existingChatWithGUID:guid];
    if (chat) return chat;
    NSArray *parts = [guid componentsSeparatedByString:@";"];
    if (parts.count == 3) chat = [reg existingChatWithChatIdentifier:parts[2]];
    if (chat && ![[chat guid] hasPrefix:@"iMessage;"]) chat = nil;
    return chat;
}

- (id)resolveChat:(NSString *)guid addresses:(NSArray<NSString *> *)addresses error:(NSString **)error {
    if (!_connected && ![self connect]) { *error = @"not connected to imagent"; return nil; }
    if (guid.length && ![guid hasPrefix:@"iMessage;"]) { *error = @"only iMessage chats are supported"; return nil; }

    id chat = nil;
    if (guid.length) {
        chat = MWOnMain(^id { return [self existingChat:guid]; });
        if (!chat) {
            NSArray *parts = [guid componentsSeparatedByString:@";"];
            if (parts.count == 3) {
                MWOnMain(^id {
                    [[NSClassFromString(@"IMChatRegistry") sharedInstance] loadChatFromDaemonWithChatIdentifier:parts[2]];
                    return nil;
                });
                for (int i = 0; i < 20 && !chat; i++) {
                    usleep(50 * 1000);
                    chat = MWOnMain(^id { return [self existingChat:guid]; });
                }
                if (!chat && [parts[1] isEqualToString:@"-"]) addresses = @[parts[2]];
            }
        }
    }
    if (!chat && addresses.count) {
        chat = MWOnMain(^id {
            id acct = [self iMessageAccount];
            if (!acct) return nil;
            NSMutableArray *handles = [NSMutableArray array];
            for (NSString *addr in addresses) {
                NSString *a = [addr stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (!a.length) continue;
                id h = [acct imHandleWithID:a];
                if (h) [handles addObject:h];
            }
            if (!handles.count) return nil;
            id reg = [NSClassFromString(@"IMChatRegistry") sharedInstance];
            return handles.count == 1 ? [reg chatWithHandle:handles[0]] : [reg chatWithHandles:handles];
        });
    }
    if (!chat) { *error = guid.length ? @"chat not found" : @"no valid recipients (or iMessage is not signed in)"; return nil; }

    MWOnMain(^id {
        NSString *alias = [self preferredAlias];
        NSString *cur = MWStripAliasPrefix([chat lastAddressedHandleID] ?: @"");
        if (alias.length && ![cur containsString:@"@"]) [chat setLastAddressedHandleID:alias];
        return nil;
    });
    return chat;
}

#pragma mark - sending

- (NSString *)threadIdentifierForReplyTo:(NSString *)replyGUID {
    if (!replyGUID.length) return nil;
    NSDictionary *orig = [[MWDatabase shared] messageWithGUID:replyGUID];
    if (!orig) return nil;
    NSString *root = [orig[@"replyTo"] isKindOfClass:NSString.class] ? orig[@"replyTo"] : replyGUID;
    if (![root isEqualToString:replyGUID]) {
        NSDictionary *r = [[MWDatabase shared] messageWithGUID:root];
        if (r) orig = r;
    }
    NSString *text = [orig[@"text"] isKindOfClass:NSString.class] ? orig[@"text"] : @"";
    NSUInteger len = text.length ?: 1;
    return [NSString stringWithFormat:@"0:0:%lu:%@", (unsigned long)len, root];
}

- (NSDictionary *)sendText:(NSString *)text subject:(NSString *)subject toChat:(NSString *)chatGUID
                 addresses:(NSArray<NSString *> *)addresses effect:(NSString *)effect
                   replyTo:(NSString *)replyGUID notifyAnyway:(BOOL)notifyAnyway {
    if (!text.length) return MWErr(@"text is required");
    NSString *err = nil;
    id chat = [self resolveChat:chatGUID addresses:addresses error:&err];
    if (!chat) return MWErr(err);
    NSString *thread = [self threadIdentifierForReplyTo:replyGUID];
    NSString *effectID = MWEffectID(effect);
    NSDictionary *res = MWOnMain(^id {
        NSAttributedString *body = [[NSAttributedString alloc] initWithString:text
                                                                   attributes:@{@"__kIMMessagePartAttributeName": @0}];
        NSAttributedString *subj = subject.length ? [[NSAttributedString alloc] initWithString:subject] : nil;
        id msg = [NSClassFromString(@"IMMessage") instantMessageWithText:body messageSubject:subj flags:kMWMessageFlags
                                                   expressiveSendStyleID:effectID threadIdentifier:thread];
        if (!msg) return MWErr(@"could not create message");
        [chat sendMessage:msg];
        MWLog(@"sent text to %@ (%@)", [chat guid], [msg guid]);
        return @{@"ok": @YES, @"guid": [msg guid] ?: [NSNull null], @"chat": [chat guid] ?: [NSNull null]};
    });
    if ([res[@"ok"] boolValue] && notifyAnyway && [res[@"guid"] isKindOfClass:NSString.class]) {
        NSString *sentGUID = res[@"guid"];
        NSString *resolvedChatGUID = res[@"chat"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self notifyAnywayForMessage:sentGUID inChat:resolvedChatGUID];
        });
    }
    return res;
}

- (NSDictionary *)sendFile:(NSData *)data filename:(NSString *)filename toChat:(NSString *)chatGUID
                 addresses:(NSArray<NSString *> *)addresses text:(NSString *)text {
    if (!data.length) return MWErr(@"empty file");
    filename = [filename.lastPathComponent stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    if (!filename.length) filename = @"attachment";
    NSString *err = nil;
    id chat = [self resolveChat:chatGUID addresses:addresses error:&err];
    if (!chat) return MWErr(err);

    NSString *dir = [NSString stringWithFormat:@"/var/mobile/Library/SMS/Attachments/meow/%@", NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:filename];
    if (![data writeToFile:path atomically:YES]) return MWErr(@"could not stage file");

    return MWOnMain(^id {
        id center = [NSClassFromString(@"IMFileTransferCenter") sharedInstance];
        NSURL *url = [NSURL fileURLWithPath:path];
        NSString *tguid = [center guidForNewOutgoingTransferWithLocalURL:url];
        id transfer = tguid ? [center transferForGUID:tguid] : nil;
        if (!transfer) return MWErr(@"could not create file transfer");

        id pac = [NSClassFromString(@"IMDPersistentAttachmentController") sharedInstance];
        NSString *persist = nil;
        @try {
            persist = [pac _persistentPathForTransfer:transfer filename:filename highQuality:YES
                                             chatGUID:[chat guid] storeAtExternalPath:YES];
        } @catch (NSException *e) {
            MWLog(@"persistent path lookup failed: %@", e);
        }
        if (persist.length) {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm createDirectoryAtPath:persist.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            NSError *e = nil;
            if ([fm moveItemAtPath:path toPath:persist error:&e]) {
                [transfer _setLocalURL:[NSURL fileURLWithPath:persist]];
                [fm removeItemAtPath:dir error:nil];
            } else {
                MWLog(@"move to persistent path failed: %@", e);
            }
        }
        [center registerTransferWithDaemon:tguid];

        NSMutableAttributedString *body = [[NSMutableAttributedString alloc] initWithString:@"\uFFFC" attributes:@{
            @"__kIMBaseWritingDirectionAttributeName": @"-1",
            @"__kIMFileTransferGUIDAttributeName": tguid,
            @"__kIMFilenameAttributeName": filename,
            @"__kIMMessagePartAttributeName": @0,
        }];
        if (text.length) {
            [body appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{
                @"__kIMBaseWritingDirectionAttributeName": @"-1",
                @"__kIMMessagePartAttributeName": @1,
            }]];
        }
        id msg = [NSClassFromString(@"IMMessage") instantMessageWithText:body messageSubject:nil
                                                       fileTransferGUIDs:@[tguid] flags:kMWMessageFlags threadIdentifier:nil];
        if (!msg) return MWErr(@"could not create message");
        [chat sendMessage:msg];
        MWLog(@"sent attachment %@ to %@ (%@)", filename, [chat guid], [msg guid]);
        return @{@"ok": @YES, @"guid": [msg guid] ?: [NSNull null], @"chat": [chat guid] ?: [NSNull null]};
    });
}

- (NSDictionary *)react:(NSString *)type remove:(BOOL)remove toMessage:(NSString *)messageGUID inChat:(NSString *)chatGUID {
    NSArray *types = @[@"love", @"like", @"dislike", @"laugh", @"emphasize", @"question"];
    NSUInteger idx = [types indexOfObject:type.lowercaseString];
    if (idx == NSNotFound) return MWErr(@"type must be one of love, like, dislike, laugh, emphasize, question");
    NSDictionary *target = [[MWDatabase shared] messageWithGUID:messageGUID];
    if (!target) return MWErr(@"message not found");
    if (!chatGUID.length) chatGUID = target[@"chat"];
    NSString *err = nil;
    id chat = [self resolveChat:chatGUID addresses:nil error:&err];
    if (!chat) return MWErr(err);

    NSString *orig = [target[@"text"] isKindOfClass:NSString.class] && [target[@"text"] length] ? target[@"text"] : @"an attachment";
    NSArray *verbs = remove
        ? @[@"Removed a heart from", @"Removed a like from", @"Removed a dislike from", @"Removed a laugh from", @"Removed an exclamation from", @"Removed a question mark from"]
        : @[@"Loved", @"Liked", @"Disliked", @"Laughed at", @"Emphasized", @"Questioned"];
    NSString *summary = [NSString stringWithFormat:@"%@ \u201C%@\u201D", verbs[idx], orig];
    long long assocType = (remove ? 3000 : 2000) + (long long)idx;
    NSString *assocGUID = [NSString stringWithFormat:@"p:0/%@", messageGUID];
    NSUInteger len = orig.length;
    return MWOnMain(^id {
        NSAttributedString *content = [[NSAttributedString alloc] initWithString:summary];
        id msg = [NSClassFromString(@"IMMessage") instantMessageWithAssociatedMessageContent:content flags:5
                     associatedMessageGUID:assocGUID associatedMessageType:assocType
                     associatedMessageRange:NSMakeRange(0, len) messageSummaryInfo:@{@"amc": @1, @"ams": orig}
                     threadIdentifier:nil];
        if (!msg) return MWErr(@"could not create reaction");
        [chat sendMessage:msg];
        return @{@"ok": @YES, @"guid": [msg guid] ?: [NSNull null], @"chat": [chat guid] ?: [NSNull null]};
    });
}

- (NSDictionary *)markRead:(NSString *)chatGUID {
    if (!chatGUID.length) return MWErr(@"chat is required");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSString *err = nil;
        id chat = [self resolveChat:chatGUID addresses:nil error:&err];
        if (chat) MWOnMain(^id { [chat markAllMessagesAsRead]; return nil; });
    });
    return @{@"ok": @YES};
}

- (NSDictionary *)setTyping:(BOOL)typing inChat:(NSString *)chatGUID {
    if (!chatGUID.length) return MWErr(@"chat is required");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        id chat = [self resolveChat:chatGUID addresses:nil error:&err];
        if (chat) MWOnMain(^id { [chat setLocalUserIsTyping:typing]; return nil; });
    });
    return @{@"ok": @YES};
}

@end
