import Foundation
import XCTest
@testable import SwiftInterpreterCore

final class RuntimeViewTests: XCTestCase {
    func testViewTreeRoundTripsThroughCodable() throws {
        let actionID = RuntimeActionID()
        let tree = RuntimeViewNode.verticalStack(
            alignment: .leading,
            spacing: 12,
            children: [
                .modified(
                    content: .text("Hallo"),
                    modifier: .background(
                        style: .color(RuntimeColorValue(style: .secondary, opacity: 0.08)),
                        shape: .roundedRectangle(cornerRadius: 12, style: .circular)
                    )
                ),
                .modified(
                    content: .text("Composer"),
                    modifier: .overlay(alignment: .center, overlay: .shape(.circle))
                ),
                .group([.text("First"), .text("Second")]),
                .forEach([
                    RuntimeForEachItem(
                        id: RuntimeForEachID(rawValue: "6:String4:chat"),
                        content: .text("Identified row")
                    )
                ]),
                .horizontalStack(
                    alignment: .center,
                    spacing: 6,
                    children: [
                        .image(systemName: "paperplane.fill"),
                        .button(label: .text("Senden"), actionID: actionID, role: nil)
                    ]
                ),
                .divider
            ]
        )

        let encoded = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(RuntimeViewNode.self, from: encoded)

        XCTAssertEqual(decoded, tree)
    }

    func testActionIdentityIsStableAndDistinct() {
        let firstID = RuntimeActionID()
        let sameID = RuntimeActionID(firstID.rawValue)
        let otherID = RuntimeActionID()

        XCTAssertEqual(firstID, sameID)
        XCTAssertNotEqual(firstID, otherID)
    }

    func testLowererBuildsNestedStaticViews() throws {
        let lowerer = SwiftUIViewExpressionLowerer()
        let source = """
        VStack(alignment: .leading, spacing: 8) {
            Text("Hello")
            HStack {
                Image(systemName: "bubble.left")
                Text("world")
            }
            Spacer(minLength: 4)
            Divider()
        }
        """

        let node = try lowerer.lower(source)

        XCTAssertEqual(node, .verticalStack(
            alignment: .leading,
            spacing: 8,
            children: [
                .text("Hello"),
                .horizontalStack(
                    alignment: .center,
                    spacing: nil,
                    children: [
                        .image(systemName: "bubble.left"),
                        .text("world")
                    ]
                ),
                .spacer(minLength: 4),
                .divider
            ]
        ))
    }

    func testLowererRejectsDynamicTextAndUnsupportedViews() throws {
        let lowerer = SwiftUIViewExpressionLowerer()

        XCTAssertThrowsError(try lowerer.lower("Text(title)")) { error in
            XCTAssertEqual(error as? RuntimeViewLoweringError, .invalidLiteral("Text"))
        }
        XCTAssertThrowsError(try lowerer.lower("Menu { Text(\"Run\") }")) { error in
            XCTAssertEqual(error as? RuntimeViewLoweringError, .unsupportedView("Menu"))
        }
    }

    func testLowererSupportsTitleAndViewBuilderButtons() throws {
        let lowerer = SwiftUIViewExpressionLowerer()

        let titleButton = try lowerer.lower("Button(\"Save\", role: .cancel) {}")
        guard case .button(let title, _, let titleRole) = titleButton else {
            return XCTFail("Expected a lowered Button node")
        }
        XCTAssertEqual(title, .text("Save"))
        XCTAssertEqual(titleRole, .cancel)

        let viewBuilderButton = try lowerer.lower(
            "Button { print(\"tap\") } label: { Text(\"Run\") }"
        )
        guard case .button(let customLabel, _, let customRole) = viewBuilderButton else {
            return XCTFail("Expected a lowered Button node")
        }
        XCTAssertEqual(customLabel, .text("Run"))
        XCTAssertNil(customRole)

        let actionArgumentButton = try lowerer.lower(
            "Button(action: { print(\"tap\") }) { Text(\"Again\") }"
        )
        guard case .button(let actionArgumentLabel, _, _) = actionArgumentButton else {
            return XCTFail("Expected a lowered Button node")
        }
        XCTAssertEqual(actionArgumentLabel, .text("Again"))
    }

