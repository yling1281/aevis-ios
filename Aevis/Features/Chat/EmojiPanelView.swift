import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 表情面板：输入框左边的笑脸点开。
///
/// 微信风 8 列紧凑；iMessage 风 4 列大格 + 顶部搜索框 + 横滑分类胶囊。
/// 点一下就走 `onPick`，收不收起由父视图决定。
struct EmojiPanelView: View {
    @ObservedObject private var emoji = EmojiPack.shared

    var theme: ChatTheme = .wechat
    var onPick: (EmojiPack.Item) -> Void

    @State private var query = ""
    @State private var selectedPack = "classic"

    private var isImessage: Bool { theme == .imessage }

    private var columns: [GridItem] {
        if isImessage {
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        }
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
    }

    private var visibleItems: [EmojiPack.Item] {
        emoji.items(inPack: selectedPack, matching: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isImessage {
                searchField
                packBar
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(visibleItems) { item in
                        Button {
                            onPick(item)
                        } label: {
                            cell(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(height: isImessage ? 310 : 230)
    }

    // MARK: - iMessage 顶部

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("搜索表情", text: $query)
                .font(.aevis(14))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.55))
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var packBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(emoji.packs) { pack in
                    Button {
                        selectedPack = pack.id
                    } label: {
                        Text(pack.name)
                            .font(.aevis(13, weight: .medium))
                            .foregroundStyle(
                                selectedPack == pack.id ? Color.white : Color.primary
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(
                                    selectedPack == pack.id
                                        ? ImessagePalette.blue
                                        : Color.white.opacity(0.55)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 格子

    @ViewBuilder
    private func cell(_ item: EmojiPack.Item) -> some View {
        if isImessage {
            imessageCell(item)
        } else {
            wechatCell(item)
        }
    }

    /// iMessage：半透明白底、圆角 14、约 82 高的大格。
    private func imessageCell(_ item: EmojiPack.Item) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.55))
            #if canImport(UIKit)
            if let image = emoji.image(for: item) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 46, height: 46)
            } else {
                Text(item.emoji)
                    .font(.aevis(30))
            }
            #else
            Text(item.emoji)
                .font(.aevis(30))
            #endif
        }
        .frame(maxWidth: .infinity)
        .frame(height: 82)
    }

    /// 微信：8 列紧凑，小图小字。
    @ViewBuilder
    private func wechatCell(_ item: EmojiPack.Item) -> some View {
        #if canImport(UIKit)
        if let image = emoji.image(for: item) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
        } else {
            Text(item.emoji)
                .font(.aevis(26))
                .frame(width: 34, height: 34)
        }
        #else
        Text(item.emoji)
            .font(.aevis(26))
            .frame(width: 34, height: 34)
        #endif
    }
}
