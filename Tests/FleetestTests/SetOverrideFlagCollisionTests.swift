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

    /// `ApiRunCommand` も `RunScenarios` と同じく `validate()` で `--set` の型検査
    /// (RunProfileSetOverride.parse)を行うため、型の合わない値は parse() 自体で落ちる
    /// (プロジェクト解決やデバイスに触れる前。専用フラグとの衝突チェックと同じ場所)
    func testApiRunEagerlyValidatesSetOverridesAtParse() {
        XCTAssertThrowsError(
            try ApiRunCommand.parse(["--scenario", "A.S0010", "--set", "defaultTimeout=soon"])
        ) { error in
            let message = ApiRunCommand.message(for: error)
            XCTAssertTrue(message.contains("defaultTimeout"), message)
        }
    }

    /// `api run` 側の衝突チェックは `validate()`(= parse 時点)にあり、プロジェクト解決
    /// (`ScenarioHost.project`)より前に throw する。デバイス・プロジェクトの用意なしに
    /// 決定的に検証できる(この位置より後ろへ動かすと、実プロジェクトが無い環境でこのテストが
    /// 別の理由で失敗するようになる)
    func testApiRunRejectsReportDirFlagAndSetOverrideTogetherAtParse() {
        XCTAssertThrowsError(
            try ApiRunCommand.parse([
                "--scenario", "A.S0010", "--report-dir", "/tmp/a", "--set", "reportDir=/tmp/b",
            ])
        ) { error in
            let message = ApiRunCommand.message(for: error)
            XCTAssertTrue(message.contains("--report-dir"), message)
            XCTAssertTrue(message.contains("--set reportDir"), message)
        }
    }
}
