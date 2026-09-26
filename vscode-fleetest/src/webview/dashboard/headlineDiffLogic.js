// headlineDiffLogic.js
// 前回比の判定だけを持つ純関数群。DOM に触れない(document 参照が無い)ので、
// headlineDiff.js(DOM 描画側)から import されるほか、単体テストから直接 import できる。

/** groups = groupRuns(payload.runs) の戻り値(新しい順・各要素は1実行の構成 run 配列)。
 * 同じ profile で、全構成 run の total/passed/failed が揃っている直前のグループを探す。
 * 見つからなければ null(= 比較相手が無い)。 */
export function selectComparisonGroups(groups) {
  if (!groups || groups.length === 0) {
    return null;
  }
  const latest = groups[0];
  const latestProfile = latest[0] ? latest[0].profile ?? null : null;
  for (let i = 1; i < groups.length; i += 1) {
    const candidate = groups[i];
    const candidateProfile = candidate[0] ? candidate[0].profile ?? null : null;
    if (candidateProfile !== latestProfile) {
      continue;
    }
    const complete = candidate.every(
      (r) => typeof r.total === 'number' && typeof r.passed === 'number' && typeof r.failed === 'number',
    );
    if (!complete) {
      continue;
    }
    return { latest, previous: candidate };
  }
  return null;
}

function scenarioKey(scenario) {
  return scenario.scenarioID + '\u0000' + scenario.platform;
}

// 構成 run 全部のシナリオを (scenarioID, platform) ごとに1件へ畳む。同じ鍵が複数ある
// (broadcast・フリート)ときは1件でも失敗していれば失敗 —— 後勝ちにすると読んだ順で結果が変わる。
// skipKind のある記録(始まっていない)は比較から外す。
function flattenScenarios(payloads) {
  const map = new Map();
  for (const payload of payloads) {
    for (const scenario of payload.scenarios) {
      if (scenario.skipKind) {
        continue;
      }
      const key = scenarioKey(scenario);
      const seen = map.get(key);
      if (!seen || (seen.passed && !scenario.passed)) {
        map.set(key, scenario);
      }
    }
  }
  return map;
}

/** latestPayloads/previousPayloads = results-run 応答の配列(構成 run ごと)。
 * (scenarioID, platform) の組で突き合わせ、新規失敗(最新で失敗かつ前回で成功)と
 * 回復(最新で成功かつ前回で失敗)を返す。比較相手のいないシナリオは無視する。 */
export function computeHeadlineDiff(latestPayloads, previousPayloads) {
  const latestMap = flattenScenarios(latestPayloads);
  const previousMap = flattenScenarios(previousPayloads);
  const newFailures = [];
  const recovered = [];
  for (const [key, latest] of latestMap) {
    const previous = previousMap.get(key);
    if (!previous || latest.passed === previous.passed) {
      continue;
    }
    const entry = { scenarioID: latest.scenarioID, platform: latest.platform };
    if (!latest.passed && previous.passed) {
      newFailures.push(entry);
    } else {
      recovered.push(entry);
    }
  }
  return { newFailures, recovered };
}
