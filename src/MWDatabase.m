#import <Foundation/Foundation.h>
#import "MWDatabase.h"
#import "MWLog.h"
#import <sqlite3.h>

static NSString *const kDBPath = @"/var/mobile/Library/SMS/sms.db";
static const long long kAppleEpochMs = 978307200000LL;

#pragma mark - attributedBody (typedstream) decoding

NSString *MWTextFromAttributedBody(NSData *blob) {
    if (blob.length < 16) return nil;
    const uint8_t *b = blob.bytes;
    NSUInteger n = blob.length;
    const char *marker = "NSString";
    size_t ml = strlen(marker);
    for (NSUInteger i = 0; i + ml < n; i++) {
        if (memcmp(b + i, marker, ml) != 0) continue;
        // After the class name comes a short preamble ending with '+' (0x2B), then the length.
        NSUInteger p = i + ml;
        NSUInteger limit = MIN(n, p + 12);
        while (p < limit && b[p] != 0x2B) p++;
        if (p >= limit) continue;
        p++;
        if (p >= n) return nil;
        NSUInteger len;
        uint8_t lb = b[p++];
        if (lb == 0x81) {
            if (p + 2 > n) return nil;
            len = (NSUInteger)b[p] | ((NSUInteger)b[p + 1] << 8);
            p += 2;
        } else if (lb == 0x82) {
            if (p + 4 > n) return nil;
            len = (NSUInteger)b[p] | ((NSUInteger)b[p + 1] << 8) | ((NSUInteger)b[p + 2] << 16) | ((NSUInteger)b[p + 3] << 24);
            p += 4;
        } else {
            len = lb;
        }
        if (p + len > n) return nil;
        return [[NSString alloc] initWithBytes:b + p length:len encoding:NSUTF8StringEncoding];
    }
    return nil;
}

static long long MWAppleToUnixMs(long long v) {
    if (v == 0) return 0;
    if (v > 100000000000LL) return v / 1000000 + kAppleEpochMs;   // nanoseconds (iOS 11+)
    return v * 1000 + kAppleEpochMs;                               // seconds (legacy)
}

static long long MWUnixMsToApple(long long ms) {
    return (ms - kAppleEpochMs) * 1000000;
}

static NSString *MWReactionName(long long type) {
    switch (type % 1000) {
        case 0: return @"love";
        case 1: return @"like";
        case 2: return @"dislike";
        case 3: return @"laugh";
        case 4: return @"emphasize";
        case 5: return @"question";
        default: return nil;
    }
}

#pragma mark - statement helpers

static NSString *col_str(sqlite3_stmt *s, int i) {
    const unsigned char *t = sqlite3_column_text(s, i);
    return t ? [NSString stringWithUTF8String:(const char *)t] : nil;
}
static NSData *col_data(sqlite3_stmt *s, int i) {
    const void *p = sqlite3_column_blob(s, i);
    int len = sqlite3_column_bytes(s, i);
    return p && len > 0 ? [NSData dataWithBytes:p length:(NSUInteger)len] : nil;
}
static long long col_ll(sqlite3_stmt *s, int i) { return sqlite3_column_int64(s, i); }
static id orNull(id o) { return o ?: [NSNull null]; }

// Shared column list for message rows; keep in sync with -messageFromStmt:.
#define MW_MSG_COLS \
    "m.ROWID, m.guid, m.text, m.attributedBody, m.subject, m.date, m.date_read, m.date_delivered, " \
    "m.is_from_me, m.is_delivered, m.is_read, m.is_sent, m.error, m.service, h.id, m.item_type, " \
    "m.associated_message_type, m.associated_message_guid, m.cache_has_attachments, " \
    "m.expressive_send_style_id, m.thread_originator_guid, m.date_edited, m.date_retracted, " \
    "m.group_title, m.balloon_bundle_id, m.is_audio_message, c.guid, m.group_action_type, oh.id, " \
    "m.was_delivered_quietly, m.did_notify_recipient"

#define MW_MSG_JOINS \
    " FROM message m" \
    " JOIN chat_message_join cmj ON cmj.message_id = m.ROWID" \
    " JOIN chat c ON c.ROWID = cmj.chat_id" \
    " LEFT JOIN handle h ON h.ROWID = m.handle_id" \
    " LEFT JOIN handle oh ON oh.ROWID = m.other_handle "

