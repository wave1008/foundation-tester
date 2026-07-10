// profileSchema.test.mjs
// schemas/{app,machine,run}-profile.schema.json が実在の
// Projects/SampleApp/profiles/{apps,machines,runs}/*.json 全ファイルを受理することを確認する。
//
// ajv 等の外部ライブラリは devDependency に追加できない制約があるため、このテストのためだけの
// 最小限の JSON Schema サブセット評価器(type/required/properties/items/minItems/minLength/
// minimum/maximum/$ref(#/definitions/...))をここに実装する(schemas/*.schema.json が実際に
// 使う機能のみ対応。汎用の JSON Schema 実装ではない)。
//
// src/*.ts には依存しない(vscode-ftester の TypeScript 側ではなく、拡張マニフェストが指す
// schemas/*.schema.json と、リポジトリの実データの整合性を見るテストのため)。

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

// npm test は vscode-ftester/ を cwd として実行される(package.json の "test" スクリプト)ので、
// リポジトリルート(Package.swift のあるフォルダ)はその1つ上(e2e-*.test.mjs と同じ)。
const REPO_ROOT = path.resolve(process.cwd(), "..");
const SCHEMAS_DIR = path.resolve(process.cwd(), "schemas");
const PROFILES_DIR = path.join(REPO_ROOT, "Projects", "SampleApp", "profiles");

const SCHEMA_FILE_BY_KIND = {
  apps: "app-profile.schema.json",
  machines: "machine-profile.schema.json",
  runs: "run-profile.schema.json",
};

function loadJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function resolveSchema(schema, root) {
  if (schema && typeof schema === "object" && typeof schema.$ref === "string") {
    const refPath = schema.$ref.replace(/^#\//, "").split("/");
    let target = root;
    for (const key of refPath) {
      target = target[key];
    }
    return target;
  }
  return schema;
}

/** schemas/*.schema.json が実際に使う機能だけをサポートする最小限の評価器。 */
function validateAgainstSchema(schemaNode, value, root, pathLabel, errors) {
  const schema = resolveSchema(schemaNode, root);
  if (!schema || typeof schema !== "object") {
    return;
  }
  switch (schema.type) {
    case "object": {
      if (typeof value !== "object" || value === null || Array.isArray(value)) {
        errors.push(`${pathLabel}: object を期待しましたが実際は ${typeof value} でした`);
        return;
      }
      for (const key of schema.required ?? []) {
        if (!(key in value)) {
          errors.push(`${pathLabel}: 必須キー "${key}" がありません`);
        }
      }
      for (const [key, propSchema] of Object.entries(schema.properties ?? {})) {
        if (key in value) {
          validateAgainstSchema(propSchema, value[key], root, `${pathLabel}.${key}`, errors);
        }
      }
      return;
    }
    case "array": {
      if (!Array.isArray(value)) {
        errors.push(`${pathLabel}: array を期待しましたが実際は ${typeof value} でした`);
        return;
      }
      if (typeof schema.minItems === "number" && value.length < schema.minItems) {
        errors.push(`${pathLabel}: minItems ${schema.minItems} 未満です(実際: ${value.length})`);
      }
      if (schema.items) {
        value.forEach((item, index) =>
          validateAgainstSchema(schema.items, item, root, `${pathLabel}[${index}]`, errors),
        );
      }
      return;
    }
    case "string": {
      if (typeof value !== "string") {
        errors.push(`${pathLabel}: string を期待しましたが実際は ${typeof value} でした`);
      } else if (typeof schema.minLength === "number" && value.length < schema.minLength) {
        errors.push(`${pathLabel}: minLength ${schema.minLength} 未満です`);
      }
      return;
    }
    case "boolean": {
      if (typeof value !== "boolean") {
        errors.push(`${pathLabel}: boolean を期待しましたが実際は ${typeof value} でした`);
      }
      return;
    }
    case "integer": {
      if (!Number.isInteger(value)) {
        errors.push(`${pathLabel}: integer を期待しましたが実際は ${JSON.stringify(value)} でした`);
        return;
      }
      if (typeof schema.minimum === "number" && value < schema.minimum) {
        errors.push(`${pathLabel}: minimum ${schema.minimum} 未満です`);
      }
      if (typeof schema.maximum === "number" && value > schema.maximum) {
        errors.push(`${pathLabel}: maximum ${schema.maximum} を超えています`);
      }
      return;
    }
    default:
      return; // 未対応の type(このリポジトリのスキーマでは使用しない)は無視する
  }
}

function jsonFilesIn(dir) {
  return readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
    .map((entry) => path.join(dir, entry.name))
    .sort();
}

for (const [kind, schemaFileName] of Object.entries(SCHEMA_FILE_BY_KIND)) {
  const schema = loadJson(path.join(SCHEMAS_DIR, schemaFileName));
  const dir = path.join(PROFILES_DIR, kind);
  const files = jsonFilesIn(dir);

  test(`スキーマ照合: Projects/SampleApp/profiles/${kind}/*.json(${files.length}件)が ${schemaFileName} にパスする`, () => {
    assert.ok(files.length > 0, `${dir} に .json ファイルが1件以上あること`);
    for (const file of files) {
      const value = loadJson(file);
      const errors = [];
      validateAgainstSchema(schema, value, schema, path.basename(file), errors);
      assert.deepEqual(errors, [], `${path.relative(REPO_ROOT, file)} がスキーマ照合エラーなしであること`);
    }
  });
}
