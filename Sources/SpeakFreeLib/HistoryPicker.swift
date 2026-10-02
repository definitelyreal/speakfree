// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import SwiftUI

/// Shared geometry keeps page navigation in step with the number of visible rows.
enum HistoryPickerLayout {
    static let width: CGFloat = 380
    static let rowHeight: CGFloat = 44
    static let pageSize = 6
    static let headerHeight: CGFloat = 72
    static let footerHeight: CGFloat = 48
    static let emptyHeight: CGFloat = 132
    static let screenInset: CGFloat = 8

    static func listHeight(itemCount: Int) -> CGFloat {
        itemCount == 0 ? emptyHeight : CGFloat(min(itemCount, pageSize)) * rowHeight + 8
    }

    /// AppKit screen coordinates, including displays above or left of the main display.
    /// Keep the menu near the pointer with a small gap, then clamp clear of menu bar/Dock.
    static func frame(near pointer: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let x = min(max(pointer.x + 8, bounds.minX), bounds.maxX - width)
        let y = min(max(pointer.y - height - 6, bounds.minY), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

enum HistoryPickerKeyAction: Equatable {
    case close, move(Int), page(Int), activate(copyOnly: Bool), preferences, focusSearch
    case cycleFilter(Int)
    case focusPlainText, focusRow
    case filter(HistoryPickerModel.Filter)

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       filterNavigationFocused: Bool = false, rowNavigationFocused: Bool = false,
                       emptySearchFocused: Bool = false) -> Self? {
        let modifiers = modifiers.intersection([.command, .shift, .option, .control])
        switch (keyCode, modifiers) {
        case (53, []): return .close
        case (48, []): return .cycleFilter(1)
        case (48, .shift): return .cycleFilter(-1)
        case (123, []) where filterNavigationFocused: return .cycleFilter(-1)
        case (124, []) where filterNavigationFocused: return .cycleFilter(1)
        case (124, []) where rowNavigationFocused || emptySearchFocused: return .focusPlainText
        case (123, []) where rowNavigationFocused: return .focusRow
        case (3, .command): return .focusSearch
        case (125, []): return .move(1)
        case (126, []): return .move(-1)
        case (125, .command), (121, []): return .page(1)
        case (126, .command), (116, []): return .page(-1)
        case (36, []), (76, []): return .activate(copyOnly: false)
        case (36, .command), (76, .command): return .activate(copyOnly: true)
        case (43, .command): return .preferences
        case (18, .command): return .filter(.all)
        case (19, .command): return .filter(.dictation)
        case (20, .command): return .filter(.clipboard)
        default: return nil
        }
    }
}

final class HistoryPickerModel: ObservableObject {
    enum Filter: String, CaseIterable { case all, dictation, clipboard }
    enum KeyboardFocus: Hashable { case search, filter(Filter), row, plainText }
    enum PasteBehavior { case ready, pasting, copyOnly }
    @Published var pasteBehavior: PasteBehavior = .ready
    @Published var keyboardFocus: KeyboardFocus? = .search
    @Published var entries: [HistoryEntry] = []
    @Published var query = ""
    @Published var filter: Filter = .all {
        didSet {
            if oldValue != filter { preferences?.set(filter.rawValue, forKey: Self.filterPreferenceKey) }
        }
    }
    @Published var selectedID: UUID?
    @Published var status: String?
    @Published var clipboardEnabled = false
    @Published private(set) var maximumPanelHeight: CGFloat?
    @Published private(set) var selectionScrollRevision: UInt64 = 0
    private(set) var selectionScrollAnchor: UnitPoint?
    private var lastPointerLocation: NSPoint?
    /// Keeps keyboard/mouse ordering tests independent of the user's live pointer.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var choose: ((HistoryEntry, Bool) -> Void)?
    var remove: ((UUID) -> Void)?
    var close: (() -> Void)?
    var openSavedDictations: (() -> Void)?
    var openPreferences: (() -> Void)?
    var resize: (() -> Void)?
    var focusSearchEditor: (() -> Void)?
    private let preferences: UserDefaults?
    static let filterPreferenceKey = "HistoryPickerSelectedFilter"

    init(preferences: UserDefaults? = nil) {
        self.preferences = preferences
        filter = preferences?.string(forKey: Self.filterPreferenceKey).flatMap(Filter.init(rawValue:)) ?? .all
    }

    var showsClipboardDisabled: Bool { filter == .clipboard && !clipboardEnabled }
    var actionVerb: String { pasteBehavior == .copyOnly ? "Copy" : "Paste" }
    var filterNavigationFocused: Bool {
        if case .filter = keyboardFocus { return true }
        return false
    }
    var rowNavigationFocused: Bool { keyboardFocus == .row || keyboardFocus == .plainText }
    /// Row/action focus is logical: leave the text editor ready for type-to-search.
    var editorFocus: KeyboardFocus? { rowNavigationFocused ? .search : keyboardFocus }
    func keyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HistoryPickerKeyAction? {
        HistoryPickerKeyAction.action(keyCode: keyCode, modifiers: modifiers,
            filterNavigationFocused: filterNavigationFocused, rowNavigationFocused: rowNavigationFocused,
            emptySearchFocused: keyboardFocus == .search && query.isEmpty)
    }
    func searchChanged() {
        keyboardFocus = .search
        reconcileSelection()
    }
    var visible: [HistoryEntry] {
        guard !showsClipboardDisabled else { return [] }
        return entries.filter { (filter == .all || $0.source.rawValue == filter.rawValue) && $0.matches(query) }
    }
    var statusHeight: CGFloat { status == nil ? 0 : 48 }
    var chromeHeight: CGFloat {
        HistoryPickerLayout.headerHeight + HistoryPickerLayout.footerHeight + 2 + statusHeight
    }
    private var availableListHeight: CGFloat {
        maximumPanelHeight.map { max(0, $0 - chromeHeight) }
            ?? HistoryPickerLayout.listHeight(itemCount: HistoryPickerLayout.pageSize)
    }
    var pageSize: Int {
        max(1, min(HistoryPickerLayout.pageSize,
                   Int(max(0, availableListHeight - 8) / HistoryPickerLayout.rowHeight)))
    }
    var listHeight: CGFloat {
        let ideal = visible.isEmpty ? HistoryPickerLayout.emptyHeight
            : CGFloat(min(visible.count, pageSize)) * HistoryPickerLayout.rowHeight + 8
        return min(ideal, availableListHeight)
    }
    var showsInlineClipboardPreferences: Bool { showsClipboardDisabled && listHeight >= 60 }
    var preferredSize: NSSize {
        NSSize(width: HistoryPickerLayout.width, height: chromeHeight + listHeight)
    }
    func fit(to visibleFrame: NSRect) {
        let height = max(0, visibleFrame.height - 2 * HistoryPickerLayout.screenInset)
        // Resizing the view can ask the coordinator to position again. Publish only a
        // changed screen constraint, never the size we just calculated from it.
        if maximumPanelHeight != height { maximumPanelHeight = height }
    }
    func resetForPresentation() {
        pasteBehavior = .ready
        lastPointerLocation = pointerLocation()
        selectionScrollAnchor = nil
        query = ""
        keyboardFocus = .search
        selectedID = visible.first?.id
        selectionScrollRevision &+= 1
    }
    func reconcileSelection() {
        selectionScrollAnchor = nil
        if !visible.contains(where: { $0.id == selectedID }) {
            selectedID = visible.first?.id
            selectionScrollRevision &+= 1
        }
        if keyboardFocus == .plainText && visible.first(where: { $0.id == selectedID })?.canPastePlainText != true {
            keyboardFocus = .row
        }
    }
    func select(_ id: UUID) {
        guard visible.contains(where: { $0.id == id }) else { return }
        selectionScrollAnchor = nil
        selectedID = id
    }
    func hover(_ id: UUID, at location: NSPoint) {
        guard location != lastPointerLocation else { return }
        lastPointerLocation = location
        select(id)
        keyboardFocus = .row
    }
    func move(_ delta: Int) {
        selectionScrollAnchor = nil
        moveSelection(delta)
    }
    private func moveSelection(_ delta: Int) {
        keyboardFocus = .row
        // A keyboard scroll can move another row under a stationary pointer. Its
        // new tracking area must not immediately override the keyboard selection.
        lastPointerLocation = pointerLocation()
        let rows = visible
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? 0
        selectedID = rows[min(max(current + delta, 0), rows.count - 1)].id
        selectionScrollRevision &+= 1
    }
    func page(_ direction: Int) {
        selectionScrollAnchor = .top
        moveSelection(direction * pageSize)
    }
    func activate(copyOnly: Bool = false) {
        guard let entry = visible.first(where: { $0.id == selectedID }) ?? visible.first else { return }
        activate(id: entry.id, copyOnly: copyOnly, plainText: keyboardFocus == .plainText)
    }
    func activate(id: UUID, copyOnly: Bool = false, plainText: Bool = false) {
        guard pasteBehavior != .pasting else { return }
        // A row can disappear between mouse-down and mouse-up when history refreshes.
        guard let entry = visible.first(where: { $0.id == id }) else { return }
        select(id)
        if plainText {
            guard let variant = entry.plainTextVariant() else { return }
            choose?(variant, copyOnly || pasteBehavior == .copyOnly)
        } else { choose?(entry, copyOnly || pasteBehavior == .copyOnly) }
    }
    func handle(_ action: HistoryPickerKeyAction) {
        switch action {
        case .close: close?()
        case .move(let delta): move(delta)
        case .page(let direction): page(direction)
        case .activate(let copyOnly): activate(copyOnly: copyOnly)
        case .preferences: openPreferences?()
        case .focusSearch:
            keyboardFocus = .search
            // Reassert native focus even if logical focus was already search.
            focusSearchEditor?()
        case .focusRow: keyboardFocus = .row
        case .focusPlainText:
            if visible.first(where: { $0.id == selectedID })?.canPastePlainText == true {
                keyboardFocus = .plainText
            }
        case .cycleFilter(let direction):
            let filters = Filter.allCases
            let current = filters.firstIndex(of: filter) ?? 0
            let next = (current + direction % filters.count + filters.count) % filters.count
            filter = filters[next]
            keyboardFocus = .filter(filter)
            reconcileSelection()
        case .filter(let value):
            filter = value
            if filterNavigationFocused { keyboardFocus = .filter(value) }
            reconcileSelection()
        }
    }
}

struct HistoryPickerView: View {
    @ObservedObject var model: HistoryPickerModel
    @FocusState private var focusedControl: HistoryPickerModel.KeyboardFocus?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search history", text: $model.query)
                        .textFieldStyle(.plain).focused($focusedControl, equals: .search)
                        .simultaneousGesture(TapGesture().onEnded { model.keyboardFocus = .search })
                        .help("Search history (⌘F). Tab cycles source filters.")
                        .onSubmit { model.activate() }
                }.padding(.horizontal, 12).frame(height: 40)
                HStack(spacing: 5) {
                    chip(.all, label: "All", shortcut: "⌘1") { Text("All") }
                    chip(.dictation, label: "Dictations", shortcut: "⌘2") {
                        Image(nsImage: StatusBarController.drawLogo(active: false))
                            .renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16)
                    }
                    chip(.clipboard, label: "Clipboard", shortcut: "⌘3") {
                        Image(systemName: "clipboard")
                    }
                    Spacer(minLength: 0)
                    if !model.showsClipboardDisabled {
                        Text("\(model.visible.count)").foregroundStyle(.secondary)
                            .accessibilityLabel("\(model.visible.count) items")
                    }
                }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: 32)
            }.frame(height: HistoryPickerLayout.headerHeight)
            Divider()
            Group {
                if model.showsClipboardDisabled {
                    ScrollView {
                        VStack(spacing: 8) {
                            Text("Turn on clipboard manager in")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if model.showsInlineClipboardPreferences { preferencesButton }
                        }.frame(maxWidth: .infinity, minHeight: model.listHeight)
                    }
                } else if model.visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                        Text(model.query.isEmpty ? "Your next dictation appears here" : "No matching items")
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(model.visible) { entry in row(entry).id(entry.id) }
                            }.padding(4)
                        }
                        .onChange(of: model.selectionScrollRevision) { _ in
                            if let value = model.selectedID { reader.scrollTo(value, anchor: model.selectionScrollAnchor) }
                        }
                    }
                }
            }.frame(maxWidth: .infinity).frame(height: model.listHeight)
            Divider()
            if let status = model.status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(3).help(status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).frame(height: model.statusHeight)
            }
            VStack(spacing: 5) {
                HStack {
                    Text(model.pasteBehavior == .copyOnly
                         ? "↩ Copy   → Plain text   ⇥ Filters   ⎋ Close"
                         : "↩ Paste   → Plain text   ⇥ Filters   ⎋ Close").lineLimit(1)
                    Spacer()
                    Text("⌘↑↓ Page").fixedSize()
                }
                HStack {
                    Button("Saved Dictations") { model.openSavedDictations?() }
                        .buttonStyle(.link)
                        .help("Open saved recordings, Edit sessions, and recovery actions")
                    Spacer()
                    if !model.showsInlineClipboardPreferences {
                        preferencesButton
                    }
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: HistoryPickerLayout.footerHeight)
        }
        .font(.system(size: 12))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { focusedControl = model.editorFocus; model.reconcileSelection() }
        .onChange(of: model.keyboardFocus) { _ in focusedControl = model.editorFocus }
        // AppKit may temporarily focus a chip while a nonactivating panel opens.
        // Only deliberate clicks/keys change logical navigation, never that fallback.
        .onChange(of: model.query) { _ in model.searchChanged() }
        .onChange(of: model.filter) { _ in model.reconcileSelection() }
        .onChange(of: model.clipboardEnabled) { _ in model.reconcileSelection() }
        .onChange(of: model.preferredSize) { _ in model.resize?() }
    }

    private var preferencesButton: some View {
        Button("Preferences…") { model.openPreferences?() }
            .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.primary)
            .help("Open Clipboard preferences (⌘,)")
    }

    private func chip<Content: View>(_ filter: HistoryPickerModel.Filter, label: String, shortcut: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        let unavailable = filter == .clipboard && !model.clipboardEnabled
        return Button {
            model.filter = filter
            model.keyboardFocus = .filter(filter)
        } label: {
            HStack(spacing: 4) { content() }.frame(minWidth: 24)
                .padding(.horizontal, 7).frame(height: 23)
                .foregroundStyle(unavailable ? Color.secondary : Color.primary)
                .opacity(unavailable ? 0.55 : 1)
                .background(model.filter == filter ? Color.secondary.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
            .focusable()
            .focusEffectDisabled()
            .focused($focusedControl, equals: .filter(filter))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(model.keyboardFocus == .filter(filter) ? Color.accentColor : .clear, lineWidth: 1))
            .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
            .accessibilityLabel(unavailable ? "Clipboard history is off. Show how to enable it." : label)
            .help(unavailable ? "Clipboard history is off. Open for details (\(shortcut))." : "\(label) (\(shortcut))")
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 0) {
          Button { model.activate(id: entry.id) } label: {
            HStack(spacing: 8) {
                if entry.containsImage {
                    HistoryThumbnail(entry: entry, sideLength: 28)
                } else {
                    Image(systemName: entry.source == .dictation ? "waveform" : entry.containsFiles ? "doc" : "clipboard")
                        .foregroundStyle(.secondary).frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayTitle.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        Text(entry.source == .dictation ? "Dictation" : "Clipboard")
                        if entry.representationNote != nil { Text("· PNG") }
                        if entry.searchWasTruncated { Text("· Limited search") }
                        if entry.containsImage && !entry.containsFiles {
                            Spacer(minLength: 0)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                        }
                    }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).frame(height: HistoryPickerLayout.rowHeight)
            .contentShape(Rectangle())
          }.buttonStyle(.plain)
          if entry.source == .clipboard {
            Button { model.activate(id: entry.id, plainText: true) } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
                    .foregroundStyle(entry.canPastePlainText ? Color.primary : Color.secondary.opacity(0.4))
                    .background(entry.canPastePlainText ? Color.primary.opacity(0.08) : .clear, in: Circle())
                    .overlay(Circle().strokeBorder(
                        model.selectedID == entry.id && model.keyboardFocus == .plainText ? Color.accentColor : .clear,
                        lineWidth: 2))
            }.buttonStyle(.plain).disabled(!entry.canPastePlainText)
                .accessibilityLabel("\(model.actionVerb) as Plain Text")
                .help(entry.canPastePlainText ? "\(model.actionVerb) as Plain Text (→ then ↩)" : "No convertible rich text in this item")
                .padding(.trailing, 8)
          }
        }
        .background(model.selectedID == entry.id ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            // Pointer selection must never scroll a partially visible row under the
            // pointer, which would move the next click to a different history item.
            if case .active = phase { model.hover(entry.id, at: model.pointerLocation()) }
        }
        .help([entry.displayTitle, entry.representationNote,
               entry.searchWasTruncated ? "Search covers the first 64 KB; full content is kept." : nil]
            .compactMap { $0 }.joined(separator: "\n"))
        .contextMenu {
            Button(model.actionVerb) { model.activate(id: entry.id) }
            Button("\(model.actionVerb) as Plain Text") { model.activate(id: entry.id, plainText: true) }
                .disabled(!entry.canPastePlainText)
            if model.pasteBehavior != .copyOnly {
                Button("Copy") { model.activate(id: entry.id, copyOnly: true) }
            }
            Divider()
            Button("Remove from History") { model.remove?(entry.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("\(model.actionVerb) this item")
        .accessibilityAddTraits(model.selectedID == entry.id ? .isSelected : [])
    }
}

/// History behaves like a menu: the first click chooses even while another app
/// remains active behind this nonactivating panel.
final class HistoryHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var handleKey: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?
    var onClose: (() -> Void)?
    @discardableResult
    func focusSearchEditor() -> Bool {
        contentView?.layoutSubtreeIfNeeded()
        func searchField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        guard let contentView, let field = searchField(in: contentView) else { return false }
        return makeFirstResponder(field)
    }
    override func resignKey() { super.resignKey(); onResignKey?() }
    override func close() { onClose?(); super.close() }
    override func keyDown(with event: NSEvent) {
        if handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
}
