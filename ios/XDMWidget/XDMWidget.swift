import WidgetKit
import SwiftUI

// This file previously contained duplicate TimelineProvider and Entry models.
// All logic has been consolidated into XDMWidgetModels.swift and
// XDMTimelineProvider.swift. This file is kept for backward compatibility
// but contains no additional definitions.
//
// If you have any references to XDMWidgetEntry with the old 6-field
// initializer, update them to use the full XDMWidgetEntry from
// XDMWidgetModels.swift instead.
