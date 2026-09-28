import SwiftUI

struct DetailMenuScreen: View {
    var body: some View {
        List {
            ForEach(1...3, id: \.self) { n in
                NavigationLink(value: Route.detail(n)) { Text("詳細 \(n)") }
                    .accessibilityIdentifier(Tags.detailLink(n))
            }
        }
        .screenTitleTag("引数付き遷移")
    }
}

struct DetailScreen: View {
    let id: Int

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtDetailId, text: "id=\(id)")
            NavigationLink(value: Route.detail(id + 1)) { Text("次の詳細") }
                .accessibilityIdentifier(Tags.btnDetailNext)
        }
        .screenTitleTag("詳細")
    }
}
