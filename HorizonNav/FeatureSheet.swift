import SwiftUI

/// First-run guide for new users and a one-time "What's new" sheet for people updating.
/// Bump `featureRevision` and the what's new items whenever a visible feature changes.
struct FeatureSheet: View {
    enum Kind: String, Identifiable {
        case guide
        case whatsNew
        var id: String { rawValue }
    }

    static let featureRevision = 4
    private static let seenKey = "featureSheetRevisionSeen"

    /// The guide on first launch, what's new after an update with new features, otherwise nothing.
    static func kindToShow(defaults: UserDefaults = .standard) -> Kind? {
        let seen = defaults.integer(forKey: seenKey)
        if seen == 0 { return .guide }
        return seen < featureRevision ? .whatsNew : nil
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(featureRevision, forKey: seenKey)
    }

    let kind: Kind
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id = UUID()
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private var items: [Item] {
        var list = [
            Item(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Choose your route",
                 detail: "Search for a place. Horizon Nav shows the fastest route and any alternatives on the map. Tap one to select it, then tap Start."),
            Item(symbol: "arrow.turn.up.right", title: "Turn-by-turn guidance",
                 detail: "The next turn and the distance to it stay at the top of the screen, and the arrival time updates as you drive."),
            Item(symbol: "arrow.triangle.2.circlepath", title: "Automatic rerouting",
                 detail: "Leave the route and Horizon Nav finds a new one from where you are, without you doing anything."),
            Item(symbol: "map.fill", title: "Traffic on the map",
                 detail: "Apple Maps traffic is shown on the phone and in the car, and route times take current traffic into account."),
            Item(symbol: "car.fill", title: "CarPlay",
                 detail: "Connect to CarPlay to search, compare routes and follow turn-by-turn directions on the car screen. A trip started on the phone continues in the car."),
            Item(symbol: "key.fill", title: "TomTom and Mapbox",
                 detail: "Add your own free TomTom or Mapbox key in Settings (the gear button) for their routes, search, traffic, lanes and speed limits. With both, the quicker route is offered first. Without a key, Apple Maps is used."),
            Item(symbol: "arrow.down.circle", title: "Offline maps",
                 detail: "Tap the download button to save a map area, or a routing pack for a country or region. With no signal the map draws saved areas, routes are planned on the phone, and the last route is kept so guidance carries on."),
            Item(symbol: "speaker.wave.2.fill", title: "Spoken directions",
                 detail: "Turns are announced before each junction, with the lane to be in. Use the speaker button to mute, or Settings for alerts only."),
            Item(symbol: "road.lanes", title: "Lanes, speed limits and cameras",
                 detail: "The lanes to use, the speed limit and your speed show on the phone and in CarPlay, and speed cameras ahead are warned about. CarPlay follows the car's day and night look, or your choice in Settings."),
            Item(symbol: "view.3d", title: "Map views and route overview",
                 detail: "While driving, the map zooms with your speed and the next turn. Tap the view button to switch between the tilted view, heading up and north up. Tap the route button to see the rest of the route with the arrival time and traffic delay, and tap it again to follow the car. In CarPlay both buttons are at the top of the map. Settings has Zoom while driving (Closer, Default or Wider) and 3D buildings."),
            Item(symbol: "signpost.right", title: "Junctions on the map",
                 detail: "Traffic lights, level crossings and stop signs on your route show on the map as you drive, from OpenStreetMap, and a sign with the lanes to use stands at the next junction."),
            Item(symbol: "play.circle", title: "Preview a junction",
                 detail: "Before you start, tap Preview a junction and pick a turn or exit to watch a short drive through it, with the instruction and the lanes."),
        ]
        // This revision's features: last in the guide, first in what's new.
        let latest = [
            Item(symbol: "mappin.and.ellipse", title: "Plan from anywhere",
                 detail: "Tap From under Where to? and search for a starting point to look at a route ahead of time. Tap the location button to start from where you are again."),
            Item(symbol: "fuelpump.fill", title: "Stops along the route",
                 detail: "Tap Stops for fuel, charging, coffee, food, services or toilets ahead on your route, each with the extra time it adds. Tap Add stop and the route goes through it. In CarPlay, tap Stops while driving."),
            Item(symbol: "nosign", title: "Avoid a road",
                 detail: "Tap Avoid a road and pick a road or exit on the route. The route is planned again without it for this trip, and Undo puts it back. This needs a TomTom or Mapbox key, or a routing pack with no signal."),
            Item(symbol: "arrow.triangle.branch", title: "Quicker routes on the way",
                 detail: "When a quicker route turns up while you drive, it is offered with what changes: minutes saved, the extra or shorter distance and toll roads. Tap Switch or Keep, on the phone or in CarPlay."),
            Item(symbol: "speedometer", title: "Lower speed limits ahead",
                 detail: "A lower limit coming up shows under your speed with how far it is, for example 50 in 250 m. Settings can speak it too."),
            Item(symbol: "parkingsign", title: "Entrances and parking",
                 detail: "Where TomTom or Mapbox know a place's entrance, the route goes to it and the map marks it, and the side of the street is shown as you arrive. Car parks near the destination are offered as you get close."),
            Item(symbol: "arrow.down.to.line.circle", title: "Offline from the route preview",
                 detail: "Tap Download for offline in the route preview to save the map along the route. The preview says whether a routing pack covers the trip and offers the one you need."),
            Item(symbol: "ticket", title: "Vignettes and low-emission zones",
                 detail: "With a TomTom key, routes that need a motorway vignette or enter a low-emission zone are flagged in the preview and drawn in orange, with links to the rules."),
        ]
        if kind == .guide {
            list.insert(Item(symbol: "magnifyingglass", title: "Search anywhere",
                             detail: "Type a place or address in Where to? at the bottom of the map."), at: 0)
            return list + latest
        }
        return latest + list
    }

    var body: some View {
        NavigationStack {
            List(items) { item in
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: item.symbol).foregroundStyle(.cyan)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle(kind == .guide ? "Welcome" : "What's new")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { dismiss() }
                }
            }
        }
        .onDisappear { Self.markSeen() }
    }
}
