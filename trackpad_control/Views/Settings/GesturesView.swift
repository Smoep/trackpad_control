import SwiftUI

struct GesturesView: View {
    @State private var appState = AppState.shared
    @State private var searchText = ""
    @State private var filterMode: FilterMode = .all
    @State private var fingerFilter: Int? = nil
    @State private var typeFilter: InputType? = nil

    enum FilterMode: String, CaseIterable {
        case all = "All"
        case enabled = "Enabled"
        case disabled = "Disabled"
    }

    var filteredGestures: [GestureDefinition] {
        appState.gestures.filter { gesture in
            let matchesSearch = searchText.isEmpty ||
                gesture.name.localizedCaseInsensitiveContains(searchText)
            let matchesFilter = switch filterMode {
            case .all: true
            case .enabled: gesture.isEnabled
            case .disabled: !gesture.isEnabled
            }
            let matchesFinger = fingerFilter == nil || gesture.fingerCount == fingerFilter
            let matchesType = typeFilter == nil || gesture.inputType == typeFilter
            return matchesSearch && matchesFilter && matchesFinger && matchesType
        }
    }

    private func gesturesOfType(_ type: InputType) -> [GestureDefinition] {
        filteredGestures.filter { $0.inputType == type }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            topBar
            Divider()

            // Gesture list grouped by type
            if filteredGestures.isEmpty {
                emptyState
            } else {
                gestureList
            }
        }
        .sheet(isPresented: $appState.isShowingEditor, onDismiss: {
            appState.isRecordingArmed = false
            appState.recordedPaths = nil
            appState.recordingLivePaths = []
        }) {
            if let gesture = appState.editingGesture {
                GestureEditorSheet(gesture: gesture, isNew: appState.isCreatingNew)
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 140)

            Picker("", selection: $filterMode) {
                ForEach(FilterMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Spacer()

            // Type filter
            Menu {
                Button { typeFilter = nil } label: {
                    Label("All Types", systemImage: "square.grid.2x2")
                }
                Divider()
                ForEach(InputType.allCases, id: \.self) { type in
                    Button { typeFilter = type } label: {
                        Label(type.rawValue, systemImage: type.icon)
                    }
                }
            } label: {
                Image(systemName: typeFilter?.icon ?? "square.grid.2x2")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("Filter by input type")

            // Finger filter
            Menu {
                Button("All Fingers") { fingerFilter = nil }
                Divider()
                ForEach(1...5, id: \.self) { count in
                    Button("\(count)F") { fingerFilter = count }
                }
            } label: {
                Image(systemName: "hand.raised.fingers.spread")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)

            // Create menu
            Menu {
                ForEach(InputType.allCases, id: \.self) { type in
                    Button {
                        appState.createNewGesture(inputType: type)
                    } label: {
                        Label(type.rawValue, systemImage: type.icon)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderedButton)
            .help("Create new input")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Inputs", systemImage: "hand.draw")
        } description: {
            if searchText.isEmpty && filterMode == .all && fingerFilter == nil && typeFilter == nil {
                Text("Create your first trackpad input to get started.")
            } else {
                Text("No inputs match your current filters.")
            }
        } actions: {
            if searchText.isEmpty && filterMode == .all && fingerFilter == nil && typeFilter == nil {
                Menu("Create Input") {
                    ForEach(InputType.allCases, id: \.self) { type in
                        Button {
                            appState.createNewGesture(inputType: type)
                        } label: {
                            Label(type.rawValue, systemImage: type.icon)
                        }
                    }
                }
                .menuStyle(.borderedButton)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Gesture List

    private var gestureList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(InputType.allCases, id: \.self) { type in
                    let items = gesturesOfType(type)
                    if !items.isEmpty {
                        typeSection(type: type, gestures: items)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func typeSection(type: InputType, gestures: [GestureDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: type.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(type.rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(type.description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(gestures.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            ForEach(gestures) { gesture in
                GestureRowView(gesture: gesture)
            }
        }
    }
}
