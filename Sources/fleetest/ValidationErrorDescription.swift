import ArgumentParser
import Foundation

/// `ArgumentParser.ValidationError` は CustomStringConvertible だけで LocalizedError ではないので、
/// `error.localizedDescription` で写すと「The operation couldn't be completed.
/// (ArgumentParser.ValidationError error 1.)」に潰れて本文が消える。`api *` の NDJSON `finished`
/// (`ApiDeviceFinishedEvent.failure` 等 19 箇所)はすべて localizedDescription を書くので、
/// 呼び手を個別に直さずここで1回だけ本文を返す。**ArgumentParser 自身の CLI 出力は
/// `description` を使うので影響しない**
extension ValidationError: @retroactive LocalizedError {
    public var errorDescription: String? { message }
}
