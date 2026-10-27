#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Read-only access to /var/mobile/Library/SMS/sms.db. All methods are thread-safe (serial queue).
@interface MWDatabase : NSObject
+ (instancetype)shared;
- (BOOL)open;

// Conversations ordered by most recent message. iMessage only.
- (NSArray<NSDictionary *> *)chatsWithLimit:(NSInteger)limit offset:(NSInteger)offset;
- (nullable NSDictionary *)chatWithGUID:(NSString *)guid;
// Newest first. `before` is a unix-ms timestamp (0 = latest).
- (NSArray<NSDictionary *> *)messagesForChat:(NSString *)chatGUID before:(long long)beforeMs limit:(NSInteger)limit;
- (nullable NSDictionary *)messageWithGUID:(NSString *)guid;
- (NSArray<NSDictionary *> *)searchMessages:(NSString *)query limit:(NSInteger)limit;
- (nullable NSDictionary *)attachmentWithID:(long long)rowid;

// Change tracking used by the event loop.
- (long long)maxMessageROWID;
- (NSArray<NSDictionary *> *)messagesAfterROWID:(long long)rowid limit:(NSInteger)limit;
// Outgoing messages whose delivered/read/edited state changed after `sinceAppleTime` (apple ns).
- (NSArray<NSDictionary *> *)messagesUpdatedSince:(long long)sinceAppleTime;
// Returns YES if another connection committed to the DB since the last call.
- (BOOL)hasChanged;
+ (long long)appleTimeNow;
@end

// Extracts the plain string from a typedstream-archived NSAttributedString (message.attributedBody).
NSString *_Nullable MWTextFromAttributedBody(NSData *blob);

NS_ASSUME_NONNULL_END
