#import <Foundation/Foundation.h>
#include <krb5.h>
#include <profile.h>

// A small Objective-C boundary a future Swift client can import. No UI or I/O.
@interface KPBuildBridge : NSObject
+ (NSString *)runtimeName;
@end
@implementation KPBuildBridge
+ (NSString *)runtimeName {
    profile_t profile = NULL;
    krb5_context context = NULL;
    if (profile_init(NULL, &profile) != 0) return nil;
    int error = krb5_init_context_profile(profile, KRB5_INIT_CONTEXT_SECURE, &context);
    profile_release(profile);
    if (error != 0) return nil;
    krb5_free_context(context);
    return @"MIT Kerberos";
}
@end

int bridge_probe(void) {
    @autoreleasepool {
        return [[KPBuildBridge runtimeName] isEqualToString:@"MIT Kerberos"] ? 0 : 1;
    }
}
