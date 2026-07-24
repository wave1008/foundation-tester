// CoreSimulator 直叩きシム(dlopen+objc_msgSend。リンクしない)。
// SimulatorCatalog(Swift)から使う。私有 API のためセレクタ存在を毎回ガードし、
// 利用不能なら nil を返す(呼び出し側が simctl にフォールバックする契約)。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 利用可能な iOS シミュレータの列挙。各要素は
/// @{ @"udid": NSString, @"name": NSString, @"os": NSString(例 "iOS 27.0"), @"booted": NSNumber(BOOL) }。
/// CoreSimulator が使えない環境(クラス/セレクタ欠落・ctx 取得失敗)では nil。
/// 初期化(dlopen+SimServiceContext ~470ms)は初回のみ。保持する deviceSet は
/// boot/shutdown に live 追従する(2026-07-25 実測)ため再初期化不要。
NSArray<NSDictionary<NSString *, id> *> * _Nullable FTCoreSimListDevices(void);

NS_ASSUME_NONNULL_END
