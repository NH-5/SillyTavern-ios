import Foundation

#if canImport(UIKit)
import UIKit
/// 当前平台的图像类型。
///
/// 业务层（`AppStore`）需要缓存头像图像，但同一份代码既要在 iOS 上跑，
/// 也要能在 macOS 上被命令行测试工具编译，因此用别名抹平差异。
typealias PlatformImage = UIImage

/// 平台无关的图像解码入口。
///
/// 两个平台的初始化器名字不同（`UIImage(data:)` 与 `NSImage(data:)`），
/// 用同一个函数包一层，业务代码就不必到处写条件编译。
func makePlatformImage(from data: Data) -> PlatformImage? {
    UIImage(data: data)
}

#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage

func makePlatformImage(from data: Data) -> PlatformImage? {
    NSImage(data: data)
}

#else
typealias PlatformImage = AnyObject

func makePlatformImage(from data: Data) -> PlatformImage? { nil }
#endif