    func testLowererSupportsDefaultPaddingAndRejectsInvalidStackArguments() throws {
        let lowerer = SwiftUIViewExpressionLowerer()

        XCTAssertEqual(
            try lowerer.lower("Text(\"Hello\").padding()"),
            .modified(content: .text("Hello"), modifier: .padding(edges: .all, length: nil))
        )
        XCTAssertThrowsError(try lowerer.lower("VStack(spacing: 4, spacing: 8) { Text(\"x\") }")) { error in
            XCTAssertEqual(error as? RuntimeViewLoweringError, .unsupportedArgument("VStack"))
        }
        XCTAssertThrowsError(try lowerer.lower("VStack(alignment: layout.leading) { Text(\"x\") }")) { error in
            XCTAssertEqual(error as? RuntimeViewLoweringError, .unsupportedArgument("VStack"))
        }
        XCTAssertThrowsError(try lowerer.lower("Text(\"x\") { EmptyView() }")) { error in
            XCTAssertEqual(error as? RuntimeViewLoweringError, .unsupportedArgument("Text"))
        }
    }

    func testLowererPreservesStaticModifierOrderAndValues() throws {
        let lowerer = SwiftUIViewExpressionLowerer()
        let source = "Text(\"Start\").font(.title3.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1...3).multilineTextAlignment(.center).accessibilityLabel(\"Greeting\").disabled(false)"

        let actual = try lowerer.lower(source)
        let text = RuntimeViewNode.text("Start")
        let font = RuntimeViewNode.modified(
            content: text,
            modifier: .font(RuntimeFont(size: .textStyle(.title3), weight: .semibold))
        )
        let foreground = RuntimeViewNode.modified(content: font, modifier: .foregroundStyle(.secondary))
        let padding = RuntimeViewNode.modified(
            content: foreground,
            modifier: .padding(edges: .horizontal, length: 12)
        )
        let frame = RuntimeViewNode.modified(
            content: padding,
            modifier: .frame(
                width: nil,
                height: nil,
                maxWidth: .infinity,
                maxHeight: nil,
                alignment: .leading
            )
        )
        let lineLimit = RuntimeViewNode.modified(
            content: frame,
            modifier: .lineLimit(.range(minimum: 1, maximum: 3))
        )
        let textAlignment = RuntimeViewNode.modified(
            content: lineLimit,
            modifier: .multilineTextAlignment(.center)
        )
        let label = RuntimeViewNode.modified(
            content: textAlignment,
            modifier: .accessibilityLabel("Greeting")
        )
        let expected = RuntimeViewNode.modified(content: label, modifier: .disabled(false))

        XCTAssertEqual(actual, expected)
    }

    func testLowererSupportsSystemFontAndStaticColorInitializer() throws {
        let lowerer = SwiftUIViewExpressionLowerer()
        let node = try lowerer.lower(
            "Image(systemName: \"sparkle\").font(.system(size: 34, weight: .medium)).foregroundStyle(Color(uiColor: .systemBackground)).frame(width: 26, height: 26)"
        )

        XCTAssertEqual(node, .modified(
            content: .modified(
                content: .modified(
                    content: .image(systemName: "sparkle"),
                    modifier: .font(RuntimeFont(size: .points(34), weight: .medium))
                ),
                modifier: .foregroundStyle(.systemBackground)
            ),
            modifier: .frame(
                width: 26,
                height: 26,
                maxWidth: nil,
                maxHeight: nil,
                alignment: .center
            )
        ))

        let designFont = try lowerer.lower(
            "Text(\"Code\").font(.system(.title2, design: .monospaced).weight(.bold))"
        )
        XCTAssertEqual(designFont, .modified(
            content: .text("Code"),
            modifier: .font(RuntimeFont(
                size: .textStyle(.title2),
                weight: .bold,
                design: .monospaced
            ))
        ))
    }