@implementation MWDatabase {
    sqlite3 *_db;
    dispatch_queue_t _q;
    long long _dataVersion;
}

+ (instancetype)shared {
    static MWDatabase *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MWDatabase new]; });
    return s;
}

+ (long long)appleTimeNow {
    return MWUnixMsToApple((long long)([[NSDate date] timeIntervalSince1970] * 1000));
}

- (instancetype)init {
    if ((self = [super init])) _q = dispatch_queue_create("meow.db", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (BOOL)open {
    __block BOOL ok = NO;
    dispatch_sync(_q, ^{
        int rc = sqlite3_open_v2(kDBPath.UTF8String, &self->_db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
        if (rc != SQLITE_OK) {
            MWLog(@"sqlite open failed: %s", sqlite3_errmsg(self->_db));
            return;
        }
        sqlite3_busy_timeout(self->_db, 3000);
        sqlite3_exec(self->_db, "PRAGMA cache_size = -8000; PRAGMA temp_store = MEMORY;", NULL, NULL, NULL);
        ok = YES;
    });
    return ok;
}

- (sqlite3_stmt *)prepare:(const char *)sql {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &st, NULL) != SQLITE_OK) {
        MWLog(@"sqlite prepare failed: %s -- %s", sqlite3_errmsg(_db), sql);
        return NULL;
    }
    return st;
}

#pragma mark - mapping

- (NSArray *)attachmentsForMessage:(long long)rowid {
    sqlite3_stmt *st = [self prepare:
        "SELECT a.ROWID, a.guid, a.filename, a.mime_type, a.transfer_name, a.total_bytes, a.uti, a.is_sticker, a.transfer_state "
        "FROM attachment a JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID "
        "WHERE maj.message_id = ? AND a.hide_attachment = 0"];
    if (!st) return @[];
    sqlite3_bind_int64(st, 1, rowid);
    NSMutableArray *out = [NSMutableArray array];
    while (sqlite3_step(st) == SQLITE_ROW) {
        NSString *mime = col_str(st, 3);
        NSString *uti = col_str(st, 6);
        if (!mime && [uti isEqualToString:@"public.heic"]) mime = @"image/heic";
        [out addObject:@{
            @"id": @(col_ll(st, 0)),
            @"guid": orNull(col_str(st, 1)),
            @"name": orNull(col_str(st, 4) ?: [col_str(st, 2) lastPathComponent]),
            @"mime": orNull(mime),
            @"uti": orNull(uti),
            @"size": @(col_ll(st, 5)),
            @"sticker": @(col_ll(st, 7) != 0),
            @"ready": @(col_ll(st, 8) == 5 || col_str(st, 2) != nil),
        }];
    }
    sqlite3_finalize(st);
    return out;
}

- (NSDictionary *)messageFromStmt:(sqlite3_stmt *)st {
    long long rowid = col_ll(st, 0);
    NSString *text = col_str(st, 2);
    if (!text.length) text = MWTextFromAttributedBody(col_data(st, 3));
    BOOL hasAtt = col_ll(st, 18) != 0;
    if (text && hasAtt) {
        // Attachment placeholders (U+FFFC) are rendered from `attachments` instead.
        text = [text stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
    }
    NSMutableDictionary *m = [@{
        @"id": @(rowid),
        @"guid": orNull(col_str(st, 1)),
        @"chat": orNull(col_str(st, 26)),
        @"text": orNull(text),
        @"subject": orNull(col_str(st, 4)),
        @"date": @(MWAppleToUnixMs(col_ll(st, 5))),
        @"dateRead": @(MWAppleToUnixMs(col_ll(st, 6))),
        @"dateDelivered": @(MWAppleToUnixMs(col_ll(st, 7))),
        @"fromMe": @(col_ll(st, 8) != 0),
        @"delivered": @(col_ll(st, 9) != 0),
        @"read": @(col_ll(st, 10) != 0),
        @"sent": @(col_ll(st, 11) != 0),
        @"error": @(col_ll(st, 12)),
        @"service": orNull(col_str(st, 13)),
        @"sender": orNull(col_str(st, 14)),
        @"itemType": @(col_ll(st, 15)),
        @"effect": orNull(col_str(st, 19)),
        @"replyTo": orNull(col_str(st, 20)),
        @"dateEdited": @(MWAppleToUnixMs(col_ll(st, 21))),
        @"dateRetracted": @(MWAppleToUnixMs(col_ll(st, 22))),
        @"groupTitle": orNull(col_str(st, 23)),
        @"balloon": orNull(col_str(st, 24)),
        @"audio": @(col_ll(st, 25) != 0),
        @"groupAction": @(col_ll(st, 27)),
        @"otherHandle": orNull(col_str(st, 28)),
        @"wasDeliveredQuietly": @(col_ll(st, 29) != 0),
        @"didNotifyRecipient": @(col_ll(st, 30) != 0),
        @"attachments": hasAtt ? [self attachmentsForMessage:rowid] : @[],
    } mutableCopy];
    long long at = col_ll(st, 16);
    NSString *ag = col_str(st, 17);
    if (at >= 2000 && at < 4000 && ag && MWReactionName(at)) {
        NSRange slash = [ag rangeOfString:@"/"];
        NSString *target = slash.location != NSNotFound ? [ag substringFromIndex:slash.location + 1]
                         : ([ag hasPrefix:@"bp:"] ? [ag substringFromIndex:3] : ag);
        m[@"reaction"] = @{ @"type": MWReactionName(at), @"remove": @(at >= 3000), @"target": target };
    }
    return m;
}

- (long long)attachmentIDForGUID:(NSString *)guid {
    if (!guid.length) return 0;
    sqlite3_stmt *st = [self prepare:"SELECT ROWID FROM attachment WHERE guid = ? OR original_guid = ? LIMIT 1"];
    if (!st) return 0;
    sqlite3_bind_text(st, 1, guid.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, guid.UTF8String, -1, SQLITE_TRANSIENT);
    long long rowid = 0;
    if (sqlite3_step(st) == SQLITE_ROW) rowid = col_ll(st, 0);
    sqlite3_finalize(st);
    return rowid;
}

#pragma mark - queries

// Single-pass CTE query: avoids N+1 participant queries and correlated unread subqueries.
static const char *kChatSelectCTE =
    "WITH latest AS ("
    "  SELECT chat_id, MAX(message_id) AS max_mid, MAX(message_date) AS md"
    "  FROM chat_message_join GROUP BY chat_id"
    "), "
    "unread_counts AS ("
    "  SELECT j.chat_id, COUNT(*) AS cnt"
    "  FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID"
    "  WHERE m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0 AND m.associated_message_type = 0"
    "  GROUP BY j.chat_id"
    "), "
    "parts AS ("
    "  SELECT chj.chat_id, GROUP_CONCAT(h.id, char(31)) AS handles"
    "  FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id"
    "  GROUP BY chj.chat_id"
    ") "
    "SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.style, c.service_name, l.md, "
    "  m.text, m.attributedBody, m.is_from_me, m.cache_has_attachments, m.associated_message_type, h.id, "
    "  COALESCE(u.cnt, 0) AS unread, COALESCE(p.handles, ''), c.group_id, c.original_group_id, c.properties, "
    "  m.was_delivered_quietly, m.did_notify_recipient, m.guid "
    "FROM chat c "
    "JOIN latest l ON l.chat_id = c.ROWID "
    "JOIN message m ON m.ROWID = l.max_mid "
    "LEFT JOIN handle h ON h.ROWID = m.handle_id "
    "LEFT JOIN unread_counts u ON u.chat_id = c.ROWID "
    "LEFT JOIN parts p ON p.chat_id = c.ROWID "
    "WHERE c.service_name = 'iMessage' ";

- (NSDictionary *)chatFromStmt:(sqlite3_stmt *)st {
    NSString *text = col_str(st, 7);
    if (!text.length) text = MWTextFromAttributedBody(col_data(st, 8));
    text = [text stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
    BOOL hasAtt = col_ll(st, 10) != 0;
    NSString *handlesRaw = col_str(st, 14);
    NSArray *participants = handlesRaw.length ? [handlesRaw componentsSeparatedByString:@"\x1F"] : @[];
    NSData *propsBlob = col_data(st, 17);
    long long groupPhotoAttID = 0;
    if (propsBlob.length) {
        NSDictionary *props = [NSPropertyListSerialization propertyListWithData:propsBlob options:0 format:nil error:nil];
        if ([props isKindOfClass:NSDictionary.class] && [props[@"groupPhotoGuid"] isKindOfClass:NSString.class]) {
            groupPhotoAttID = [self attachmentIDForGUID:props[@"groupPhotoGuid"]];
        }
    }
    return @{
        @"guid": orNull(col_str(st, 1)),
        @"identifier": orNull(col_str(st, 2)),
        @"displayName": orNull(col_str(st, 3).length ? col_str(st, 3) : nil),
        @"isGroup": @(col_ll(st, 4) == 43),
        @"service": orNull(col_str(st, 5)),
        @"participants": participants,
        @"unread": @(col_ll(st, 13)),
        @"groupID": orNull(col_str(st, 15)),
        @"originalGroupID": orNull(col_str(st, 16)),
        @"groupPhotoAttachmentID": groupPhotoAttID > 0 ? @(groupPhotoAttID) : [NSNull null],
        @"lastMessage": @{
            @"guid": orNull(col_str(st, 20)),
            @"text": orNull(text.length ? text : (hasAtt ? @"Attachment" : nil)),
            @"date": @(MWAppleToUnixMs(col_ll(st, 6))),
            @"fromMe": @(col_ll(st, 9) != 0),
            @"sender": orNull(col_str(st, 12)),
            @"isReaction": @(col_ll(st, 11) >= 2000),
            @"wasDeliveredQuietly": @(col_ll(st, 18) != 0),
            @"didNotifyRecipient": @(col_ll(st, 19) != 0),
        },
    };
}

- (NSArray<NSDictionary *> *)chatsWithLimit:(NSInteger)limit offset:(NSInteger)offset {
    __block NSMutableArray *out = [NSMutableArray array];
    dispatch_sync(_q, ^{
        NSString *sql = [NSString stringWithFormat:@"%s ORDER BY l.md DESC LIMIT ? OFFSET ?", kChatSelectCTE];
        sqlite3_stmt *st = [self prepare:sql.UTF8String];
        if (!st) return;
        sqlite3_bind_int64(st, 1, limit);
        sqlite3_bind_int64(st, 2, offset);
        while (sqlite3_step(st) == SQLITE_ROW) [out addObject:[self chatFromStmt:st]];
        sqlite3_finalize(st);
    });
    return out;
}

- (NSDictionary *)chatWithGUID:(NSString *)guid {
    __block NSDictionary *out = nil;
    dispatch_sync(_q, ^{
        NSString *sql = [NSString stringWithFormat:@"%s AND c.guid = ? LIMIT 1", kChatSelectCTE];
        sqlite3_stmt *st = [self prepare:sql.UTF8String];
        if (!st) return;
        sqlite3_bind_text(st, 1, guid.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_ROW) out = [self chatFromStmt:st];
        sqlite3_finalize(st);
    });
    return out;
}

- (NSArray<NSDictionary *> *)messagesForChat:(NSString *)chatGUID before:(long long)beforeMs limit:(NSInteger)limit {
    __block NSMutableArray *out = [NSMutableArray array];
    dispatch_sync(_q, ^{
        sqlite3_stmt *st = [self prepare:
            "SELECT " MW_MSG_COLS MW_MSG_JOINS
            "WHERE c.guid = ?1 AND (?2 = 0 OR cmj.message_date < ?2) "
            "ORDER BY cmj.message_date DESC, m.ROWID DESC LIMIT ?3"];
        if (!st) return;
        sqlite3_bind_text(st, 1, chatGUID.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 2, beforeMs > 0 ? MWUnixMsToApple(beforeMs) : 0);
        sqlite3_bind_int64(st, 3, limit);
        while (sqlite3_step(st) == SQLITE_ROW) [out addObject:[self messageFromStmt:st]];
        sqlite3_finalize(st);
    });
    return out;
}

- (NSDictionary *)messageWithGUID:(NSString *)guid {
    __block NSDictionary *out = nil;
    dispatch_sync(_q, ^{
        sqlite3_stmt *st = [self prepare:"SELECT " MW_MSG_COLS MW_MSG_JOINS "WHERE m.guid = ? LIMIT 1"];
        if (!st) return;
        sqlite3_bind_text(st, 1, guid.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_ROW) out = [self messageFromStmt:st];
        sqlite3_finalize(st);
    });
    return out;
}

- (NSArray<NSDictionary *> *)searchMessages:(NSString *)query limit:(NSInteger)limit {
    __block NSMutableArray *out = [NSMutableArray array];
    dispatch_sync(_q, ^{
        sqlite3_stmt *st = [self prepare:
            "SELECT " MW_MSG_COLS MW_MSG_JOINS
            "WHERE c.service_name = 'iMessage' AND m.associated_message_type = 0 AND m.text LIKE ?1 ESCAPE '\\' "
            "ORDER BY m.date DESC LIMIT ?2"];
        if (!st) return;
        NSString *esc = [[[query stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                          stringByReplacingOccurrencesOfString:@"%" withString:@"\\%"]
                         stringByReplacingOccurrencesOfString:@"_" withString:@"\\_"];
        NSString *pat = [NSString stringWithFormat:@"%%%@%%", esc];
        sqlite3_bind_text(st, 1, pat.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 2, limit);
        while (sqlite3_step(st) == SQLITE_ROW) [out addObject:[self messageFromStmt:st]];
        sqlite3_finalize(st);
    });
    return out;
}

- (NSDictionary *)attachmentWithID:(long long)rowid {
    __block NSDictionary *out = nil;
    dispatch_sync(_q, ^{
        sqlite3_stmt *st = [self prepare:
            "SELECT a.filename, a.mime_type, a.transfer_name, a.uti, a.total_bytes FROM attachment a WHERE a.ROWID = ?"];
        if (!st) return;
        sqlite3_bind_int64(st, 1, rowid);
        if (sqlite3_step(st) == SQLITE_ROW) {
            NSString *path = col_str(st, 0);
            if ([path hasPrefix:@"~"]) path = [@"/var/mobile" stringByAppendingString:[path substringFromIndex:1]];
            out = @{
                @"path": orNull(path),
                @"mime": orNull(col_str(st, 1)),
                @"name": orNull(col_str(st, 2)),
                @"uti": orNull(col_str(st, 3)),
                @"size": @(col_ll(st, 4)),
            };
        }
        sqlite3_finalize(st);
    });
    return out;
}

#pragma mark - change tracking

- (long long)maxMessageROWID {
    __block long long v = 0;
    dispatch_sync(_q, ^{
        sqlite3_stmt *st = [self prepare:"SELECT MAX(ROWID) FROM message"];
        if (st && sqlite3_step(st) == SQLITE_ROW) v = col_ll(st, 0);
        sqlite3_finalize(st);
    });
    return v;
}

- (NSArray<NSDictionary *> *)messagesAfterROWID:(long long)rowid limit:(NSInteger)limit {
    __block NSMutableArray *out = [NSMutableArray array];
    dispatch_sync(_q, ^{
        sqlite3_stmt *st = [self prepare:
            "SELECT " MW_MSG_COLS MW_MSG_JOINS "WHERE m.ROWID > ? ORDER BY m.ROWID ASC LIMIT ?"];
        if (!st) return;
        sqlite3_bind_int64(st, 1, rowid);
        sqlite3_bind_int64(st, 2, limit);
        while (sqlite3_step(st) == SQLITE_ROW) [out addObject:[self messageFromStmt:st]];
        sqlite3_finalize(st);
    });
    return out;
}

- (NSArray<NSDictionary *> *)messagesUpdatedSince:(long long)since {
    __block NSMutableArray *out = [NSMutableArray array];
    dispatch_sync(_q, ^{
        sqlite3_stmt *st = [self prepare:
            "SELECT " MW_MSG_COLS MW_MSG_JOINS
            "WHERE m.date > ?1 - 604800000000000 AND "   // only look at the last week of messages
            "(m.date_delivered > ?1 OR m.date_read > ?1 OR m.date_edited > ?1 OR m.date_retracted > ?1 "
            " OR (m.is_from_me = 1 AND (m.error != 0 OR m.was_delivered_quietly != 0 OR m.did_notify_recipient != 0) AND m.date > ?1 - 900000000000)) "
            "ORDER BY m.ROWID ASC LIMIT 200"];
        if (!st) return;
        sqlite3_bind_int64(st, 1, since);
        while (sqlite3_step(st) == SQLITE_ROW) [out addObject:[self messageFromStmt:st]];
        sqlite3_finalize(st);
    });
    return out;
}

- (BOOL)hasChanged {
    __block BOOL changed = NO;
    dispatch_sync(_q, ^{
        sqlite3_stmt *st = [self prepare:"PRAGMA data_version"];
        if (st && sqlite3_step(st) == SQLITE_ROW) {
            long long v = col_ll(st, 0);
            changed = v != self->_dataVersion;
            self->_dataVersion = v;
        }
        sqlite3_finalize(st);
    });
    return changed;
}

@end
