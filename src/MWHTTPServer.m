#import "MWHTTPServer.h"
#import "MWLog.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <signal.h>

static const NSUInteger kMaxHeaderBytes = 64 * 1024;
static const NSUInteger kMaxBodyBytes = 200 * 1024 * 1024;

static NSString *MWPercentDecode(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return [s stringByRemovingPercentEncoding] ?: s;
}

@implementation MWRequest
- (id)JSONBody {
    if (self.body.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:self.body options:0 error:nil];
}
@end

@implementation MWResponse
- (instancetype)init {
    if ((self = [super init])) {
        _status = 200;
        _headers = [NSMutableDictionary dictionary];
    }
    return self;
}
+ (instancetype)json:(id)object { return [self json:object status:200]; }
+ (instancetype)json:(id)object status:(NSInteger)status {
    MWResponse *r = [self new];
    r.status = status;
    r.headers[@"Content-Type"] = @"application/json; charset=utf-8";
    r.body = [NSJSONSerialization dataWithJSONObject:object ?: [NSNull null]
                                             options:NSJSONWritingFragmentsAllowed
                                               error:nil] ?: [NSData data];
    return r;
}
+ (instancetype)error:(NSString *)message status:(NSInteger)status {
    return [self json:@{@"ok": @NO, @"error": message ?: @"error"} status:status];
}
+ (instancetype)data:(NSData *)data type:(NSString *)contentType {
    MWResponse *r = [self new];
    r.headers[@"Content-Type"] = contentType;
    r.body = data;
    return r;
}
@end

static NSString *MWStatusText(NSInteger s) {
    switch (s) {
        case 200: return @"OK";
        case 204: return @"No Content";
        case 206: return @"Partial Content";
        case 400: return @"Bad Request";
        case 401: return @"Unauthorized";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 413: return @"Payload Too Large";
        case 500: return @"Internal Server Error";
        case 503: return @"Service Unavailable";
        default:  return @"Status";
    }
}

static BOOL MWWriteAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        if (n == 0) return NO;
        p += n; len -= (size_t)n;
    }
    return YES;
}

@implementation MWHTTPServer {
    int _fd;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _connQueue;
}

- (BOOL)listenOnPort:(uint16_t)port error:(NSError **)error {
    signal(SIGPIPE, SIG_IGN);
    _fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (_fd < 0) goto fail;
    int yes = 1, no = 0;
    setsockopt(_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(_fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no)); // dual-stack
    struct sockaddr_in6 addr = {0};
    addr.sin6_len = sizeof(addr);
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(port);
    addr.sin6_addr = in6addr_any;
    if (bind(_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) goto fail;
    if (listen(_fd, 64) < 0) goto fail;

    {
        _connQueue = dispatch_queue_create("meow.http.conn", DISPATCH_QUEUE_CONCURRENT);
        _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_fd, 0,
                                               dispatch_queue_create("meow.http.accept", 0));
        __weak typeof(self) weakSelf = self;
        int lfd = _fd;
        dispatch_source_set_event_handler(_acceptSource, ^{
            struct sockaddr_storage peer; socklen_t plen = sizeof(peer);
            int cfd = accept(lfd, (struct sockaddr *)&peer, &plen);
            if (cfd < 0) return;
            int one = 1;
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            struct timeval tv = { .tv_sec = 30 };
            setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            char host[INET6_ADDRSTRLEN] = "?";
            if (peer.ss_family == AF_INET6) {
                struct sockaddr_in6 *a = (struct sockaddr_in6 *)&peer;
                inet_ntop(AF_INET6, &a->sin6_addr, host, sizeof(host));
            } else if (peer.ss_family == AF_INET) {
                struct sockaddr_in *a = (struct sockaddr_in *)&peer;
                inet_ntop(AF_INET, &a->sin_addr, host, sizeof(host));
            }
            NSString *remote = @(host);
            if ([remote hasPrefix:@"::ffff:"]) remote = [remote substringFromIndex:7];
            // Each connection gets its own thread: SSE streams block for their lifetime.
            NSThread *t = [[NSThread alloc] initWithBlock:^{
                [weakSelf handleConnection:cfd remote:remote];
            }];
            t.name = @"meow.http.conn";
            [t start];
        });
        dispatch_resume(_acceptSource);
    }
    return YES;

fail:
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    if (_fd >= 0) close(_fd);
    return NO;
}

- (void)handleConnection:(int)fd remote:(NSString *)remote {
    @autoreleasepool {
        // Keep-alive loop: serve requests until the client closes or asks to close.
        NSMutableData *buf = [NSMutableData data];
        for (;;) {
            BOOL keepAlive = NO;
            MWRequest *req = [self readRequestFrom:fd buffer:buf remote:remote keepAlive:&keepAlive];
            if (!req) break;
            MWResponse *res = nil;
            @try {
                res = self.handler ? self.handler(req) : nil;
            } @catch (NSException *e) {
                MWLog(@"handler exception on %@ %@: %@", req.method, req.path, e);
                res = [MWResponse error:[NSString stringWithFormat:@"internal error: %@", e.reason] status:500];
            }
            if (!res) res = [MWResponse error:@"not found" status:404];
            if (![self writeResponse:res request:req to:fd keepAlive:keepAlive]) break;
            if (res.stream || !keepAlive) break;
        }
        close(fd);
    }
}