    func testLowererSupportsStaticColorsAndBackgroundStyles() throws {
        let lowerer = SwiftUIViewExpressionLowerer()

        XCTAssertEqual(
            try lowerer.lower("Color.clear.frame(height: 1)"),
            .modified(
                content: .color(RuntimeColorValue(style: .clear)),
                modifier: .frame(
                    width: nil,
                    height: 1,
                    maxWidth: nil,
                    maxHeight: nil,
                    alignment: .center
                )
            )
        )

        XCTAssertEqual(
            try lowerer.lower("Text(\"Message\").background(Color.secondary.opacity(0.08))"),
            .modified(
                content: .text("Message"),
                modifier: .background(
                    style: .color(RuntimeColorValue(style: .secondary, opacity: 0.08)),
                    shape: nil
                )
            )
        )

        XCTAssertEqual(
            try lowerer.lower("Text(\"Send\").background(Color.primary, in: Circle())"),
            .modified(
                content: .text("Send"),
                modifier: .background(
                    style: .color(RuntimeColorValue(style: .primary)),
                    shape: .circle
                )
            )
        )

        XCTAssertEqual(
            try lowerer.lower("Text(\"Composer\").background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))"),
            .modified(
                content: .text("Composer"),
                modifier: .background(
                    style: .material(.thin),
                    shape: .roundedRectangle(cornerRadius: 26, style: .continuous)
                )
            )
        )
    }

    func testLowererSupportsFilledAndStrokedStaticShapes() throws {
        let lowerer = SwiftUIViewExpressionLowerer()
        let rounded = RuntimeShape.roundedRectangle(cornerRadius: 18, style: .continuous)

        XCTAssertEqual(
            try lowerer.lower("RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.secondary.opacity(0.12))"),
            .filledShape(
                shape: rounded,
                color: RuntimeColorValue(style: .secondary, opacity: 0.12)
            )
        )
        XCTAssertEqual(
            try lowerer.lower("RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.secondary.opacity(0.12), lineWidth: 1)"),
            .strokedShape(
                shape: .roundedRectangle(cornerRadius: 26, style: .continuous),
                color: RuntimeColorValue(style: .secondary, opacity: 0.12),
                lineWidth: 1
            )
        )
    }

    func testLowererSupportsStaticOverlayAndContentShape() throws {
        let lowerer = SwiftUIViewExpressionLowerer()
        let overlay = try lowerer.lower(
            "Text(\"Composer\").overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.secondary.opacity(0.12), lineWidth: 1) }"
        )
        XCTAssertEqual(overlay, .modified(
            content: .text("Composer"),
            modifier: .overlay(
                alignment: .center,
                overlay: .strokedShape(
                    shape: .roundedRectangle(cornerRadius: 26, style: .continuous),
                    color: RuntimeColorValue(style: .secondary, opacity: 0.12),
                    lineWidth: 1
                )
            )
        ))

        XCTAssertEqual(
            try lowerer.lower("Image(systemName: \"plus\").contentShape(Rectangle())"),
            .modified(
                content: .image(systemName: "plus"),
                modifier: .contentShape(.rectangle)
            )
        )
        XCTAssertEqual(
            try lowerer.lower("Text(\"base\").overlay(alignment: .leading) { Text(\"loading\") }"),
            .modified(
                content: .text("base"),
                modifier: .overlay(alignment: .leading, overlay: .text("loading"))
            )
        )
    }

    func testLowererSelectsLiteralConditionalViewBranches() throws {
        let lowerer = SwiftUIViewExpressionLowerer()

        XCTAssertEqual(
            try lowerer.lower("VStack { if true { Text(\"shown\") } else { Text(\"hidden\") } }"),
            .verticalStack(alignment: .center, spacing: nil, children: [.text("shown")])
        )
        XCTAssertEqual(
            try lowerer.lower("HStack { if false { Text(\"hidden\") } else if false { Text(\"also hidden\") } else { Text(\"shown\") } }"),
            .horizontalStack(alignment: .center, spacing: nil, children: [.text("shown")])
        )
        XCTAssertEqual(
            try lowerer.lower("Text(\"base\").overlay { if false { Text(\"hidden\") } }"),
            .modified(
                content: .text("base"),
                modifier: .overlay(alignment: .center, overlay: .empty)
            )
        )
        XCTAssertThrowsError(
            try lowerer.lower("if true { Text(\"shown\") } else { Menu { Text(\"unsupported\") } }")
        ) { error in
            XCTAssertEqual(error as? RuntimeViewLoweringError, .unsupportedView("Menu"))
        }
    }

