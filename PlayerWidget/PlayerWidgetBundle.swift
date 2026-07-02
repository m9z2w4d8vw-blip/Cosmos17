//
//  PlayerWidgetBundle.swift
//  PlayerWidget
//
//  Created by CLQ on 07/12/2025.
//

import WidgetKit
import SwiftUI

// MARK: - iOS 17 compatibility helper
// widgetAccentedRenderingMode(_:) only exists on Image, and only on iOS 18.0+.
// This wrapper applies it when available and falls back to plain rendering on iOS 17.
extension Image {
    @ViewBuilder
    func fullColorWidgetRendering() -> some View {
        if #available(iOS 18.0, *) {
            self.widgetAccentedRenderingMode(.fullColor)
        } else {
            self
        }
    }
}

@main
struct PlayerWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlayerWidget()
        PlaylistWidget()
        // PlayerWidgetControl() - Control Center widget (iOS 18+)
        // PlayerWidgetLiveActivity() - Live Activity / Dynamic Island
    }
}