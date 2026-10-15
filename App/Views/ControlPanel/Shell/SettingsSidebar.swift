import SwiftUI

/// The sidebar while Settings is open: a way back to the library, the search field, and the
/// sections, each with its coloured tile. While a search is typed the rows show how many matches
/// each section has, sections without one fade, and none is highlighted.
struct SettingsSidebar: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    @Bindable var settings = controller.settings
    let search = settings.search
    List(selection: selection(settings, search)) {
      Section {
        Button {
          controller.shell.backToLibrary()
        } label: {
          Label("Back to library", systemImage: "chevron.left")
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-back")
      }
      ForEach(Self.clusters, id: \.first) { cluster in
        Section {
          ForEach(cluster, id: \.self) { section in
            row(section, search: search, settings: settings)
          }
        }
      }
      // Nothing is chosen while the guide covers the window: `.disabled` does not stop a list's
      // arrow keys on macOS.
      .selectionDisabled(controller.shell.isWelcomeOpen)
    }
    .listStyle(.sidebar)
    .searchable(text: $settings.query, placement: .sidebar, prompt: Text("Search settings"))
    .accessibilityLabel(Text(verbatim: L("Settings categories")))
  }

  /// The sections in runs, with the gaps `SettingsSection.startsCluster` marks.
  private static let clusters: [[SettingsSection]] = SettingsSection.allCases.reduce(into: []) {
    clusters, section in
    if section.startsCluster || clusters.isEmpty {
      clusters.append([section])
    } else {
      clusters[clusters.count - 1].append(section)
    }
  }

  private func row(_ section: SettingsSection, search: SettingsSearch, settings: SettingsModel)
    -> some View
  {
    let count = search.count(in: section)
    return HStack(spacing: 8) {
      SymbolTile(systemImage: section.systemImage, color: section.tileColor, size: .small)
      Text(verbatim: settings.text(section.title))
      Spacer(minLength: 4)
      if search.isActive && count > 0 { CountBadge(count: count) }
    }
    .opacity(search.isActive && count == 0 ? 0.4 : 1)
    .tag(section)
    .accessibilityIdentifier("settings-section-\(section.rawValue)")
  }

  private func selection(_ settings: SettingsModel, _ search: SettingsSearch)
    -> Binding<SettingsSection?>
  {
    Binding(
      get: { search.isActive ? nil : settings.selectedSection },
      set: { if let section = $0 { settings.select(section) } })
  }
}
