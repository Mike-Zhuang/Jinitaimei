import SwiftUI

extension View {
    /// 空状态作为 List 行展示时，隐藏系统分割线，避免出现只有右侧/中部可见的半截线。
    func listEmptyRowStyle(verticalPadding: CGFloat = 32) -> some View {
        self
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
