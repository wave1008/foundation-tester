# emulator-proto

Android Emulator の gRPC(EmulatorController)proto の vendored コピー。
出所: `$ANDROID_SDK/emulator/lib/emulator_controller.proto`(emulator 36.5.10 / Apache-2.0)。
上流は「予告なく変わり得る」と明記されているため版を固定してコミットする。

利用箇所(この proto と同期する相手):
- Swift: `Sources/FTEmulatorGrpc/Generated/`(protoc 生成物をコミット。受け手ビルドに protoc を要求しないため)

gRPC を話すのは Swift だけ。拡張は `fleetest api repair-display` 経由で CLI に委譲するため proto のコピーを持たない
(以前あった `vscode-fleetest/assets/emulator_controller.proto` は撤去済み。再導入しないこと)。

## Swift スタブの再生成手順

emulator 更新で proto を取り込み直すときのみ必要(通常は不要):

```sh
# 1) codegen プラグインを「解決済みチェックアウトと同一版」でビルド(版整合の保証)
swift package resolve
swift build -c release --package-path .build/checkouts/swift-protobuf \
  --scratch-path /tmp/pb-build --product protoc-gen-swift
swift build -c release --package-path .build/checkouts/grpc-swift-protobuf \
  --scratch-path /tmp/grpcgen-build --product protoc-gen-grpc-swift-2

# 2) 生成(protoc は brew の protobuf)
protoc \
  --plugin=protoc-gen-swift=/tmp/pb-build/release/protoc-gen-swift \
  --swift_out=Visibility=Public:Sources/FTEmulatorGrpc/Generated \
  --plugin=protoc-gen-grpc-swift-2=/tmp/grpcgen-build/release/protoc-gen-grpc-swift-2 \
  --grpc-swift-2_out=Client=True,Server=False,Visibility=Public:Sources/FTEmulatorGrpc/Generated \
  -I third_party/emulator-proto emulator_controller.proto

swift test --parallel
```
