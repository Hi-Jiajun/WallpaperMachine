import SwiftUI

/// The Collections section of the library sidebar: one row per collection with its size, a plus in
/// the heading for a new one, and Rename… and Delete… in each row's menu.
///
/// A new collection or a rename is typed in a field in the list itself: Return saves, Escape
/// cancels, and a refusal of the name is written under the field. Deleting asks first. The result
/// of a delete is shown under the list for a few seconds and spoken, and an empty section says what
/// collections are for.
struct CollectionsSidebarSection: View {
  let collections: [SidebarCounts.Collection]

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let shell = controller.shell
    let editor = shell.collectionEditor
    Section {
      ForEach(collections) { collection in
        if editor.mode == .rename(collection.id) {
          CollectionNameRow(editor: editor)
        } else {
          row(collection, editor: editor)
        }
      }
      if editor.mode == .create {
        CollectionNameRow(editor: editor)
      }
      if collections.isEmpty && !editor.isOpen {
        SidebarNote(Text("Group wallpapers for browsing and for playlists."))
      }
      if let notice = shell.notice {
        // A collection's name can be long, and the sentence is up for a few seconds only.
        SidebarNote(Text(verbatim: notice))
          .accessibilityIdentifier("collection-notice")
      }
    } header: {
      header(editor)
    }
  }

  private func row(_ collection: SidebarCounts.Collection, editor: CollectionEditorModel)
    -> some View
  {
    Label {
      Text(verbatim: collection.name)
    } icon: {
      Image(systemName: "folder")
    }
    .badge(Text(collection.count, format: .number))
    .tag(SidebarRow.collection(collection.id))
    .contextMenu {
      Button("Rename…") { editor.beginRename(collection.id) }
        .disabled(editor.isChanging)
      Button("Delete…", role: .destructive) { editor.requestDelete(collection.id) }
        .disabled(editor.isChanging)
    }
    // The same two commands for VoiceOver, which does not open a context menu.
    .accessibilityAction(named: Text("Rename…")) { editor.beginRename(collection.id) }
    .accessibilityAction(named: Text("Delete…")) { editor.requestDelete(collection.id) }
    .accessibilityIdentifier("sidebar-collection-\(collection.id)")
  }

  private func header(_ editor: CollectionEditorModel) -> some View {
    HStack(spacing: 4) {
      Text("Collections")
      Spacer(minLength: 0)
      Button {
        editor.beginCreate()
      } label: {
        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(theme.surface.muted.color)
      .frame(width: 20, height: 20)
      .contentShape(Rectangle())
      .disabled(editor.isChanging)
      .help(L("New collection…"))
      .accessibilityLabel(Text(verbatim: L("New collection…")))
      .accessibilityIdentifier("collection-new")
    }
  }
}

/// A line of quiet text in the sidebar list: the empty Collections hint, and the result of a
/// change. It wraps rather than being cut.
///
/// A sidebar row is measured before its width is final, so wrapping text has to ask for its height
/// itself: without the full-width frame and the fixed vertical size it is cut to one line.
struct SidebarNote: View {
  let text: Text

  init(_ text: Text) { self.text = text }

  var body: some View {
    text
      .font(.system(size: 11.5))
      .foregroundStyle(.secondary)
      .lineLimit(4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .selectionDisabled()
  }
}

/// The field a collection is named in. The name is whatever the person types; the store's refusals
/// ("Enter a name between 1 and 128 characters, on one line.") are shown under it.
private struct CollectionNameRow: View {
  @Bindable var editor: CollectionEditorModel

  @Environment(\.panelTheme) private var theme
  @FocusState private var isFocused: Bool

  var body: some View {
    let isRenaming = editor.mode != .create
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "folder")
          .foregroundStyle(theme.surface.muted.color)
          .accessibilityHidden(true)
        TextField("Collection name", text: $editor.name)
          .textFieldStyle(.plain)
          .focused($isFocused)
          .onSubmit { editor.submit() }
          .onExitCommand { editor.cancel() }
          .onChange(of: editor.name) { editor.clearFailure() }
          .accessibilityIdentifier("collection-name")
        Button {
          editor.submit()
        } label: {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .disabled(editor.isChanging || editor.name.trimmingCharacters(in: .whitespaces).isEmpty)
        .help(isRenaming ? L("Save") : L("Create"))
        .accessibilityLabel(Text(verbatim: isRenaming ? L("Save") : L("Create")))
        .accessibilityIdentifier("collection-name-save")
        Button {
          editor.cancel()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(theme.surface.faint.color)
        }
        .buttonStyle(.plain)
        .help(L("Cancel"))
        .accessibilityLabel(Text(verbatim: L("Cancel")))
        .accessibilityIdentifier("collection-name-cancel")
      }
      .padding(.horizontal, 8)
      .frame(minHeight: 28)
      .background(
        theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(
            editor.failure == nil ? theme.surface.line.color : theme.surface.danger.color,
            lineWidth: editor.failure == nil ? 0.5 : 1)
      }
      if let failure = editor.failure {
        Text(verbatim: failure)
          .font(.system(size: 11))
          .foregroundStyle(theme.surface.danger.color)
          .lineLimit(4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("collection-name-error")
      }
    }
    .selectionDisabled()
    .onAppear {
      // The row has to be in the list before it can take the keyboard.
      DispatchQueue.main.async { isFocused = true }
    }
  }
}
