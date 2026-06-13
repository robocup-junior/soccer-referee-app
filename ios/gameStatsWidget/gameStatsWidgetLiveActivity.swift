//
//  gameStatsWidgetLiveActivity.swift
//  gameStatsWidget
//
//  Created by Fabian Weller on 13.06.2026.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct gameStatsWidgetAttributes: ActivityAttributes, Identifiable {
  public typealias LiveDeliveryData = ContentState // don't forget to add this line, otherwise, live activity will not display it.

  public struct ContentState: Codable, Hashable { }

  var id = UUID()
}

// Create shared default with custom group
let sharedDefault = UserDefaults(suiteName: "group.com.robocup.rcjScoreboard")!

struct gameStatsWidgetLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: gameStatsWidgetAttributes.self) { context in
      // create your live activity widget extension here
      // to access Flutter properties:
        let teamAName = sharedDefault.string(forKey: context.attributes.prefixedKey("team_a_name"))!
        let teamAScore = sharedDefault.string(forKey: context.attributes.prefixedKey("team_a_score"))!
        let teamBName = sharedDefault.string(forKey: context.attributes.prefixedKey("team_b_name"))!
        let teamBScore = sharedDefault.string(forKey: context.attributes.prefixedKey("team_b_score"))!
        let timeLeft = sharedDefault.string(forKey: context.attributes.prefixedKey("timeLeft"))!
        let matchStage = sharedDefault.string(forKey: context.attributes.prefixedKey("match_stage"))!
        /*
         'team_a_name': 'Team A',
        'team_a_score': '0',
        'team_b_name': 'Team B',
        'team_b_score': '0',
        'time_left': '10:00',
        'game_stage': 'first_half',
         */

        VStack {
                Text("\(teamAName) \(teamAScore)")
                Text("\(teamBName) \(teamBScore)")
                Text(timeLeft)
                Text(matchStage)
            }
    } dynamicIsland: { context in
        DynamicIsland {
            DynamicIslandExpandedRegion(.center) {
                Text("Live Match")
            }
        } compactLeading: {
            Text("A")
        } compactTrailing: {
            Text("1-0")
        } minimal: {
            Text("⚽")
        }
    }
  }
}

extension gameStatsWidgetAttributes {
  func prefixedKey(_ key: String) -> String {
    return "\(id)_\(key)"
  }
}

/*
#Preview("Notification", as: .content, using: gameStatsWidgetAttributes.preview) {
   gameStatsWidgetLiveActivity()
} contentStates: {
    gameStatsWidgetAttributes.ContentState.smiley
    gameStatsWidgetAttributes.ContentState.starEyes
}
*/
