/// 信頼できない compose.yaml を読むときの上限。尽きたときは `ComposeRefusal` の
/// documentTooLarge / tooManyNodes / tooDeep で止める。
public struct ComposeLimits: Sendable {
    /// 単位 byte。実在の compose.yaml は数 KB〜数十 KB。1 MiB を超えるのは生成物か膨らませる攻撃。
    public var maxBytes: Int
    /// 単位 ノード(エイリアスを展開して数える)。エイリアスの展開で膨らませる攻撃への備え。
    /// 数百サービスでも数千ノード。
    public var maxNodes: Int
    /// 単位 階層。compose の深さは最大でも 6〜7。
    public var maxDepth: Int

    public init(maxBytes: Int, maxNodes: Int, maxDepth: Int) {
        self.maxBytes = maxBytes
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
    }

    public static let standard = ComposeLimits(maxBytes: 1_048_576, maxNodes: 50_000, maxDepth: 32)
}
