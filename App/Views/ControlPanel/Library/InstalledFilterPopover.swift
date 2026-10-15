import SwiftUI

/// The Filters popover of the Installed page: the collection on show, the tags a wallpaper must
/// have (Show only), and the boxes whose unticking hides every wallpaper that carries the tag.
/// Nothing is sent anywhere: the grid narrows as the boxes change.
struct InstalledFilterPopover: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    FilterPopover(count: model.filterCount, onClear: { model.clearFilters() }) {
      if let collection = model.shownCollection {
        CollectionFilterRow(name: collection.name) { model.showAllWallpapers() }
      }
      FilterGroup(
        "Show only", count: model.filter.requiredTags.count, isExpanded: expansion("show-only")
      ) {
        ForEach(LibraryFilterCatalog.showOnly) { entry in
          RequiredTagToggle(entry: entry)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        let others = model.filter.requiredTags.filter { tag in
          !LibraryFilterCatalog.showOnly.contains { $0.tag == tag }
        }
        if !others.isEmpty {
          Text("Other selected tags")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
          TagFlow(spacing: 6) {
            ForEach(others, id: \.self) { tag in
              Button { model.setRequired(tag, false) } label: {
                TagChip(text: tag, selection: .required)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(Text(verbatim: tag))
              .accessibilityAddTraits(.isSelected)
            }
          }
        }
      }
      ForEach(LibraryFilterCatalog.installedGroups) { group in
        FilterGroup(
          group.title, count: model.filter.excludedCount(among: group.tags),
          isExpanded: expansion(group.key)
        ) {
          ForEach(group.sections) { section in
            ExclusionSection(section: section)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .accessibilityIdentifier("installed-filters")
  }

  private func expansion(_ key: String) -> Binding<Bool> {
    let model = controller.library
    return Binding(
      get: { model.openFilterGroups.contains(key) },
      set: { isOpen in
        if isOpen { model.openFilterGroups.insert(key) } else { model.openFilterGroups.remove(key) }
      })
  }
}

/// The collection the grid is narrowed to, which the count of filters includes. It is chosen in
/// the sidebar; here it can be put away.
private struct CollectionFilterRow: View {
  let name: String
  let onShowAll: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Label {
        Text(verbatim: name).lineLimit(1)
      } icon: {
        Image(systemName: "folder")
      }
      .font(.system(size: 13, weight: .semibold))
      Spacer(minLength: 8)
      Button("Show all wallpapers", action: onShowAll)
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
    .padding(.vertical, 8)
  }
}

/// A "Show only" box: ticking it requires the tag.
private struct RequiredTagToggle: View {
  let entry: LibraryFilterCatalog.RequiredTag

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.library
    Toggle(
      isOn: Binding(
        get: { model.filter.requiredTags.contains(entry.tag) },
        set: { model.setRequired(entry.tag, $0) })
    ) {
      Label {
        entry.label
      } icon: {
        Image(systemName: entry.symbol)
          .foregroundStyle(
            entry.tag == LibraryFilterCatalog.approvedTag
              ? theme.surface.approved.color : Color.secondary)
          .frame(width: 16)
      }
    }
    .toggleStyle(.checkbox)
    .font(.system(size: 13))
  }
}

/// One run of exclusion boxes: an optional heading with All and None, then the tags as chips.
private struct ExclusionSection: View {
  let section: LibraryFilterCatalog.Section

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    let included = model.includedCount(in: section)
    VStack(alignment: .leading, spacing: 6) {
      if section.title != nil || section.hasQuickLinks {
        HStack(spacing: 10) {
          if let title = section.title {
            title.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          if section.hasQuickLinks {
            Button("All") { model.setSection(section.key, included: true) }
              .disabled(included == section.entries.count)
            Button("None") { model.setSection(section.key, included: false) }
              .disabled(included == 0)
          }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
      }
      TagFlow(spacing: 6) {
        ForEach(section.entries) { entry in
          Toggle(
            isOn: Binding(
              get: { model.isIncluded(entry.tag) }, set: { model.setIncluded(entry.tag, $0) })
          ) {
            entry.label
          }
          .toggleStyle(FilterChipToggleStyle())
        }
      }
    }
    .padding(.bottom, 4)
  }
}

/// A tag of the filters as a capsule that is on while wallpapers with it are shown, and struck
/// through in red once it is off, which is how a wallpaper carrying it gets hidden.
private struct FilterChipToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    FilterChip(configuration: configuration)
  }
}

private struct FilterChip: View {
  let configuration: ToggleStyleConfiguration

  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    let isOn = configuration.isOn
    Button {
      configuration.isOn.toggle()
    } label: {
      configuration.label
        .font(.system(size: 11, weight: .medium))
        .strikethrough(!isOn)
        .foregroundStyle(isOn ? theme.surface.tagInk.color : theme.surface.danger.color)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(background(isOn), in: Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    // VoiceOver meets a checkbox, as the web panel's chips were, which it reads as checked or
    // unchecked in the listener's language.
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .toggleStyle(.checkbox)
    }
  }

  private func background(_ isOn: Bool) -> Color {
    if isOn { return isHovering ? theme.surface.selected.color : theme.surface.badge.color }
    return theme.surface.danger.color.opacity(isHovering ? 0.2 : 0.14)
  }
}
