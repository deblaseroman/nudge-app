//
//  MascotAvatarView.swift
//  Nudge
//
//  Configurable-size mascot circle. Falls back to a coral "N" circle
//  if the mascot-default asset is not yet in the asset catalog.
//

import SwiftUI
import UIKit

struct MascotAvatarView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // Soft circle backdrop. Keeps the avatar shape consistent with
            // the rest of the chat UI even though the pigeon artwork itself
            // is transparent and not perfectly circular.
            Circle()
                .fill(NudgeTheme.primary.opacity(0.12))

            if UIImage(named: "mascot-default") != nil {
                // Fit (not fill) so the whole pigeon — including tail and
                // feet — stays inside the circle without getting clipped.
                Image("mascot-default")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.08)
            } else {
                Text("N")
                    .font(.custom(NudgeTheme.fontBrand, size: size * 0.45))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
