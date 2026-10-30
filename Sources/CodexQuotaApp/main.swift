import AppKit
import CodexQuotaCore
import Darwin
import Foundation
import SwiftUI

if CommandLine.arguments.contains("--print-dashboard") {
    do {
        let dashboard = try SheetsDashboardClient.fetchOnce()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(dashboard)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-dashboard-preview"),
   CommandLine.arguments.indices.contains(previewIndex + 1) {
    do {
        let output = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1])
        try MainActor.assumeIsolated {
            _ = NSApplication.shared
            let model = DashboardViewModel()
            let client = SheetsDashboardClient()
            defer { client.stop() }
            if let cache = client.cached() {
                model.dashboard = cache.0
                model.fetchedAt = cache.1
            }
            let view = NSHostingView(rootView: DashboardView(model: model))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: output, options: .atomic)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("预览失败：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-icon-preview"),
   CommandLine.arguments.indices.contains(previewIndex + 1) {
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1])
    let percent = CommandLine.arguments.indices.contains(previewIndex + 2)
        ? Double(CommandLine.arguments[previewIndex + 2]) ?? 28
        : 28
    do {
        guard let data = MainActor.assumeIsolated({
            QuotaRingIcon.previewPNG(remainingPercent: percent)
        }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: outputURL, options: .atomic)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("无法生成图标预览：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--print-quota") {
    let locator = CodexLocator()
    guard let executableURL = locator.resolveExecutable() else {
        FileHandle.standardError.write(Data("未找到 Codex 程序。\n".utf8))
        exit(2)
    }

    do {
        let snapshot = try CodexAppServerClient.fetchOnce(executableURL: executableURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(snapshot)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    application.run()
}
