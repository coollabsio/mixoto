#import "ObjCCatch.h"

BOOL ObjCCatch(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:exception.name code:0 userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}
