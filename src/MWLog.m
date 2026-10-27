#import "MWLog.h"

void MWLog(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    NSString *line;
    @synchronized (df) {
        line = [NSString stringWithFormat:@"%@ [meowd] %@\n", [df stringFromDate:[NSDate date]], msg];
    }
    fputs(line.UTF8String, stderr);
    fflush(stderr);
}
