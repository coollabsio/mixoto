#import <Foundation/Foundation.h>

// Runs block and returns NO with error set when it throws an Objective-C exception.
BOOL ObjCCatch(NS_NOESCAPE void (^_Nonnull block)(void), NSError *_Nullable *_Nullable error);
