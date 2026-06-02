#import "CTryCatch.h"

BOOL CTryCatch(void (^tryBlock)(void), NSError * _Nullable * _Nullable error) {
    @try {
        tryBlock();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            info[@"NSExceptionName"] = exception.name;
            if (exception.userInfo) {
                info[@"NSExceptionUserInfo"] = exception.userInfo;
            }
            *error = [NSError errorWithDomain:@"com.speakfree.NSExceptionDomain"
                                         code:0
                                     userInfo:info];
        }
        return NO;
    }
}