- (MWRequest *)readRequestFrom:(int)fd buffer:(NSMutableData *)buf remote:(NSString *)remote keepAlive:(BOOL *)keepAlive {
    uint8_t chunk[16384];
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange hdrEnd;
    for (;;) {
        hdrEnd = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
        if (hdrEnd.location != NSNotFound) break;
        if (buf.length > kMaxHeaderBytes) return nil;
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) return nil;
        [buf appendBytes:chunk length:(NSUInteger)n];
    }
    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrEnd.location)]
                                           encoding:NSUTF8StringEncoding];
    [buf replaceBytesInRange:NSMakeRange(0, NSMaxRange(hdrEnd)) withBytes:NULL length:0];
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *rl = [lines.firstObject componentsSeparatedByString:@" "];
    if (rl.count < 2) return nil;

    MWRequest *req = [MWRequest new];
    req.method = rl[0].uppercaseString;
    req.remoteAddress = remote;
    NSString *target = rl[1];
    NSRange q = [target rangeOfString:@"?"];
    NSString *rawPath = q.location == NSNotFound ? target : [target substringToIndex:q.location];
    req.path = MWPercentDecode(rawPath);
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    if (q.location != NSNotFound) {
        for (NSString *pair in [[target substringFromIndex:q.location + 1] componentsSeparatedByString:@"&"]) {
            if (!pair.length) continue;
            NSRange eq = [pair rangeOfString:@"="];
            NSString *k = eq.location == NSNotFound ? pair : [pair substringToIndex:eq.location];
            NSString *v = eq.location == NSNotFound ? @"" : [pair substringFromIndex:eq.location + 1];
            query[MWPercentDecode(k)] = MWPercentDecode(v);
        }
    }
    req.query = query;

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange c = [lines[i] rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        NSString *k = [[lines[i] substringToIndex:c.location] lowercaseString];
        NSString *v = [[lines[i] substringFromIndex:c.location + 1]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        headers[k] = v;
    }
    req.headers = headers;

    NSString *conn = [headers[@"connection"] lowercaseString];
    BOOL http11 = rl.count > 2 && [rl[2] isEqualToString:@"HTTP/1.1"];
    *keepAlive = http11 ? ![conn isEqualToString:@"close"] : [conn isEqualToString:@"keep-alive"];

    NSUInteger len = (NSUInteger)[headers[@"content-length"] longLongValue];
    if (len > kMaxBodyBytes) return nil;
    while (buf.length < len) {
        ssize_t n = read(fd, chunk, MIN(sizeof(chunk), len - buf.length));
        if (n <= 0) return nil;
        [buf appendBytes:chunk length:(NSUInteger)n];
    }
    req.body = [buf subdataWithRange:NSMakeRange(0, len)];
    [buf replaceBytesInRange:NSMakeRange(0, len) withBytes:NULL length:0];
    return req;
}

- (BOOL)writeResponse:(MWResponse *)res request:(MWRequest *)req to:(int)fd keepAlive:(BOOL)keepAlive {
    NSMutableString *h = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)res.status, MWStatusText(res.status)];
    NSMutableDictionary *headers = [res.headers mutableCopy];
    headers[@"Access-Control-Allow-Origin"] = @"*";
    headers[@"Access-Control-Allow-Headers"] = @"Authorization, Content-Type, X-Meow-Token, Accept, Range, Cache-Control";
    headers[@"Access-Control-Allow-Methods"] = @"GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS";
    headers[@"Access-Control-Expose-Headers"] = @"Content-Length, Content-Range, Content-Type";
    headers[@"Access-Control-Allow-Private-Network"] = @"true";
    headers[@"Access-Control-Max-Age"] = @"86400";
    headers[@"Cross-Origin-Resource-Policy"] = @"cross-origin";
    headers[@"Cross-Origin-Opener-Policy"] = @"same-origin";
    headers[@"Cross-Origin-Embedder-Policy"] = @"credentialless";
    if (res.stream) {
        headers[@"Cache-Control"] = @"no-cache";
        headers[@"Connection"] = @"keep-alive";
        headers[@"X-Accel-Buffering"] = @"no";
    } else {
        headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)res.body.length];
        headers[@"Connection"] = keepAlive ? @"keep-alive" : @"close";
    }
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [h appendFormat:@"%@: %@\r\n", k, v];
    }];
    [h appendString:@"\r\n"];
    NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
    if (!MWWriteAll(fd, hd.bytes, hd.length)) return NO;
    if (res.stream) {
        struct timeval tv = { .tv_sec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        res.stream(^BOOL(NSData *chunk) {
            return MWWriteAll(fd, chunk.bytes, chunk.length);
        });
        return NO;
    }
    if (res.body.length && ![req.method isEqualToString:@"HEAD"])
        return MWWriteAll(fd, res.body.bytes, res.body.length);
    return YES;
}

@end
