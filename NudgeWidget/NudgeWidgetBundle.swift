//
//  NudgeWidgetBundle.swift
//  NudgeWidget
//
//  Created by Roman DeBlase on 3/30/26.
//

import WidgetKit
import SwiftUI

@main
struct NudgeWidgetBundle: WidgetBundle {
    var body: some Widget {
        NudgeTaskWidget()
        NudgeCompanionWidget()
        TaskLiveActivityView()
    }
}
