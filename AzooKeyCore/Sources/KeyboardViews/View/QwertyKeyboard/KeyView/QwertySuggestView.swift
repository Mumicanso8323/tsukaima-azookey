//
//  QwertySuggestView.swift
//  Keyboard
//
//  Created by ensan on 2020/09/18.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation
import SwiftUI
import SwiftUIUtils

enum VariationsViewDirection: Sendable, Equatable {
    case center, right, left

    var alignment: Alignment {
        switch self {
        case .center: return .center
        case .right: return .leading
        case .left: return .trailing
        }
    }

    var edge: Edge.Set {
        switch self {
        case .center: return []
        case .right: return .leading
        case .left: return .trailing
        }
    }

}

struct QwertySuggestView {
    @MainActor private static func expandedPath(rdw: CGFloat, ldw: CGFloat, keyWidth: CGFloat, tabDesign: TabDependentDesign) -> some Shape {
        let height = tabDesign.keyViewHeight * 2 + tabDesign.verticalSpacing
        // バリエーション上側の高さ
        let BC: CGFloat = tabDesign.keyViewHeight
        let _CD: CGSize = .init(width: tabDesign.verticalSpacing, height: tabDesign.verticalSpacing)
        let G_H = _CD
        // キーの幅
        let EF = keyWidth
        let width = ldw + _CD.width + keyWidth + G_H.width + rdw
        return Path { path in
            var points = [CGPoint]()
            points.append(contentsOf: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 0, y: BC),
            ])
            if ldw > 0 {
                points.append(CGPoint(x: ldw, y: BC))
            }
            points.append(contentsOf: [
                CGPoint(x: ldw + _CD.width, y: BC + _CD.height),
                CGPoint(x: ldw + _CD.width, y: height),
                CGPoint(x: ldw + _CD.width + EF, y: height),
                CGPoint(x: ldw + _CD.width + EF, y: BC + _CD.height),
                CGPoint(x: width - rdw, y: BC),
            ])
            if rdw > 0 {
                points.append(CGPoint(x: width, y: BC))
            }
            points.append(CGPoint(x: width, y: 0))
            path.addPoints(points, cornerRadius: 4)
        }
        .offsetBy(dx: -(ldw + _CD.width), dy: 0 )
    }

    @MainActor static func scaleToFrameSize(keyWidth: CGFloat, scale_y: CGFloat, color: some ShapeStyle, borderColor: some ShapeStyle, borderWidth: CGFloat, tabDesign: TabDependentDesign) -> some View {
        let height = (tabDesign.keyViewHeight * 2 + tabDesign.verticalSpacing) * scale_y
        return expandedPath(rdw: 0, ldw: 0, keyWidth: keyWidth, tabDesign: tabDesign)
            .strokeAndFill(fillContent: color, strokeContent: borderColor, lineWidth: borderWidth)
            .frame(width: keyWidth, height: height)
    }

    @MainActor static func scaleToVariationsSize(keyWidth: CGFloat, scale_y: CGFloat, variationsCount: Int, color: some ShapeStyle, borderColor: some ShapeStyle, borderWidth: CGFloat, direction: VariationsViewDirection, tabDesign: TabDependentDesign) -> some View {
        let keyViewSize = tabDesign.keyViewSize
        let height = (keyViewSize.height * 2 + tabDesign.verticalSpacing) * scale_y
        // dwはexpand時のoffsetにあたる。C_CとH_Hがそれぞれ増加分に対応。
        let dw = keyViewSize.width * CGFloat(variationsCount - 1) + tabDesign.horizontalSpacing * CGFloat(variationsCount - 1)
        switch direction {
        case .center:
            return expandedPath(rdw: dw / 2, ldw: dw / 2, keyWidth: keyWidth, tabDesign: tabDesign)
                .strokeAndFill(fillContent: color, strokeContent: borderColor, lineWidth: borderWidth)
                .frame(width: keyWidth, height: height)
        case .right:
            return expandedPath(rdw: dw, ldw: 0, keyWidth: keyWidth, tabDesign: tabDesign)
                .strokeAndFill(fillContent: color, strokeContent: borderColor, lineWidth: borderWidth)
                .frame(width: keyWidth, height: height)
        case .left:
            return expandedPath(rdw: 0, ldw: dw, keyWidth: keyWidth, tabDesign: tabDesign)
                .strokeAndFill(fillContent: color, strokeContent: borderColor, lineWidth: borderWidth)
                .frame(width: keyWidth, height: height)
        }
    }
}

// MARK: - Rounded Polyline helper
private extension Path {
    /// Adds a polyline (or polygon) through the given points, rounding each corner by the specified radius.
    /// - Parameters:
    ///   - points: Ordered list of vertices.
    ///   - cornerRadius: Desired corner radius (applied uniformly, clipped when edges are too short).
    mutating func addPoints(_ points: [CGPoint], cornerRadius: CGFloat) {
        let count = points.count
        guard count > 1 else { return }

        // Helper: unit vector from `a` toward `b`
        func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = hypot(dx, dy)
            guard len > 0 else { return .zero }
            return CGPoint(x: dx / len, y: dy / len)
        }

        // --- Step 1: determine effective radius at every vertex ---
        var effR = Array(repeating: cornerRadius, count: count)
        if cornerRadius > 0 {
            for i in 0 ..< count {
                let prev = points[(i - 1 + count) % count]
                let curr = points[i]
                let next = points[(i + 1) % count]

                let maxR = 0.5 * min(
                    hypot(prev.x - curr.x, prev.y - curr.y),
                    hypot(next.x - curr.x, next.y - curr.y)
                )
                effR[i] = min(cornerRadius, maxR)
            }
        }

        // --- Step 2: draw ---
        // Shift start point **along the incoming edge** so the first vertex also gets a rounded corner
        if cornerRadius > 0 {
            self.move(to: points[count - 1])
        } else {
            self.move(to: points[0])
        }
        for i in 0 ..< count {
            let curr = points[i]
            let next = points[(i + 1) % count]
            let r = effR[i]

            if r > 0 {
                self.addArc(tangent1End: curr, tangent2End: next, radius: r)
            } else {
                self.addLine(to: curr)
            }
        }
        self.closeSubpath()
    }
}
