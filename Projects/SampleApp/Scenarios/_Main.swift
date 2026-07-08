// _Main.swift
// ftester-scenarios のエントリポイント(編集不要)。
// このディレクトリ(Scenarios/)に .swift を置いて swift build すればシナリオが認識される。

import FTScenarioRunner

@main
struct ScenariosMain {
    static func main() async {
        await ScenarioRunnerMain.main()
    }
}
