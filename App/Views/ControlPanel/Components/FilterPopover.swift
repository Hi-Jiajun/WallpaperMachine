import SwiftUI

/// The frame of a filters popover: a header with the number of filters in effect and a Clear
/// button, and the filter groups below it. What the groups contain belongs to the page that shows
/// it.
struct FilterPopover<Content: View>: View {
  /// How many filters are in effect.
  let count: Int
  let onClear: () -> Void
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Filters").font(.headline)
        if count > 0 { CountBadge(count: count, style: .attention) }
        Spacer(minLength: 8)
        Button("Clear", action: onClear)
          .buttonStyle(.link)
          .disabled(count == 0)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 0) { content }
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
      }
    }
    .frame(width: 300)
    .frame(maxHeight: 520)
  }
}

/// One group of a filters popover: a disclosure whose title carries how many of its options are on.
struct FilterGroup<Content: View>: View {
  private let title: Text
  let count: Int
  @Binding var isExpanded: Bool
  private let content: Content

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    _ title: LocalizedStringKey, count: Int = 0, isExpanded: Binding<Bool>,
    @ViewBuilder content: () -> Content
  ) {
    self.title = Text(title)
    self.count = count
    _isExpanded = isExpanded
    self.content = content()
  }

  var body: some View {
    // The pages hand in plain get/set bindings, which would snap the group open and shut; the
    // animation rides on the binding so the chevron turns and the rows slide in with it.
    let animation: Animation? = reduceMotion ? nil : .snappy(duration: 0.25)
    DisclosureGroup(isExpanded: $isExpanded.animation(animation)) {
      VStack(alignment: .leading, spacing: 6) { content }
        .padding(.vertical, 6)
    } label: {
      HStack {
        title.font(.system(size: 13, weight: .semibold))
        if count > 0 { CountBadge(count: count) }
      }
    }
    .padding(.vertical, 4)
  }
}
