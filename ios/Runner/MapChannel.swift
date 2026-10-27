import CryptoKit
import Flutter
import MapKit
import UIKit

/// The travel diary's map: an `MKMapView` platform view (`byo.photos/map_view`),
/// each with its own channel `byo.photos/map/<id>`, plus `byo.photos/places`
/// for search and snapshots. MapKit ships with iOS: no package, no tiles.
enum MapChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(
      MapViewFactory(messenger: registrar.messenger()),
      withId: "byo.photos/map_view"
    )
    let places = FlutterMethodChannel(
      name: "byo.photos/places",
      binaryMessenger: registrar.messenger()
    )
    places.setMethodCallHandler { call, result in
      switch call.method {
      case "search":
        PlaceSearch.search(call.arguments as? [String: Any] ?? [:], result)
      case "snapshot":
        MapSnapshots.snapshot(call.arguments as? [String: Any] ?? [:], result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

// MARK: - Shared drawing

struct MapPin {
  let id: String
  let coordinate: CLLocationCoordinate2D
  let title: String
  let number: Int?

  static func list(_ raw: Any?) -> [MapPin] {
    guard let items = raw as? [[String: Any]] else { return [] }
    return items.compactMap { item in
      guard let id = item["id"] as? String,
        let lat = item["lat"] as? Double,
        let lng = item["lng"] as? Double
      else { return nil }
      return MapPin(
        id: id,
        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
        title: item["title"] as? String ?? "",
        number: item["number"] as? Int
      )
    }
  }
}

/// Points, and per segment whether it's a flight (drawn as a great circle).
struct MapLine {
  let points: [CLLocationCoordinate2D]
  let geodesic: [Bool]

  static func from(_ raw: Any?) -> MapLine? {
    guard let args = raw as? [String: Any],
      let pts = args["points"] as? [[Double]], pts.count >= 2
    else { return nil }
    let points = pts.compactMap { p in
      p.count == 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil
    }
    let flags = args["geodesic"] as? [Bool] ?? []
    return MapLine(points: points, geodesic: flags)
  }

  /// One overlay per segment, so flights curve and the rest stay straight.
  var overlays: [MKOverlay] {
    var out: [MKOverlay] = []
    for i in 0..<max(0, points.count - 1) {
      var pair = [points[i], points[i + 1]]
      if i < geodesic.count && geodesic[i] {
        out.append(MKGeodesicPolyline(coordinates: &pair, count: 2))
      } else {
        out.append(MKPolyline(coordinates: &pair, count: 2))
      }
    }
    return out
  }
}

final class PinAnnotation: NSObject, MKAnnotation {
  let pin: MapPin
  var coordinate: CLLocationCoordinate2D { pin.coordinate }
  var title: String? { pin.title.isEmpty ? nil : pin.title }

  init(_ pin: MapPin) { self.pin = pin }
}

// MARK: - Platform view

final class MapViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    MapPlatformView(frame: frame, id: viewId, messenger: messenger, args: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class MapPlatformView: NSObject, FlutterPlatformView, MKMapViewDelegate {
  private let map: MKMapView
  private let channel: FlutterMethodChannel

  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
    map = MKMapView(frame: frame)
    channel = FlutterMethodChannel(
      name: "byo.photos/map/\(id)",
      binaryMessenger: messenger
    )
    super.init()
    map.delegate = self
    map.pointOfInterestFilter = .includingAll
    if let args = args as? [String: Any], args["interactive"] as? Bool == false {
      map.isScrollEnabled = false
      map.isZoomEnabled = false
      map.isRotateEnabled = false
      map.isPitchEnabled = false
    }
    let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
    map.addGestureRecognizer(press)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  func view() -> UIView { map }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "setPins":
      map.removeAnnotations(map.annotations)
      map.addAnnotations(MapPin.list(call.arguments).map(PinAnnotation.init))
      result(nil)
    case "setPolyline":
      map.removeOverlays(map.overlays)
      if let line = MapLine.from(call.arguments) {
        map.addOverlays(line.overlays)
      }
      result(nil)
    case "fitAll":
      fitAll(animated: (call.arguments as? Bool) ?? true)
      result(nil)
    case "focus":
      guard let args = call.arguments as? [String: Any],
        let lat = args["lat"] as? Double, let lng = args["lng"] as? Double
      else {
        result(nil)
        return
      }
      let span = args["span"] as? Double ?? 0.05
      map.setRegion(
        MKCoordinateRegion(
          center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
          span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        ),
        animated: true
      )
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func fitAll(animated: Bool) {
    var rect = MKMapRect.null
    for a in map.annotations {
      let p = MKMapPoint(a.coordinate)
      rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
    }
    for o in map.overlays {
      rect = rect.union(o.boundingMapRect)
    }
    guard !rect.isNull else { return }
    if rect.size.width < 2000 && rect.size.height < 2000 {
      // One pin: a neighbourhood around it, not the closest zoom.
      rect = rect.insetBy(dx: -4000, dy: -4000)
    }
    map.setVisibleMapRect(
      rect,
      edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
      animated: animated
    )
  }

  @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began else { return }
    let c = map.convert(g.location(in: map), toCoordinateFrom: map)
    channel.invokeMethod("longPress", arguments: ["lat": c.latitude, "lng": c.longitude])
  }

  func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
    guard let a = annotation as? PinAnnotation else { return nil }
    let view =
      mapView.dequeueReusableAnnotationView(withIdentifier: "pin") as? MKMarkerAnnotationView
      ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: "pin")
    view.annotation = a
    view.canShowCallout = false
    view.glyphText = a.pin.number.map(String.init)
    view.markerTintColor = .systemTeal
    return view
  }

  func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
    guard let a = view.annotation as? PinAnnotation else { return }
    mapView.deselectAnnotation(a, animated: false)
    channel.invokeMethod("pinTapped", arguments: a.pin.id)
  }

  func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
    guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
    let r = MKPolylineRenderer(polyline: line)
    r.strokeColor = .systemTeal
    r.lineWidth = 3
    if overlay is MKGeodesicPolyline { r.lineDashPattern = [6, 6] }
    return r
  }
}

