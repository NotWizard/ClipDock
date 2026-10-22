import AppKit
import SwiftUI

/// A queue of items that are pasted one at a time — handy for filling in forms
/// or moving several snippets between apps.
@MainActor
final class PasteStackModel: ObservableObject {
    @Published var queue: [UUID] = []
    @Published var feedback: String?

    private let store: Store

    init(store: Store) {
        self.store = store
    }

    var items: [ClipItem] {
        queue.compactMap { id in store.items.first(where: { $0.id == id }) }
    }

    var isEmpty: Bool { queue.isEmpty }

    func append(_ ids: [UUID]) {
        for id in ids where !queue.contains(id) {
            queue.append(id)
        }
    }

    func remove(_ id: UUID) {
        queue.removeAll { $0 == id }
    }

    func clear() {
        queue.removeAll()
    }

    func move(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }

    /// Pastes the head of the queue and advances.
    func pasteNext(hide: @escaping () -> Void) {
        guard let first = items.first else { return }
        Paster.shared.rememberFrontmostTarget()
        let started = Paster.shared.paste(items: [first], hide: { done in
            hide()
            TroveWindows.shared.hideForPaste(completion: done)
        }) { [self] success in
            if success { queue.removeAll { $0 == first.id }; feedback = nil }
            else { feedback = Paster.shared.lastError ?? "粘贴已取消，条目仍保留在队列中。" }
        }
        if !started {
            feedback = Paster.shared.lastError ?? "已复制。直接粘贴尚不可用，条目仍保留在队列中。"
        }
    }

    func copyNext() {
        guard let first = items.first else { return }
        if Paster.shared.copy(items: [first]) {
            queue.removeAll { $0 == first.id }
            feedback = "已复制并移出队列"
        } else {
            feedback = Paster.shared.lastError ?? "复制失败，条目已保留。"
        }
    }
}

struct PasteStackView: View {
    @ObservedObject var model: PasteStackModel
    @ObservedObject var store: Store
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .foregroundStyle(Theme.accent)
                Text("Paste Stack")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(model.queue.count) queued")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Clear") { model.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .disabled(model.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if model.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("The stack is empty")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Select items in the main window and choose “Add to Paste Stack”.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .frame(width: 14)
                            KindBadge(kind: item.kind, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.system(size: 11)).lineLimit(1)
                                if let text = item.text, item.kind == .text {
                                    Text(text.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button {
                                model.remove(item.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
            }

            if let feedback = model.feedback {
                Text(feedback).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
            }
            Divider()

            HStack(spacing: 8) {
                Button {
                    Paster.shared.rememberFrontmostTarget()
                    model.pasteNext { TroveWindows.shared.hideAll() }
                } label: {
                    Label("Paste next", systemImage: "arrow.down.doc")
                        .font(.system(size: 11))
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.isEmpty)

                Button("Copy next") { model.copyNext() }
                    .disabled(model.isEmpty)

                Spacer()
                Button("Done") { close() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
        }
        .frame(width: 480, height: 380)
        .background(Theme.windowBackground)
    }
}
