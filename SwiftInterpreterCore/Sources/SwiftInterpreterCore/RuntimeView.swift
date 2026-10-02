import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Stable action identity carried by a rendered button node.
public struct RuntimeActionID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// The host app's current scene lifecycle state, exposed to interpreted views.
public enum RuntimeScenePhase: String, Codable, Hashable, Sendable {
    case active
    case inactive
    case background
}

public enum RuntimeActionError: Error, LocalizedError, Equatable, Sendable {
    case unknownAction(RuntimeActionID)

    public var errorDescription: String? {
        switch self {
        case .unknownAction(let actionID):
            return "No interpreted button action is registered for \(actionID.rawValue.uuidString)."
        }
    }
}

public enum RuntimeHorizontalAlignment: String, Codable, Hashable, Sendable {
    case leading
    case center
    case trailing
}

public enum RuntimeVerticalAlignment: String, Codable, Hashable, Sendable {
    case top
    case center
    case bottom
    case firstTextBaseline
    case lastTextBaseline
}

public enum RuntimeButtonRole: String, Codable, Hashable, Sendable {
    case cancel
    case destructive
}

public enum RuntimePaddingEdges: String, Codable, Hashable, Sendable {
    case all
    case horizontal
    case vertical
    case top
    case leading
    case bottom
    case trailing
}

public enum RuntimeFrameAlignment: String, Codable, Hashable, Sendable {
    case center
    case top
    case bottom
    case leading
    case trailing
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

public enum RuntimeFrameDimension: Codable, Equatable, Sendable {
    case value(Double)
    case infinity
}

public enum RuntimeColorStyle: String, Codable, Hashable, Sendable {
    case clear
    case primary
    case secondary
    case red
    case green
    case blue
    case orange
    case yellow
    case gray
    case white
    case black
    case tint
    case systemBackground
}

public struct RuntimeColorValue: Codable, Equatable, Sendable {
    public let style: RuntimeColorStyle
    public let opacity: Double

    public init(style: RuntimeColorStyle, opacity: Double = 1) {
        self.style = style
        self.opacity = opacity
    }
}

public enum RuntimeMaterialStyle: String, Codable, Hashable, Sendable {
    case ultraThin
    case thin
    case regular
    case thick
    case ultraThick
}

public enum RuntimeBackgroundStyle: Codable, Equatable, Sendable {
    case color(RuntimeColorValue)
    case material(RuntimeMaterialStyle)
}

public enum RuntimeRoundedCornerStyle: String, Codable, Hashable, Sendable {
    case circular
    case continuous
}

public enum RuntimeShape: Codable, Equatable, Sendable {
    case rectangle
    case circle
    case capsule
    case roundedRectangle(cornerRadius: Double, style: RuntimeRoundedCornerStyle)
}

public enum RuntimeTextStyle: String, Codable, Hashable, Sendable {
    case largeTitle
    case title
    case title2
    case title3
    case headline
    case subheadline
    case body
    case callout
    case footnote
    case caption
    case caption2
}

public enum RuntimeFontWeight: String, Codable, Hashable, Sendable {
    case ultraLight
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black
}

public enum RuntimeFontDesign: String, Codable, Hashable, Sendable {
    case `default`
    case rounded
    case serif
    case monospaced
}

public enum RuntimeFontSize: Codable, Equatable, Sendable {
    case textStyle(RuntimeTextStyle)
    case points(Double)
}

public struct RuntimeFont: Codable, Equatable, Sendable {
    public let size: RuntimeFontSize
    public let weight: RuntimeFontWeight?
    public let design: RuntimeFontDesign

