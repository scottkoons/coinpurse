import MapKit
import SwiftUI

/// A coin's map pin, drawn as a picture of the map (made on the iPhone by
/// Apple Maps), with the pin in the middle and a ring for how sure it is.
struct PinMapView: View {
    let pin: Pin
    var tint: Color = .red
    @Environment(\.colorScheme) private var scheme

    @State private var image: UIImage?

    /// How much ground the map shows from top to bottom.
    static let spanMeters: Double = 360

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // A map made for a very different shape would look stretched; show
                // the plain background until the right one is ready.
                if let image, size.height > 1, abs(image.size.width / image.size.height - size.width / size.height) < 0.35 {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Color(.secondarySystemBackground)
                }
                // How sure the iPhone was, to scale.
                if let acc = pin.acc, acc > 5, size.height > 0 {
                    let radius = min(acc / (Self.spanMeters / size.height), size.height * 0.45)
                    Circle()
                        .fill(tint.opacity(0.16))
                        .overlay(Circle().strokeBorder(tint.opacity(0.45), lineWidth: 1))
                        .frame(width: radius * 2, height: radius * 2)
                }
                PinMarker(tint: tint)
                    .offset(y: -15)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .task(id: "\(pin.lat),\(pin.lng),\(Int(size.width))x\(Int(size.height)),\(scheme)") {
                // A card tucked into the stack has no room to show a map.
                guard size.width > 40, size.height > 40 else { return }
                // While a card is opening its size changes every frame: wait for
                // it to settle, and never show a map made for an old size.
                if let hit = MapSnapshots.shared.cached(for: pin, size: size, dark: scheme == .dark) {
                    image = hit
                    return
                }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let snap = await MapSnapshots.shared.image(for: pin, size: size, dark: scheme == .dark)
                guard !Task.isCancelled, let snap else { return }
                withAnimation(.easeOut(duration: 0.25)) { image = snap }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Map pin")
        .accessibilityHint("Opens Apple Maps with directions")
        .accessibilityIdentifier("pinMap")
    }
}

/// The pin itself: a round head in the coin's color on a short stem.
struct PinMarker: View {
    var tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(tint)
                Circle().strokeBorder(.white, lineWidth: 2.5)
                Circle().fill(.white).frame(width: 9, height: 9)
            }
            .frame(width: 30, height: 30)
            Rectangle()
                .fill(.white)
                .frame(width: 2.5, height: 8)
            Ellipse()
                .fill(.black.opacity(0.35))
                .frame(width: 10, height: 4)
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

/// Map pictures are made once per spot and size, then reused, so scrolling
/// the purse never waits on Maps.
final class MapSnapshots {
    static let shared = MapSnapshots()
    private var cache: [String: UIImage] = [:]

    private func key(_ pin: Pin, _ size: CGSize, _ dark: Bool) -> String {
        "\(pin.lat),\(pin.lng),\(Int(size.width))x\(Int(size.height)),\(dark)"
    }

    func cached(for pin: Pin, size: CGSize, dark: Bool) -> UIImage? { cache[key(pin, size, dark)] }

    func image(for pin: Pin, size: CGSize, dark: Bool) async -> UIImage? {
        let key = key(pin, size, dark)
        if let hit = cache[key] { return hit }
        let options = MKMapSnapshotter.Options()
        let center = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng)
        let wide = PinMapView.spanMeters * Double(size.width / max(size.height, 1))
        options.region = MKCoordinateRegion(center: center, latitudinalMeters: PinMapView.spanMeters, longitudinalMeters: wide)
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        cache[key] = snapshot.image
        return snapshot.image
    }
}

/// The pin on a real Apple map, in an open coin: sharp at any size, with
/// Apple's own marker. It does not pan, so swiping still turns the page;
/// a tap opens directions.
struct LivePinMap: View {
    let pin: Pin
    let name: String
    var tint: Color

    var body: some View {
        let center = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng)
        // Held at street level (not just started there): while the card is
        // opening the map is tiny, and a starting spot gets fitted to that.
        Map(position: .constant(.camera(MapCamera(centerCoordinate: center, distance: 650))),
            bounds: MapCameraBounds(minimumDistance: 300, maximumDistance: 900),
            interactionModes: []) {
            if let acc = pin.acc, acc > 5 {
                MapCircle(center: center, radius: acc)
                    .foregroundStyle(tint.opacity(0.16))
                    .stroke(tint.opacity(0.5), lineWidth: 1)
            }
            Marker(name, systemImage: "mappin", coordinate: center)
                .tint(tint)
        }
        .accessibilityElement()
        .accessibilityLabel("Map pin")
        .accessibilityHint("Opens Apple Maps with directions")
        .accessibilityIdentifier("pinMap")
    }
}

/// Opening a pin in Apple Maps, ready to walk back to it.
enum MapsLink {
    static func openDirections(to pin: Pin, name: String) {
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: CLLocation(latitude: pin.lat, longitude: pin.lng), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng)))
        }
        item.name = name
        // From where you are to the pin: Maps shows the route choices and
        // waits for you to tap Go, rather than starting navigation by itself.
        MKMapItem.openMaps(
            with: [MKMapItem.forCurrentLocation(), item],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        )
    }

    /// A link anyone can open, for sharing a pin by text or email.
    static func shareURL(for pin: Pin, name: String) -> URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")
        parts?.queryItems = [
            URLQueryItem(name: "ll", value: "\(pin.lat),\(pin.lng)"),
            URLQueryItem(name: "q", value: name),
        ]
        return parts?.url
    }
}

extension Pin {
    /// "Pinned at 2:14 PM" today, otherwise with the date.
    var pinnedLabel: String {
        let d = date
        if Calendar.current.isDateInToday(d) {
            return "Pinned at " + d.formatted(date: .omitted, time: .shortened)
        }
        return "Pinned " + d.formatted(date: .abbreviated, time: .shortened)
    }
}
