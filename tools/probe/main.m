#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
static void dump(const char *cn, NSString *filter) {
  Class c = objc_getClass(cn); if (!c) { printf("!! no class %s\n", cn); return; }
  for (int meta = 0; meta < 2; meta++) {
    unsigned n; Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
    for (unsigned i = 0; i < n; i++) { NSString *s = NSStringFromSelector(method_getName(m[i]));
      if (!filter || [s rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound)
        printf("%s%s %s\n", meta ? "+" : "-", cn, s.UTF8String); }
    free(m);
  }
}
int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *f = argc > 2 ? @(argv[2]) : nil;
    if (argc > 1 && strcmp(argv[1], "dump") == 0) { for (int i = 3; i < argc; i++) dump(argv[i], [f isEqual:@"-"] ? nil : f); return 0; }
    id dc = [objc_getClass("IMDaemonController") performSelector:@selector(sharedInstance)];
    printf("controller %s\n", [[dc description] UTF8String]);
    SEL s = NSSelectorFromString(@"connectToDaemonWithLaunch:capabilities:blockUntilConnected:");
    BOOL (*fn)(id, SEL, BOOL, unsigned long long, BOOL) = (void *)objc_msgSend;
    BOOL ok = fn(dc, s, YES, getenv("CAPS") ? strtoull(getenv("CAPS"), 0, 0) : 17159, YES);
    printf("caps=%llx\n", [[dc valueForKey:@"capabilities"] unsignedLongLongValue]);
    printf("connect=%d connected=%d\n", ok, (int)[[dc valueForKey:@"isConnected"] boolValue]);
    id reg = [objc_getClass("IMChatRegistry") performSelector:@selector(sharedInstance)];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
    printf("caps after=%llx\n", [[dc valueForKey:@"capabilities"] unsignedLongLongValue]);
    SEL ls = NSSelectorFromString(@"_loadChatsFilteredUsingPredicate:lastMessageOlderThan:limit:waitForReply:completionHandler:");
    void (*lf)(id, SEL, id, id, unsigned long long, BOOL, id) = (void *)objc_msgSend;
    __block BOOL done = NO;
    lf(reg, ls, nil, nil, 50, YES, ^(id x){ printf("load cb %s\n", [[x description] UTF8String]); done = YES; });
    for (int i = 0; i < 50 && !done; i++) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    NSArray *chats = [reg valueForKey:@"allExistingChats"];
    printf("chats=%lu\n", (unsigned long)chats.count);
    for (id c in [chats subarrayWithRange:NSMakeRange(0, MIN(3, chats.count))]) printf(" chat %s\n", [[c valueForKey:@"guid"] UTF8String]);
    id am = [objc_getClass("IMAccountController") performSelector:@selector(sharedInstance)];
    for (id a in [am valueForKey:@"accounts"]) printf(" account %s service=%s active=%d\n", [[a valueForKey:@"login"] UTF8String], [[[a valueForKey:@"service"] valueForKey:@"name"] UTF8String], [[a valueForKey:@"isActive"] intValue]);
  }
  return 0;
}
