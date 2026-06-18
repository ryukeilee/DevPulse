import SwiftUI
import WidgetKit

/// Main widget entry view that routes to the correct size-specific view.
struct DevPulseWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: DevPulseWidgetEntry

    var body: some View {
        Group {
            if family == .systemSmall {
                SmallWidgetView(entry: entry)
            } else if family == .systemMedium {
                MediumWidgetView(entry: entry)
            } else {
                LargeWidgetView(entry: entry)
            }
        }
    }
}
