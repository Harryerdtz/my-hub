// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WidgetDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WidgetDesk", targets: ["WidgetDesk"])],
    targets: [.executableTarget(name: "WidgetDesk")]
)
