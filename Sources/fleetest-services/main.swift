// この実行ファイルは Seatbelt の中の setup.sh / teardown.sh から呼ばれ、親の `ServiceGatewayServer` へ
// unix ソケットで頼む。判定は親(方針は FTServices の `ServicePolicy`)。
import Darwin
import FTCore
import Foundation

exit(ServiceGatewayClient.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    out: { FileHandle.standardOutput.write($0) },
    err: { FileHandle.standardError.write($0) }))
