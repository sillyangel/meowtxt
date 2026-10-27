#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MWRequest : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *query;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers; // lower-cased keys
@property (nonatomic, strong) NSData *body;
@property (nonatomic, copy) NSString *remoteAddress;
- (nullable id)JSONBody;
@end

@class MWResponse;
// Called on a background thread for streaming responses (SSE). Return NO from `write` once the
// client is gone. The block should loop until write fails.
typedef void (^MWStreamWriter)(BOOL (^write)(NSData *chunk));

@interface MWResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong, nullable) NSData *body;
@property (nonatomic, copy, nullable) MWStreamWriter stream;
+ (instancetype)json:(id)object;
+ (instancetype)json:(id)object status:(NSInteger)status;
+ (instancetype)error:(NSString *)message status:(NSInteger)status;
+ (instancetype)data:(NSData *)data type:(NSString *)contentType;
@end

typedef MWResponse *_Nullable (^MWHandler)(MWRequest *req);

@interface MWHTTPServer : NSObject
@property (nonatomic, copy, nullable) MWHandler handler;
- (BOOL)listenOnPort:(uint16_t)port error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
