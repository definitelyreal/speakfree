#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Run an Objective-C block; if it raises an NSException, returns NO and populates `error`.
/// Swift cannot catch Objective-C exceptions natively — `try` only catches Swift errors.
/// AVAudioEngine throws NSException for invalid `installTap` formats, which under Swift
/// reaches libc++abi's terminate handler and (with libggml linked) crashes via SIGABRT.
/// This 10-line bridge keeps the exception inside Objective-C land so Swift can recover.
BOOL CTryCatch(__attribute__((noescape)) void (^tryBlock)(void),
               NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
