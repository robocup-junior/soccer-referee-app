//
//  gameStatsWidgetBundle.swift
//  gameStatsWidget
//
//  Created by Fabian Weller on 13.06.2026.
//

import WidgetKit
import SwiftUI

@main
struct gameStatsWidgetBundle: WidgetBundle {
    var body: some Widget {
        gameStatsWidget()
        gameStatsWidgetControl()
        gameStatsWidgetLiveActivity()
    }
}