    public init(
        size: RuntimeFontSize,
        weight: RuntimeFontWeight? = nil,
        design: RuntimeFontDesign = .default
    ) {
        self.size = size
        self.weight = weight
        self.design = design
    }
}

public enum RuntimeLineLimit: Codable, Equatable, Sendable {
    case fixed(Int)
    case range(minimum: Int, maximum: Int)
}

public enum RuntimeViewModifier: Codable, Equatable, Sendable {
    case padding(edges: RuntimePaddingEdges, length: Double?)
    case frame(
        width: Double?,
        height: Double?,
        maxWidth: RuntimeFrameDimension?,
        maxHeight: RuntimeFrameDimension?,
        alignment: RuntimeFrameAlignment
    )
    case foregroundStyle(RuntimeColorStyle)
    case font(RuntimeFont)
    case lineLimit(RuntimeLineLimit)
    case multilineTextAlignment(RuntimeHorizontalAlignment)
    case accessibilityLabel(String)
    case disabled(Bool)
    case background(style: RuntimeBackgroundStyle, shape: RuntimeShape?)
    case overlay(alignment: RuntimeFrameAlignment, overlay: RuntimeViewNode)
    case contentShape(RuntimeShape)
}

/// A renderer-independent tree that interpreted view declarations can produce.
///
/// The tree contains only serializable display data. Button behavior is carried
/// separately as an action ID so the host can route taps back to the interpreter
/// without storing interpreter closures in the view model.
public indirect enum RuntimeViewNode: Codable, Equatable, Sendable {
    case empty
    case text(String)
    case image(systemName: String)
    case color(RuntimeColorValue)
    case shape(RuntimeShape)
    case filledShape(shape: RuntimeShape, color: RuntimeColorValue)
    case strokedShape(shape: RuntimeShape, color: RuntimeColorValue, lineWidth: Double)
    case modified(content: RuntimeViewNode, modifier: RuntimeViewModifier)
    case group([RuntimeViewNode])
    case verticalStack(
        alignment: RuntimeHorizontalAlignment,
        spacing: Double?,
        children: [RuntimeViewNode]
    )
    case horizontalStack(
        alignment: RuntimeVerticalAlignment,
        spacing: Double?,
        children: [RuntimeViewNode]
    )
    case button(
        label: RuntimeViewNode,
        actionID: RuntimeActionID,
        role: RuntimeButtonRole?
    )
    case spacer(minLength: Double?)
    case divider
}

#if canImport(SwiftUI)
/// Converts portable runtime view nodes into native SwiftUI.
@available(iOS 16.0, macOS 13.0, *)
@MainActor
public struct SwiftUIRuntimeRenderer: View {
    private let node: RuntimeViewNode
    private let onAction: @MainActor (RuntimeActionID) -> Void
    private let onActionWithDismissal: (@MainActor @Sendable (RuntimeActionID) async -> Bool)?

    @Environment(\.dismiss) private var hostDismissAction

    public init(
        node: RuntimeViewNode,
        onAction: @escaping @MainActor (RuntimeActionID) -> Void = { _ in }
    ) {
        self.node = node
        self.onAction = onAction
        self.onActionWithDismissal = nil
    }

    /// Renders actions that may request dismissal of the native presentation
    /// containing this renderer. The dismissal action is read from this view's
    /// SwiftUI environment so a renderer placed inside a sheet receives that
    /// sheet's own host context.
    public init(
        node: RuntimeViewNode,
        onActionWithDismissal: @escaping @MainActor @Sendable (RuntimeActionID) async -> Bool
    ) {
        self.node = node
        self.onAction = { _ in }
        self.onActionWithDismissal = onActionWithDismissal
    }

    @ViewBuilder
    public var body: some View {
        render(node)
    }

    private func render(_ node: RuntimeViewNode) -> AnyView {
        AnyView(renderContent(node))
    }

    @ViewBuilder
    private func renderContent(_ node: RuntimeViewNode) -> some View {
        switch node {
        case .empty:
            EmptyView()
        case .text(let value):
            Text(value)
        case .image(let systemName):
            Image(systemName: systemName)
        case .color(let value):
            color(value.style).opacity(value.opacity)
        case .shape(let shape):
            renderShape(shape)
        case .filledShape(let shape, let colorValue):
            renderFilledShape(shape, colorValue: colorValue)
        case .strokedShape(let shape, let colorValue, let lineWidth):
            renderStrokedShape(shape, colorValue: colorValue, lineWidth: lineWidth)
        case .modified(let content, let modifier):
            renderModified(content, modifier: modifier)
        case .group(let children):
            Group {
                ForEach(children.indices, id: \.self) { index in
                    render(children[index])
                }
            }
        case .verticalStack(let alignment, let spacing, let children):
            VStack(alignment: horizontalAlignment(alignment), spacing: spacing.map { CGFloat($0) }) {
                ForEach(children.indices, id: \.self) { index in
                    render(children[index])
                }
            }
        case .horizontalStack(let alignment, let spacing, let children):
            HStack(alignment: verticalAlignment(alignment), spacing: spacing.map { CGFloat($0) }) {
                ForEach(children.indices, id: \.self) { index in
                    render(children[index])
                }
            }
        case .button(let label, let actionID, let role):
            if let role {
                Button(role: buttonRole(role)) {
                    dispatchAction(actionID)
                } label: {
                    render(label)
                }
            } else {
                Button {
                    dispatchAction(actionID)
                } label: {
                    render(label)
                }
            }
        case .spacer(let minLength):
            Spacer(minLength: minLength.map { CGFloat($0) })
        case .divider:
            Divider()
        }
    }