    func testLowererSupportsGroupAndEmptyViewNodes() throws {
        let lowerer = SwiftUIViewExpressionLowerer()

        XCTAssertEqual(
            try lowerer.lower("Group { Text(\"first\"); Text(\"second\") }"),
            .group([.text("first"), .text("second")])
        )
        XCTAssertEqual(try lowerer.lower("EmptyView()"), .empty)
    }

    func testLowererBuildsIdentifiedRowsFromKernelMarkers() throws {
        let lowerer = SwiftUIViewExpressionLowerer()
        let node = try lowerer.lower(#"__SwiftPouchForEachGroup { __SwiftPouchForEachItem(id: "6:String4:chat") { Text("Chat") }; __SwiftPouchForEachItem(id: "6:String4:help") { Text("Help") } }"#)

        XCTAssertEqual(node, .forEach([
            RuntimeForEachItem(
                id: RuntimeForEachID(rawValue: "6:String4:chat"),
                content: .text("Chat")
            ),
            RuntimeForEachItem(
                id: RuntimeForEachID(rawValue: "6:String4:help"),
                content: .text("Help")
            )
        ]))
    }

    func testLowererPreservesMultipleConditionalAndOverlayChildrenAsAGroup() throws {
        let lowerer = SwiftUIViewExpressionLowerer()

        XCTAssertEqual(
            try lowerer.lower("Text(\"base\").overlay { if true { Text(\"first\"); Text(\"second\") } }"),
            .modified(
                content: .text("base"),
                modifier: .overlay(
                    alignment: .center,
                    overlay: .group([.text("first"), .text("second")])
                )
            )
        )
        XCTAssertEqual(
            try lowerer.lower("VStack { if false { Text(\"one\"); Text(\"two\") } else { Text(\"three\"); Text(\"four\") } }"),
            .verticalStack(
                alignment: .center,
                spacing: nil,
                children: [.group([.text("three"), .text("four")])]
            )
        )
    }

    func testLowererRejectsDynamicModifierArgumentsAndUnknownModifiers() throws {
        let lowerer = SwiftUIViewExpressionLowerer()

        XCTAssertThrowsError(try lowerer.lower("Text(\"x\").padding(isCompact ? 4 : 8)"))
        XCTAssertThrowsError(try lowerer.lower("Text(\"x\").disabled(isSending)"))
        XCTAssertThrowsError(try lowerer.lower("Text(\"x\").background(isSelected ? Color.red : Color.blue)"))
        XCTAssertThrowsError(try lowerer.lower("Text(\"x\").background { RoundedRectangle(cornerRadius: 8) }"))
        XCTAssertThrowsError(try lowerer.lower("Text(\"x\").contentShape(shape)"))
        XCTAssertThrowsError(try lowerer.lower("Text(\"x\").overlay(alignment: .leading) { if isLoading { Text(\"wait\") } }"))
        XCTAssertEqual(
            try lowerer.lower("Text(\"x\").overlay { Text(\"one\"); Text(\"two\") }"),
            .modified(
                content: .text("x"),
                modifier: .overlay(
                    alignment: .center,
                    overlay: .group([.text("one"), .text("two")])
                )
            )
        )
        XCTAssertThrowsError(try lowerer.lower("Text(\"x\").sheet(isPresented: true) { Text(\"Sheet\") }")) { error in
            XCTAssertEqual(error as? RuntimeViewLoweringError, .unsupportedModifier("sheet"))
        }
    }
}