// MARK: - Search

enum PlaceSearch {
  /// `{query, lat?, lng?}` → `[{name, locality, country, lat, lng, isCity}]`.
  static func search(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let query = args["query"] as? String,
      !query.trimmingCharacters(in: .whitespaces).isEmpty
    else {
      result([])
      return
    }
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.resultTypes = [.address, .pointOfInterest]
    if let lat = args["lat"] as? Double, let lng = args["lng"] as? Double {
      request.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
        latitudinalMeters: 200_000,
        longitudinalMeters: 200_000
      )
    }
    MKLocalSearch(request: request).start { response, _ in
      let items = (response?.mapItems ?? []).prefix(20).map { item -> [String: Any] in
        let mark = item.placemark
        // A town on its own: no street, no business — the result *is* the place.
        let isCity =
          item.pointOfInterestCategory == nil && mark.thoroughfare == nil
          && mark.locality != nil
          && (item.name == mark.locality || item.name == mark.administrativeArea)
        return [
          "name": item.name ?? mark.locality ?? "",
          "locality": mark.locality ?? mark.administrativeArea ?? "",
          "country": mark.country ?? "",
          "lat": mark.coordinate.latitude,
          "lng": mark.coordinate.longitude,
          "isCity": isCity,
        ]
      }
      DispatchQueue.main.async { result(Array(items)) }
    }
  }
}

// MARK: - Snapshots

enum MapSnapshots {
  /// `{pins, line, width, height, scale}` → a JPEG path under
  /// Caches/map_snapshots, named by a hash of the arguments: the same map
  /// is rendered once.
  static func snapshot(_ args: [String: Any], _ result: @escaping FlutterResult) {
    let width = args["width"] as? Double ?? 300
    let height = args["height"] as? Double ?? 160
    let pins = MapPin.list(args["pins"])
    let line = MapLine.from(args["line"])
    guard !pins.isEmpty else {
      result(nil)
      return
    }
    let key = cacheKey(args)
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("map_snapshots", isDirectory: true)
    let file = dir.appendingPathComponent("\(key).jpg")
    if FileManager.default.fileExists(atPath: file.path) {
      result(file.path)
      return
    }
    var rect = MKMapRect.null
    for p in pins {
      let m = MKMapPoint(p.coordinate)
      rect = rect.union(MKMapRect(x: m.x, y: m.y, width: 0, height: 0))
    }
    let pad = max(max(rect.size.width, rect.size.height) * 0.25, 6000)
    rect = rect.insetBy(dx: -pad, dy: -pad)
    let options = MKMapSnapshotter.Options()
    options.mapRect = rect
    options.size = CGSize(width: width, height: height)
    options.scale = args["scale"] as? Double ?? UIScreen.main.scale
    options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
    MKMapSnapshotter(options: options).start(with: .global(qos: .utility)) { snap, _ in
      guard let snap = snap else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      let image = UIGraphicsImageRenderer(size: options.size).image { ctx in
        snap.image.draw(at: .zero)
        let c = ctx.cgContext
        if let line = line {
          c.setStrokeColor(UIColor.systemTeal.cgColor)
          c.setLineWidth(2)
          for (i, coord) in line.points.enumerated() {
            let p = snap.point(for: coord)
            if i == 0 { c.move(to: p) } else { c.addLine(to: p) }
          }
          c.strokePath()
        }
        c.setFillColor(UIColor.systemTeal.cgColor)
        for pin in pins {
          let p = snap.point(for: pin.coordinate)
          c.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
        }
      }
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let ok = (try? image.jpegData(compressionQuality: 0.8)?.write(to: file)) != nil
      DispatchQueue.main.async { result(ok ? file.path : nil) }
    }
  }

  private static func cacheKey(_ args: [String: Any]) -> String {
    let data =
      (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
    return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}