    private func dispatchAction(_ actionID: RuntimeActionID) {
        guard let onActionWithDismissal else {
            onAction(actionID)
            return
        }

        let dismissAction = hostDismissAction
        Task { @MainActor in
            if await onActionWithDismissal(actionID) {
                dismissAction()
            }
        }
    }

    @ViewBuilder
    private func renderModified(
        _ content: RuntimeViewNode,
        modifier: RuntimeViewModifier
    ) -> some View {
        switch modifier {
        case .padding(let edges, let length):
            render(content).padding(edgeSet(edges), length.map { CGFloat($0) })
        case .frame(let width, let height, let maxWidth, let maxHeight, let alignment):
            if width != nil || height != nil {
                render(content).frame(
                    width: width.map { CGFloat($0) },
                    height: height.map { CGFloat($0) },
                    alignment: frameAlignment(alignment)
                )
            } else {
                render(content).frame(
                    minWidth: nil,
                    idealWidth: nil,
                    maxWidth: maxWidth.map(frameDimension),
                    minHeight: nil,
                    idealHeight: nil,
                    maxHeight: maxHeight.map(frameDimension),
                    alignment: frameAlignment(alignment)
                )
            }
        case .foregroundStyle(let style):
            render(content).foregroundStyle(color(style))
        case .font(let font):
            render(content).font(swiftUIFont(font))
        case .lineLimit(.fixed(let count)):
            render(content).lineLimit(count)
        case .lineLimit(.range(let minimum, let maximum)):
            render(content).lineLimit(minimum...maximum)
        case .multilineTextAlignment(let alignment):
            render(content).multilineTextAlignment(textAlignment(alignment))
        case .accessibilityLabel(let label):
            render(content).accessibilityLabel(label)
        case .disabled(let isDisabled):
            render(content).disabled(isDisabled)
        case .background(let style, let shape):
            renderBackground(content, style: style, shape: shape)
        case .overlay(let alignment, let overlay):
            render(content).overlay(alignment: frameAlignment(alignment)) {
                render(overlay)
            }
        case .contentShape(let shape):
            renderContentShape(content, shape: shape)
        }
    }

    @ViewBuilder
    private func renderContentShape(_ content: RuntimeViewNode, shape: RuntimeShape) -> some View {
        switch shape {
        case .rectangle:
            render(content).contentShape(Rectangle())
        case .circle:
            render(content).contentShape(Circle())
        case .capsule:
            render(content).contentShape(Capsule())
        case .roundedRectangle(let cornerRadius, let style):
            render(content).contentShape(
                RoundedRectangle(cornerRadius: CGFloat(cornerRadius), style: roundedCornerStyle(style))
            )
        }
    }

    @ViewBuilder
    private func renderShape(_ shape: RuntimeShape) -> some View {
        switch shape {
        case .rectangle:
            Rectangle()
        case .circle:
            Circle()
        case .capsule:
            Capsule()
        case .roundedRectangle(let cornerRadius, let style):
            RoundedRectangle(cornerRadius: CGFloat(cornerRadius), style: roundedCornerStyle(style))
        }
    }

    @ViewBuilder
    private func renderFilledShape(_ shape: RuntimeShape, colorValue: RuntimeColorValue) -> some View {
        switch shape {
        case .rectangle:
            filled(Rectangle(), colorValue: colorValue)
        case .circle:
            filled(Circle(), colorValue: colorValue)
        case .capsule:
            filled(Capsule(), colorValue: colorValue)
        case .roundedRectangle(let cornerRadius, let style):
            filled(
                RoundedRectangle(cornerRadius: CGFloat(cornerRadius), style: roundedCornerStyle(style)),
                colorValue: colorValue
            )
        }
    }

    private func filled<S: Shape>(_ shape: S, colorValue: RuntimeColorValue) -> some View {
        shape.fill(color(colorValue.style).opacity(colorValue.opacity))
    }

    @ViewBuilder
    private func renderStrokedShape(
        _ shape: RuntimeShape,
        colorValue: RuntimeColorValue,
        lineWidth: Double
    ) -> some View {
        switch shape {
        case .rectangle:
            stroked(Rectangle(), colorValue: colorValue, lineWidth: lineWidth)
        case .circle:
            stroked(Circle(), colorValue: colorValue, lineWidth: lineWidth)
        case .capsule:
            stroked(Capsule(), colorValue: colorValue, lineWidth: lineWidth)
        case .roundedRectangle(let cornerRadius, let style):
            stroked(
                RoundedRectangle(cornerRadius: CGFloat(cornerRadius), style: roundedCornerStyle(style)),
                colorValue: colorValue,
                lineWidth: lineWidth
            )
        }
    }

