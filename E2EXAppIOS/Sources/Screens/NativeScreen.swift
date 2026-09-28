import SwiftUI
import UIKit

/// iOS 固有部品: UICollectionView(compositional layout)/ .popover / .presentationDetents(小さいシート)。
/// `btn_detent`・`btn_detent_tapped` は契約が id を明記しないため独自に追加(全タップ可能要素に
/// id を付ける方針への補完。echo 文字列 `native=detent:tapped` は契約どおり)。
struct NativeScreen: View {
    @State private var result = "native=none"
    @State private var showPopover = false
    @State private var showDetent = false

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtNativeResult, text: result)

            NativeCollectionView(onTap: { n in result = "native=collection:\(n)" })
                .frame(height: 120)

            TaggedButton(tag: Tags.btnPopover, label: "ポップオーバーを開く") { showPopover = true }
                .popover(isPresented: $showPopover) {
                    TaggedButton(tag: Tags.btnPopoverOk, label: "OK") {
                        result = "native=popover:ok"
                        showPopover = false
                    }
                    .padding()
                }

            TaggedButton(tag: Tags.btnDetent, label: "小さいシートを開く") { showDetent = true }
                .sheet(isPresented: $showDetent) {
                    TaggedButton(tag: Tags.btnDetentTapped, label: "タップする") {
                        result = "native=detent:tapped"
                        showDetent = false
                    }
                    .presentationDetents([.fraction(0.25)])
                }
        }
        .screenTitleTag("固有部品")
    }
}

/// UICollectionViewCompositionalLayout は SwiftUI に相当が無いため UIViewControllerRepresentable で包む。
private struct NativeCollectionView: UIViewControllerRepresentable {
    let onTap: (Int) -> Void

    func makeUIViewController(context: Context) -> UICollectionViewController {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0 / 5.0),
                heightDimension: .fractionalHeight(1.0))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            return NSCollectionLayoutSection(group: group)
        }
        let vc = UICollectionViewController(collectionViewLayout: layout)
        vc.collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        vc.collectionView.backgroundColor = .clear
        vc.collectionView.dataSource = context.coordinator
        vc.collectionView.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UICollectionViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        let onTap: (Int) -> Void
        init(onTap: @escaping (Int) -> Void) { self.onTap = onTap }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 5 }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
            cell.backgroundColor = .systemBlue
            cell.isAccessibilityElement = true
            cell.accessibilityIdentifier = Tags.cvItem(indexPath.item)
            cell.accessibilityLabel = "アイテム \(indexPath.item)"
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            onTap(indexPath.item)
        }
    }
}
