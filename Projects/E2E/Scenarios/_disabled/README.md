# Scenarios/_disabled

コンパイル対象外の退避場所(Package.swift の `exclude` 指定)。

- 通常実行に載せたくないシナリオ(FM 必須・破壊的等)はここに置く(有効化は Scenarios/ 直下へ移動)
- gen-scenario の生成コードがビルドに失敗した場合もここに隔離される