    private func stroked<S: Shape>(
        _ shape: S,
        colorValue: RuntimeColorValue,
        lineWidth: Double
    ) -> some View {
        shape.stroke(color(colorValue.style).opacity(colorValue.opacity), lineWidth: CGFloat(lineWidth))
    }

    @ViewBuilder
    private func renderBackground(
        _ content: RuntimeViewNode,
        style: RuntimeBackgroundStyle,
        shape: RuntimeShape?
    ) -> some View {
        switch shape {
        case nil:
            switch style {
            case .color(let value):
                render(content).background(color(value.style).opacity(value.opacity))
            case .material(let material):
                render(content).background(swiftUIMaterial(material))
            }
        case .some(.rectangle):
            background(content, style: style, in: Rectangle())
        case .some(.circle):
            background(content, style: style, in: Circle())
        case .some(.capsule):
            background(content, style: style, in: Capsule())
        case .some(.roundedRectangle(let cornerRadius, let cornerStyle)):
            background(
                content,
                style: style,
                in: RoundedRectangle(cornerRadius: CGFloat(cornerRadius), style: roundedCornerStyle(cornerStyle))
            )
        }
    }

    @ViewBuilder
    private func background<S: Shape>(
        _ content: RuntimeViewNode,
        style: RuntimeBackgroundStyle,
        in shape: S
    ) -> some View {
        switch style {
        case .color(let value):
            render(content).background(color(value.style).opacity(value.opacity), in: shape)
        case .material(let material):
            render(content).background(swiftUIMaterial(material), in: shape)
        }
    }

    private func roundedCornerStyle(_ style: RuntimeRoundedCornerStyle) -> RoundedCornerStyle {
        switch style {
        case .circular: .circular
        case .continuous: .continuous
        }
    }

    private func swiftUIMaterial(_ style: RuntimeMaterialStyle) -> Material {
        switch style {
        case .ultraThin: .ultraThin
        case .thin: .thin
        case .regular: .regular
        case .thick: .thick
        case .ultraThick: .ultraThick
        }
    }

    private func edgeSet(_ edges: RuntimePaddingEdges) -> Edge.Set {
        switch edges {
        case .all: .all
        case .horizontal: .horizontal
        case .vertical: .vertical
        case .top: .top
        case .leading: .leading
        case .bottom: .bottom
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ alignment: RuntimeFrameAlignment) -> Alignment {
        switch alignment {
        case .center: .center
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    private func frameDimension(_ dimension: RuntimeFrameDimension) -> CGFloat {
        switch dimension {
        case .value(let value): CGFloat(value)
        case .infinity: .infinity
        }
    }

    private func textAlignment(_ alignment: RuntimeHorizontalAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func color(_ style: RuntimeColorStyle) -> Color {
        switch style {
        case .clear: .clear
        case .primary: .primary
        case .secondary: .secondary
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .orange: .orange
        case .yellow: .yellow
        case .gray: .gray
        case .white: .white
        case .black: .black
        case .tint: .accentColor
        case .systemBackground:
            #if canImport(UIKit)
            Color(uiColor: .systemBackground)
            #elseif canImport(AppKit)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color.primary
            #endif
        }
    }

    private func swiftUIFont(_ font: RuntimeFont) -> Font {
        let design = fontDesign(font.design)
        let weight = font.weight.map(fontWeight)
        switch font.size {
        case .textStyle(let style):
            return .system(textStyle(style), design: design, weight: weight)
        case .points(let size):
            return .system(size: CGFloat(size), weight: weight ?? .regular, design: design)
        }
    }

    private func textStyle(_ style: RuntimeTextStyle) -> Font.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        }
    }

    private func fontWeight(_ weight: RuntimeFontWeight) -> Font.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }

    private func fontDesign(_ design: RuntimeFontDesign) -> Font.Design {
        switch design {
        case .default: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }

    private func horizontalAlignment(_ alignment: RuntimeHorizontalAlignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func verticalAlignment(_ alignment: RuntimeVerticalAlignment) -> VerticalAlignment {
        switch alignment {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        case .firstTextBaseline: .firstTextBaseline
        case .lastTextBaseline: .lastTextBaseline
        }
    }

    private func buttonRole(_ role: RuntimeButtonRole) -> ButtonRole {
        switch role {
        case .cancel: .cancel
        case .destructive: .destructive
        }
    }
}
#endif
