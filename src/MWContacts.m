#import "MWContacts.h"
#import "MWLog.h"
#import <sqlite3.h>

static NSString *const kABPath = @"/var/mobile/Library/AddressBook/AddressBook.sqlitedb";
static NSString *const kABImagesPath = @"/var/mobile/Library/AddressBook/AddressBookImages.sqlitedb";

static NSString *MWNormalizeHandle(NSString *h) {
    if (!h) return nil;
    h = [h stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([h hasPrefix:@"E:"] || [h hasPrefix:@"P:"]) h = [h substringFromIndex:2];
    if ([h containsString:@"@"]) return h.lowercaseString;
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < h.length; i++) {
        unichar c = [h characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
    }
    if (digits.length > 10) return [digits substringFromIndex:digits.length - 10];
    return digits.length ? digits : nil;
}

@implementation MWContacts {
    NSDictionary<NSString *, NSString *> *_names;          // normalized handle -> name
    NSDictionary<NSString *, NSNumber *> *_recordIDs;      // normalized handle -> ABPerson.ROWID
    NSDictionary<NSNumber *, NSArray<NSString *> *> *_personHandles; // recordID -> [normalized handles]
    NSSet<NSNumber *> *_imageRecordIDs;                    // recordIDs present in AddressBookImages
    NSCache<NSNumber *, NSData *> *_avatarCache;           // recordID -> PNG/JPEG data
    NSArray<NSDictionary *> *_people;                      // [{name, handles, hasAvatar}]
    NSDate *_loadedMtime;
    NSDate *_lastCheck;
}

+ (instancetype)shared {
    static MWContacts *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MWContacts new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _avatarCache = [NSCache new];
        _avatarCache.countLimit = 256;
    }
    return self;
}

- (void)preload {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self reloadIfNeeded];
    });
}

- (void)reloadIfNeeded {
    @synchronized (self) {
        if (_lastCheck && -[_lastCheck timeIntervalSinceNow] < 30) return;
        _lastCheck = [NSDate date];
        NSDate *mtime = [[NSFileManager defaultManager] attributesOfItemAtPath:[kABPath stringByAppendingString:@"-wal"] error:nil].fileModificationDate
                     ?: [[NSFileManager defaultManager] attributesOfItemAtPath:kABPath error:nil].fileModificationDate;
        if (_names && [mtime isEqualToDate:_loadedMtime]) return;
        _loadedMtime = mtime;
        [self load];
    }
}

- (NSSet<NSNumber *> *)loadImageRecordIDs {
    NSMutableSet<NSNumber *> *set = [NSMutableSet set];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(kABImagesPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return set;
    }
    sqlite3_busy_timeout(db, 2000);
    sqlite3_stmt *st = NULL;
    const char *sql =
        "SELECT DISTINCT record_id FROM ABThumbnailImage WHERE data IS NOT NULL AND length(data) > 0 "
        "UNION SELECT DISTINCT record_id FROM ABFullSizeImage WHERE data IS NOT NULL AND length(data) > 0";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            [set addObject:@(sqlite3_column_int64(st, 0))];
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return set;
}

- (void)load {
    NSSet<NSNumber *> *imgIDs = [self loadImageRecordIDs];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(kABPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        MWLog(@"address book open failed: %s", db ? sqlite3_errmsg(db) : "?");
        if (db) sqlite3_close(db);
        _names = @{};
        _recordIDs = @{};
        _personHandles = @{};
        _imageRecordIDs = imgIDs;
        _people = @[];
        return;
    }
    sqlite3_busy_timeout(db, 2000);
    sqlite3_stmt *st = NULL;
    const char *sql =
        "SELECT p.ROWID, p.First, p.Last, p.Organization, p.Nickname, mv.property, mv.value "
        "FROM ABPerson p JOIN ABMultiValue mv ON mv.record_id = p.ROWID "
        "WHERE mv.property IN (3, 4) AND mv.value IS NOT NULL ORDER BY p.ROWID";
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    NSMutableDictionary *recordIDs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSString *> *> *personHandles = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *people = [NSMutableDictionary dictionary];
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            NSString *(^s)(int) = ^NSString *(int i) {
                const unsigned char *t = sqlite3_column_text(st, i);
                return t ? @((const char *)t) : nil;
            };
            long long rid = sqlite3_column_int64(st, 0);
            NSNumber *pid = @(rid);
            NSString *first = s(1), *last = s(2), *org = s(3), *nick = s(4), *value = s(6);
            NSMutableArray *parts = [NSMutableArray array];
            if (first.length) [parts addObject:first];
            if (last.length) [parts addObject:last];
            NSString *name = parts.count ? [parts componentsJoinedByString:@" "] : (org.length ? org : nick);
            NSString *key = MWNormalizeHandle(value);
            if (key) {
                if (name.length && !names[key]) names[key] = name;
                if (!recordIDs[key] || [imgIDs containsObject:pid]) recordIDs[key] = pid;
                NSMutableArray *ph = personHandles[pid];
                if (!ph) personHandles[pid] = ph = [NSMutableArray array];
                if (![ph containsObject:key]) [ph addObject:key];
            }
            if (!name.length) continue;
            NSMutableDictionary *person = people[pid];
            if (!person) {
                people[pid] = person = [@{
                    @"name": name,
                    @"handles": [NSMutableArray array],
                    @"hasAvatar": @([imgIDs containsObject:pid]),
                } mutableCopy];
            }
            [person[@"handles"] addObject:value];
        }
        sqlite3_finalize(st);
    } else {
        MWLog(@"address book query failed: %s", sqlite3_errmsg(db));
    }
    sqlite3_close(db);
    _names = names;
    _recordIDs = recordIDs;
    _personHandles = personHandles;
    _imageRecordIDs = imgIDs;
    [_avatarCache removeAllObjects];
    _people = [people.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    MWLog(@"loaded %lu contacts (%lu handles, %lu with photos)",
          (unsigned long)_people.count, (unsigned long)names.count, (unsigned long)imgIDs.count);
}

