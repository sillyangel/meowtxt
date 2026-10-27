#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Handle (email / phone) -> contact name & avatar, read straight from the AddressBook databases.
@interface MWContacts : NSObject
+ (instancetype)shared;
- (void)preload;
- (nullable NSString *)nameForHandle:(NSString *)handle;
// Names for every handle in `handles` that resolves.
- (NSDictionary<NSString *, NSString *> *)namesForHandles:(NSArray<NSString *> *)handles;
// Subset of `handles` (mapped handle -> @YES) that have a contact photo in AddressBookImages.sqlitedb.
- (NSDictionary<NSString *, NSNumber *> *)avatarsForHandles:(NSArray<NSString *> *)handles;
- (BOOL)hasAvatarForHandle:(NSString *)handle;
- (nullable NSData *)avatarDataForHandle:(NSString *)handle mimeType:(NSString *_Nullable *_Nullable)mimeType;
// All normalized handles belonging to the same contact record as `handle`.
- (NSArray<NSString *> *)siblingHandlesForHandle:(NSString *)handle;
// [{name, handles:[...], hasAvatar}] for contacts whose name or handle matches `query`.
- (NSArray<NSDictionary *> *)search:(NSString *)query limit:(NSInteger)limit;
@end

NS_ASSUME_NONNULL_END
