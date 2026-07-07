// ObjCExceptionCatcher.h
// Swift からは ObjC の NSException を捕捉できないためのシム。
// XCUITest API(launch 失敗等)は NSException を投げるので、
// これで捕まえてサーバプロセスの死を防ぐ。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// block を実行し、NSException が投げられたらその説明文字列を返す(正常時は nil)。
NSString *_Nullable FTCatchObjCException(void (NS_NOESCAPE ^)(void));

NS_ASSUME_NONNULL_END
