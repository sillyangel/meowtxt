#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#include <notify.h>

static NSString *const kPrefsPlistPath = @"/var/mobile/Library/Preferences/dev.sillyangel.meowtxt.plist";

@interface MWRootListController : PSListController
@end

@implementation MWRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (NSMutableDictionary *)loadConfigDict {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:kPrefsPlistPath];
    return dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *dict = [self loadConfigDict];
    NSString *key = [specifier propertyForKey:@"key"];
    if (key && dict[key] != nil) {
        return dict[key];
    }
    return [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    NSMutableDictionary *dict = [self loadConfigDict];
    if (value != nil) {
        dict[key] = value;
    } else {
        [dict removeObjectForKey:key];
    }
    [dict writeToFile:kPrefsPlistPath atomically:YES];
    notify_post("dev.sillyangel.meowtxt/ReloadPrefs");
}

- (NSString *)tokenValue:(PSSpecifier *)specifier {
    NSDictionary *dict = [self loadConfigDict];
    NSString *tok = [dict[@"token"] isKindOfClass:NSString.class] ? dict[@"token"] : nil;
    return tok.length ? tok : @"Not generated yet";
}

- (void)copyToken {
    NSString *tok = [self tokenValue:nil];
    if (tok.length && ![tok isEqualToString:@"Not generated yet"]) {
        [UIPasteboard generalPasteboard].string = tok;
    }
}

@end
