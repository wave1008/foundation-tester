import SwiftUI
import UIKit

@MainActor
final class ChatModel: ObservableObject {
    @Published var result = "chat=none"
    @Published var count = 60
    @Published var atBottom = true
    weak var controller: ChatViewController?
}

/// A2: 反転 UITableView(Element-X と同じ作り)。入力バーは VC の `inputAccessoryView`(Signal と同じ。
/// キーボード側の別ウィンドウに居る入力欄)。echo と `着信` は SwiftUI 側の固定領域。
struct ChatScreen: View {
    @StateObject private var model = ChatModel()

    var body: some View {
        VStack(spacing: 0) {
            EchoArea {
                TaggedText(tag: "txt_chat_result", text: model.result)
                TaggedText(tag: "txt_chat_count", text: "count=\(model.count)")
                TaggedText(tag: "txt_chat_pos", text: "at_bottom=\(model.atBottom)")
                Button("着信") { model.controller?.scheduleIncoming() }
                    .accessibilityIdentifier("btn_incoming")
            }
            ChatContainer(model: model)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .screenTitleTag("反転チャット")
    }
}

private struct ChatContainer: UIViewControllerRepresentable {
    let model: ChatModel
    func makeUIViewController(context: Context) -> ChatViewController { ChatViewController(model: model) }
    func updateUIViewController(_ controller: ChatViewController, context: Context) {}
}

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private static let rowHeight: CGFloat = 56
    private static let flip = CGAffineTransform(scaleX: 1, y: -1)

    private let model: ChatModel
    private let table = UITableView(frame: .zero, style: .plain)
    private let bar = ChatInputBar()
    private let jump = UIButton(type: .system)
    private var tableBottom: NSLayoutConstraint!
    /// 新しい順(row 0 = 最新 = 見た目の最下部)
    private var messages: [(n: Int, text: String)] = (0..<60).reversed().map { ($0, "メッセージ \(Tags.two($0))") }
    private var nextNumber = 60

    init(model: ChatModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.controller = self
    }
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        table.translatesAutoresizingMaskIntoConstraints = false
        table.transform = Self.flip
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.rowHeight
        table.estimatedRowHeight = 0
        table.contentInsetAdjustmentBehavior = .never
        table.keyboardDismissMode = .interactive
        table.separatorStyle = .none
        table.accessibilityIdentifier = "list_chat"
        table.register(ChatCell.self, forCellReuseIdentifier: "cell")
        view.addSubview(table)
        // **下端は keyboardLayoutGuide に繋ぐ**(入力バー = inputAccessoryView・キーボードの上端に追従する)。キーボードの
        // 枠の通知で下端を上げる作りは、画面を開いたときに通知が来ないと一覧と #btn_jump_bottom が入力バーの下へ
        // 潜ったままになった(XCUITest の実タッチは入力バーに当たって押せない)
        tableBottom = table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableBottom,
        ])

        jump.translatesAutoresizingMaskIntoConstraints = false
        var jumpConfig = UIButton.Configuration.filled()
        jumpConfig.title = "最新へ"
        jumpConfig.cornerStyle = .capsule
        jumpConfig.baseBackgroundColor = .secondarySystemBackground
        jumpConfig.baseForegroundColor = .tintColor
        jump.configuration = jumpConfig
        jump.accessibilityIdentifier = "btn_jump_bottom"
        jump.isHidden = true
        jump.addTarget(self, action: #selector(jumpToBottom), for: .touchUpInside)
        view.addSubview(jump)
        NSLayoutConstraint.activate([
            jump.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            jump.bottomAnchor.constraint(equalTo: table.bottomAnchor, constant: -12),
        ])

        bar.sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        bar.field.resignFirstResponder()
        resignFirstResponder()
    }

    // MARK: 状態

    private var nearBottom: Bool { table.contentOffset.y <= 1 }

    private func publishPosition() {
        model.atBottom = nearBottom
        jump.isHidden = nearBottom
    }

    @objc private func jumpToBottom() {
        table.setContentOffset(.zero, animated: true)
    }

    @objc private func send() {
        guard let text = bar.field.text, !text.isEmpty else { return }
        bar.field.text = ""
        insert(text: text, followBottom: true)
    }

    func scheduleIncoming() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.insert(text: "着信 \(Tags.two(self.nextNumber))", followBottom: self.nearBottom)
        }
    }

    /// 最下部に居れば追従して見せる・離れていれば見ている位置を保つ(row 0 への挿入は offset をずらす)。
    private func insert(text: String, followBottom: Bool) {
        messages.insert((nextNumber, text), at: 0)
        nextNumber += 1
        UIView.performWithoutAnimation {
            table.insertRows(at: [IndexPath(row: 0, section: 0)], with: .none)
            table.contentOffset.y = followBottom ? 0 : table.contentOffset.y + Self.rowHeight
        }
        model.count = messages.count
        publishPosition()
    }

    // MARK: UITableView

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! ChatCell
        let m = messages[indexPath.row]
        cell.configure(text: m.text, identifier: "msg_\(Tags.two(m.n))")
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        model.result = "chat=msg_\(Tags.two(messages[indexPath.row].n))"
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { jump.isHidden = nearBottom }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { publishPosition() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { publishPosition() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { publishPosition() }
    }
}

private final class ChatCell: UITableViewCell {
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, identifier: String) {
        label.text = text
        accessibilityLabel = text
        accessibilityIdentifier = identifier
    }
}

private final class ChatInputBar: UIView {
    let field = UITextField()
    let sendButton = UIButton(type: .system)

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 52))
        autoresizingMask = .flexibleHeight
        backgroundColor = .secondarySystemBackground
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = "メッセージを入力"
        field.borderStyle = .roundedRect
        field.returnKeyType = .send
        field.accessibilityIdentifier = "field_chat"
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle("送信", for: .normal)
        sendButton.accessibilityIdentifier = "btn_send"
        addSubview(field)
        addSubview(sendButton)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            field.heightAnchor.constraint(equalToConstant: 36),
            field.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            sendButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
}
