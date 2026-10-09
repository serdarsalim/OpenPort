import SwiftUI

struct TabBarView: View {
    @ObservedObject var store: TerminalSessionStore

    var body: some View {
        HStack(spacing: 6) {
            tab(label: "Dashboard",
                systemImage: "square.grid.2x2",
                selected: store.selectedTab == .dashboard,
                onSelect: { store.selectedTab = .dashboard },
                onClose: nil)

            ForEach(store.sessions) { session in
                TerminalTabChip(session: session, store: store)
            }

            Button {
                store.openHomeSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New terminal in home")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private func tab(label: String, systemImage: String, selected: Bool,
                     onSelect: @escaping () -> Void,
                     onClose: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.primary.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .frame(maxWidth: 200)
    }
}

private struct TerminalTabChip: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: TerminalSessionStore

    private var selected: Bool {
        store.selectedTab == .session(session.id)
    }

    var body: some View {
        HStack(spacing: 6) {
            if session.job?.isServer == true {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .frame(width: 12)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
            }
            Text(session.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                store.close(session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.primary.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { store.select(session.id) }
        .help(tooltip)
        .frame(maxWidth: 220)
    }

    private var tooltip: String {
        guard let job = session.job else { return session.title }
        guard job.isServer else { return job.command }
        let ports = job.ports.map { ":\($0)" }.joined(separator: " ")
        return "\(job.command)\nListening on \(ports)"

    }
}
