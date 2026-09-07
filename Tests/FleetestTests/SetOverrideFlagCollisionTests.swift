// `fleetest run --set <key>=<value>` が Bool 以外の型(String/Int/Double)も受けるようになった
// (FTCore.RunProfileSetOverride)。ここは CLI 層(ArgumentParser の validate())だけを固定する:
// 専用フラグ(--report-dir 等)と同じキーの `--set` を両方渡すと黙ってどちらかを勝たせず
// エラーになること、型の合わない値がコマンドラインの入口で弾かれること。適用ロジック自体
// (FTCore.RunProfileDocument.flagOverrideCollision/applyingOverrides)の単体固定は
// FTCoreTests/RunProfileSetOverrideTests.swift 側。

import XCTest
import ArgumentParser
@testable import fleetest

final class SetOverrideFlagCollisionTests: XCTestCase {

    /// `--report-dir` と `--set reportDir=...` を両方渡すと `fleetest run` の validate() が
    /// 黙ってどちらかを勝たせずエラーにする(reportDirPath の計算(reportDir ?? noProfileSettings.reportDir
    /// ?? …)は最初の non-nil を黙って採用するだけなので、ここで止めないと同じ欄の二重指定が
    /// 気づかれない)
    func testRunRejectsReportDirFlagAndSetOverrideTogether() {
        XCTAssertThrowsError(
            try RunScenarios.parse(["--report-dir", "/tmp/a", "--set", "reportDir=/tmp/b"])
        ) { error in
            let message = RunScenarios.message(for: error)
            XCTAssertTrue(message.contains("--report-dir"), message)
            XCTAssertTrue(message.contains("--set reportDir"), message)
        }
    }

    /// `--report-dir` だけ、`--set reportDir=` だけならどちらも通る(誤検知しない)
    func testRunAllowsReportDirFlagOrSetOverrideAlone() {
        XCTAssertNoThrow(try RunScenarios.parse(["--report-dir", "/tmp/a"]))
        XCTAssertNoThrow(try RunScenarios.parse(["--set", "reportDir=/tmp/b"]))
    }

    /// スカラー欄の型が合わない値は、コマンドラインの入口(validate())で型を名指しして弾く
    /// (デバイスに触れる前に落ちる。RunProfileSetOverrideError.invalidValue が唯一の定義元)
    func testRunRejectsWrongTypedScalarValueAtValidate() {
        XCTAssertThrowsError(try RunScenarios.parse(["--set", "scenarioTimeout=soon"])) { error in
            let message = RunScenarios.message(for: error)
            XCTAssertTrue(message.contains("scenarioTimeout"), message)
            XCTAssertTrue(message.contains("an integer"), message)
        }
    }

    /// `devices`/`remoteControl` は「未知のキー」ではなく専用の案内で断る
    /// (RunProfileSetOverrideError.arrayOrObjectKey)。CLI の入口でもそのまま伝わる
    func testRunRejectsArrayKeyWithADedicatedMessage() {
        XCTAssertThrowsError(try RunScenarios.parse(["--set", "devices=x"])) { error in
            let message = RunScenarios.message(for: error)
            XCTAssertTrue(message.contains("edit the run profile JSON"), message)
        }
    }

    /// `ApiRunCommand` は同期 `validate()` を持たず、`--set` の型検査(RunProfileSetOverride.parse)は
    /// 専用フラグとの衝突チェックと同じく非同期の `run()` の中で行う。**`parse()` 単体では
    /// setOverrides を生の文字列配列としてしか受け取らない**ので、型の合わない値でも
    /// ここでは落ちない(前提が崩れていないことの固定 —— 崩れていたら run() 側の検査が
    /// 二重化するか、あるいは意図せず parse() 側だけで止まって run() の検査コードが
    /// 一度も通らなくなる)
    func testApiRunParseDoesNotEagerlyValidateSetOverrides() {
        XCTAssertNoThrow(
            try ApiRunCommand.parse(["--scenario", "A.S0010", "--set", "defaultTimeout=soon"]))
    }

    /// `api run` 側の衝突チェックは `run()` の先頭(スカラー解析の直後)にあり、プロジェクト解決
    /// (`ScenarioHost.project`)より前に throw する。デバイス・プロジェクトの用意なしに
    /// 決定的に検証できる(この位置より後ろへ動かすと、実プロジェクトが無い環境でこのテストが
    /// 別の理由で失敗するようになる)
    func testApiRunRejectsReportDirFlagAndSetOverrideTogetherBeforeTouchingAnyProject() async throws {
        let command = try ApiRunCommand.parse([
            "--scenario", "A.S0010", "--report-dir", "/tmp/a", "--set", "reportDir=/tmp/b",
        ])
        do {
            try await command.run()
            XCTFail("expected a collision error")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("--report-dir"), error.message)
            XCTAssertTrue(error.message.contains("--set reportDir"), error.message)
        }
    }
}