- (NSString *)nameForHandle:(NSString *)handle {
    [self reloadIfNeeded];
    NSString *key = MWNormalizeHandle(handle);
    @synchronized (self) { return key ? _names[key] : nil; }
}

- (NSDictionary<NSString *, NSString *> *)namesForHandles:(NSArray<NSString *> *)handles {
    [self reloadIfNeeded];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @synchronized (self) {
        for (NSString *h in handles) {
            if (![h isKindOfClass:NSString.class] || out[h]) continue;
            NSString *key = MWNormalizeHandle(h);
            NSString *n = key ? _names[key] : nil;
            if (n) out[h] = n;
        }
    }
    return out;
}

- (BOOL)hasAvatarForHandle:(NSString *)handle {
    [self reloadIfNeeded];
    NSString *key = MWNormalizeHandle(handle);
    @synchronized (self) {
        NSNumber *rid = key ? _recordIDs[key] : nil;
        return rid != nil && [_imageRecordIDs containsObject:rid];
    }
}

- (NSDictionary<NSString *, NSNumber *> *)avatarsForHandles:(NSArray<NSString *> *)handles {
    [self reloadIfNeeded];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @synchronized (self) {
        for (NSString *h in handles) {
            if (![h isKindOfClass:NSString.class] || out[h]) continue;
            NSString *key = MWNormalizeHandle(h);
            NSNumber *rid = key ? _recordIDs[key] : nil;
            if (rid && [_imageRecordIDs containsObject:rid]) out[h] = @YES;
        }
    }
    return out;
}

- (NSArray<NSString *> *)siblingHandlesForHandle:(NSString *)handle {
    [self reloadIfNeeded];
    NSString *key = MWNormalizeHandle(handle);
    if (!key) return @[];
    @synchronized (self) {
        NSNumber *rid = _recordIDs[key];
        NSArray<NSString *> *list = rid ? _personHandles[rid] : nil;
        return list.count ? list : @[key];
    }
}

- (NSData *)avatarDataForHandle:(NSString *)handle mimeType:(NSString **)mimeType {
    [self reloadIfNeeded];
    NSString *key = MWNormalizeHandle(handle);
    NSNumber *rid = nil;
    @synchronized (self) {
        rid = key ? _recordIDs[key] : nil;
        if (!rid || ![_imageRecordIDs containsObject:rid]) return nil;
    }
    NSData *cached = [_avatarCache objectForKey:rid];
    if (!cached) {
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(kABImagesPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
            sqlite3_busy_timeout(db, 2000);
            sqlite3_stmt *st = NULL;
            // Prefer format 0 (small thumbnail ~15-70KB), then any thumbnail, then full size.
            const char *sql =
                "SELECT data FROM ("
                "  SELECT data, CASE WHEN format = 0 THEN 0 ELSE 1 END AS prio FROM ABThumbnailImage WHERE record_id = ?1 AND data IS NOT NULL AND length(data) > 0 "
                "  UNION ALL "
                "  SELECT data, 2 AS prio FROM ABFullSizeImage WHERE record_id = ?1 AND data IS NOT NULL AND length(data) > 0"
                ") ORDER BY prio ASC LIMIT 1";
            if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
                sqlite3_bind_int64(st, 1, rid.longLongValue);
                if (sqlite3_step(st) == SQLITE_ROW) {
                    const void *bytes = sqlite3_column_blob(st, 0);
                    int len = sqlite3_column_bytes(st, 0);
                    if (bytes && len > 0) cached = [NSData dataWithBytes:bytes length:(NSUInteger)len];
                }
                sqlite3_finalize(st);
            }
            sqlite3_close(db);
        }
        if (cached) [_avatarCache setObject:cached forKey:rid];
    }
    if (cached && mimeType) {
        const uint8_t *b = cached.bytes;
        if (cached.length >= 4 && b[0] == 0x89 && b[1] == 0x50) *mimeType = @"image/png";
        else if (cached.length >= 3 && b[0] == 0xFF && b[1] == 0xD8) *mimeType = @"image/jpeg";
        else *mimeType = @"application/octet-stream";
    }
    return cached;
}

- (NSArray<NSDictionary *> *)search:(NSString *)query limit:(NSInteger)limit {
    [self reloadIfNeeded];
    NSArray *people;
    @synchronized (self) { people = _people; }
    NSString *q = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in people) {
        BOOL match = q.length == 0 || [p[@"name"] rangeOfString:q options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound;
        if (!match) {
            for (NSString *h in p[@"handles"])
                if ([h rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) { match = YES; break; }
        }
        if (match) [out addObject:p];
        if ((NSInteger)out.count >= limit) break;
    }
    return out;
}

@end
