#import <Foundation/Foundation.h>

// Timestamped log line to stderr (launchd sends it to /var/mobile/Library/Logs/meowd.log).
void MWLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
