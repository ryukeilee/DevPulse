import SwiftUI
import WidgetKit

/// Entry point for the DevPulse Widget Extension.
@main
struct DevPulseWidget: Widget {
    let kind = "DevPulseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: DevPulseWidgetProvider()
        ) { entry in
            DevPulseWidgetView(entry: entry)
        }
        .configurationDisplayName("DevPulse")
        .description("See your local Git repository status at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
