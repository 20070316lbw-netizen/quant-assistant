import AppKit
import SwiftUI

/// `swift run` 起的是个裸可执行文件，不是正经 .app bundle（没有 Info.plist），
/// macOS 不会自动把它当成前台 GUI App 对待：窗口画出来了、输入框光标也在闪，
/// 但窗口从来没真正成为 key window，键盘事件压根没路由过来——所以看起来能
/// 输入（光标在）实际上打字没反应。显式把 activation policy 设成 .regular、
/// 再 activate 一下、把窗口提到最前，就是让它表现得像一个正常前台 App。
/// 用 Xcode 打开 Package.swift 跑（而不是命令行 `swift run`）不会有这个问题，
/// 但既然现在就是命令行跑起来测试的，这里直接把兜底加上。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// activation policy 要在 SwiftUI 搭好菜单栏（标准的 Edit 菜单——里面的
    /// Cut/Copy/Paste 就是靠这个菜单的 key equivalent 才能响应 Cmd+C/Cmd+V，
    /// 不是靠裸的 keyDown）之前就设成 .regular，不然菜单栏可能是照
    /// .accessory/.prohibited 那套装配的，装完了再切策略也补不回来——这就是
    /// 复制粘贴失灵的根因，跟之前"窗口抢不到键盘焦点"是同一类"裸可执行文件
    /// 不是正经 .app bundle"的后遗症，只是发生在启动流程更早的一步。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        applyAppIcon()
    }

    /// 同样是"裸可执行文件不是正经 .app bundle"的后遗症：没有 Info.plist 里的
    /// CFBundleIconFile，系统不知道去哪儿找图标，Dock/Cmd+Tab 只会显示默认的
    /// 终端图标。资源目录里的 Assets.xcassets（Resources/Assets.xcassets）是给
    /// 以后真正打包成 .xcodeproj/.app 用的；这里额外在 Resources 里放了一份
    /// 扁平的 AppIcon.png，运行时直接读出来塞给 NSApp，让 Dock 图标看起来正常。
    private func applyAppIcon() {
        guard
            let url = Bundle.module.url(
                forResource: "AppIcon", withExtension: "png", subdirectory: "Resources"),
            let image = NSImage(contentsOf: url)
        else { return }
        NSApp.applicationIconImage = image
    }
}

@main
struct QuantAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
