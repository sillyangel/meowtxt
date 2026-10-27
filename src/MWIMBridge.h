#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MWTypingHandler)(NSString *chatGUID, NSString *_Nullable sender, BOOL typing);
typedef void (^MWPinChangeHandler)(void);
typedef void (^MWDNDChangeHandler)(NSString *_Nullable handleID, BOOL dnd);

// Thin wrapper over IMCore (talks to imagent). All public methods may be called from any thread;
// work is marshalled to the main thread where IMCore lives.
@interface MWIMBridge : NSObject
@property (nonatomic, copy, nullable) MWTypingHandler onTyping;
@property (nonatomic, copy, nullable) MWPinChangeHandler onPinnedChanged;
@property (nonatomic, copy, nullable) MWDNDChangeHandler onDNDChanged;

+ (instancetype)shared;
- (BOOL)connect;
- (NSDictionary *)status;

// Ordered list of pinned conversation identifiers (from IMPinnedConversationsController / com.apple.messages.pinning.plist).
- (NSArray<NSString *> *)pinnedIdentifiers;
// Reloads com.apple.messages.pinning.plist if modified on disk; returns YES if the pinned set changed.
- (BOOL)reloadPinnedFromDiskIfChanged;
// Pins or unpins a chat GUID and syncs to IMPinnedConversationsController + com.apple.messages.pinning.plist.
- (NSDictionary *)setPinned:(BOOL)pinned forChat:(NSString *)chatGUID;

// Focus / Do Not Disturb (StatusKit / IMHandleAvailabilityManager).
- (BOOL)isDNDActiveForChat:(NSString *)chatGUID identifier:(nullable NSString *)identifier;
- (void)observeDNDForChat:(NSString *)chatGUID;
// Manually overrides DND ("Notify Anyway") for a message that was delivered quietly.
- (NSDictionary *)notifyAnywayForMessage:(nullable NSString *)messageGUID inChat:(NSString *)chatGUID;

// `chat` is a chat GUID (iMessage;-;foo@bar.com / iMessage;+;chat123...). If nil, `to` is a list of
// addresses (emails / numbers) and a chat is found or created for them. Returns {ok, guid, chat} or {ok:NO, error}.
- (NSDictionary *)sendText:(nullable NSString *)text
                   subject:(nullable NSString *)subject
                    toChat:(nullable NSString *)chatGUID
                 addresses:(nullable NSArray<NSString *> *)addresses
                    effect:(nullable NSString *)effect
                   replyTo:(nullable NSString *)replyGUID
              notifyAnyway:(BOOL)notifyAnyway;
- (NSDictionary *)sendFile:(NSData *)data
                  filename:(NSString *)filename
                    toChat:(nullable NSString *)chatGUID
                 addresses:(nullable NSArray<NSString *> *)addresses
                      text:(nullable NSString *)text;
- (NSDictionary *)react:(NSString *)type remove:(BOOL)remove toMessage:(NSString *)messageGUID inChat:(NSString *)chatGUID;
- (NSDictionary *)editMessage:(NSString *)messageGUID newText:(NSString *)newText inChat:(nullable NSString *)chatGUID;
- (NSDictionary *)unsendMessage:(NSString *)messageGUID inChat:(nullable NSString *)chatGUID;
- (NSDictionary *)markRead:(NSString *)chatGUID;
- (NSDictionary *)setTyping:(BOOL)typing inChat:(NSString *)chatGUID;
@end

NS_ASSUME_NONNULL_END
