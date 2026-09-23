//
//  YuE2MacApp.swift
//  YuE2Mac — local AI songwriting on Apple Silicon.
//

import SwiftUI

@main
struct YuE2MacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandMenu("Playback") {
                Button("Play / Pause") { PlayerCenter.active?.toggle() }
                    .keyboardShortcut(.space, modifiers: .option)
                Button("Back 10 Seconds") { PlayerCenter.active?.skip(-10) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button("Forward 10 Seconds") { PlayerCenter.active?.skip(10) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                Button("Back to Start") { PlayerCenter.active?.seek(to: 0) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
                Divider()
                Button("Loop On / Off") { PlayerCenter.active?.loop.toggle() }
                    .keyboardShortcut("l", modifiers: .option)
                Button("Mute / Unmute") { PlayerCenter.active?.muted.toggle() }
                    .keyboardShortcut("m", modifiers: .option)
            }
        }
    }
}