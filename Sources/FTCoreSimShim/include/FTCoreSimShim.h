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

/// アプリを起動する(simctl launch の置き換え。往復 883〜909ms → ほぼ0ms・2026-08-02 実測)。
/// udid の SimDevice が引けない/セレクタ欠落なら nil(「シムが使えない」= simctl へフォールバックする契約)。
/// 引けたときは必ず非 nil で、実行結果を
/// @{ @"success": NSNumber(BOOL), @"pid": NSNumber(int, 成功時のみ), @"error": NSString(失敗時のみ) }
/// で返す(「シムが使えない」と「起動そのものが失敗した」を呼び出し側が区別できるようにするため)。
/// environment は **接頭辞なし**のキー名で渡すこと(simctl の SIMCTL_CHILD_ 接頭辞は CoreSimulator に無い。
/// 呼び出し側で剥がす。剥がし忘れると dylib 注入等が届かず無言で失敗する)。
NSDictionary<NSString *, id> * _Nullable FTCoreSimLaunch(NSString *udid, NSString *bundleID,
    NSDictionary<NSString *, NSString *> * _Nullable environment, BOOL terminateRunningProcess);

/// bundleID がインストール済みかを返す(simctl get_app_container の置き換え。約703ms → ほぼ0ms)。
/// シム利用不能なら nil(BOOL の NO と区別するため NSNumber)。
NSNumber * _Nullable FTCoreSimIsInstalled(NSString *udid, NSString *bundleID);


NS_ASSUME_NONNULL_END
