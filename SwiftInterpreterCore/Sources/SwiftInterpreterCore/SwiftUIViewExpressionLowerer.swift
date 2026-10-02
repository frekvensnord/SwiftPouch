import Foundation
import SwiftParser
import SwiftSyntax

/// Errors reported while lowering the supported static SwiftUI expression subset.
public enum RuntimeViewLoweringError: Error, LocalizedError, Equatable, Sendable {
    case malformedSyntax
    case expectedSingleExpression
    case unsupportedExpression(String)
    case unsupportedView(String)
    case unsupportedModifier(String)
    case unsupportedArgument(String)
    case invalidLiteral(String)
    case missingViewBuilderClosure(String)

    public var errorDescription: String? {
        switch self {
        case .malformedSyntax:
            return "The Swift parser found malformed view-expression syntax."
        case .expectedSingleExpression:
            return "Provide exactly one SwiftUI view expression."
        case .unsupportedExpression(let expression):
            return "This expression is not supported by the view runtime yet: \(expression)"
        case .unsupportedView(let name):
            return "This SwiftUI view is not supported by the view runtime yet: \(name)"
        case .unsupportedModifier(let name):
            return "This SwiftUI view modifier is not supported by the view runtime yet: \(name)"
        case .unsupportedArgument(let name):
            return "The arguments supplied to '\(name)' are outside the supported subset."
        case .invalidLiteral(let name):
            return "The literal supplied to '\(name)' is outside the supported static subset."
        case .missingViewBuilderClosure(let name):
            return "The '\(name)' view requires a trailing view-builder closure."
        }
    }
}

/// Lowers a small SwiftUI expression subset to the portable runtime tree.
///
/// This slice supports `Text` and system `Image` views, static colors and
/// shapes, `VStack`, `HStack`, `Spacer`, `Divider`, and a bounded set of view
/// modifiers. The kernel can supply snapshot values for dynamic `Text`
/// arguments, Boolean conditions, simple `let` optional bindings, and Boolean
/// `.disabled` arguments. Button labels and closures are lowered to portable
/// action nodes; the kernel can retain their source and execute it on demand.
/// Other dynamic values and unsupported modifiers are rejected explicitly.
public struct SwiftUIViewExpressionLowerer: Sendable {
    private let resolvedDynamicStrings: [String: String]
    private let resolvedDynamicStringSites: [Int: String]
    private let resolvedDynamicConditions: [String: Bool]
    private let resolvedDynamicBooleans: [String: Bool]
    private let resolvedDynamicBooleanSites: [Int: Bool]
    private let actionRecorder: RuntimeActionRecorder?

    public init() {
        self.resolvedDynamicStrings = [:]
        self.resolvedDynamicStringSites = [:]
        self.resolvedDynamicConditions = [:]
        self.resolvedDynamicBooleans = [:]
        self.resolvedDynamicBooleanSites = [:]
        self.actionRecorder = nil
    }

    init(
        resolvedDynamicStrings: [String: String],
        resolvedDynamicConditions: [String: Bool] = [:],
        resolvedDynamicBooleans: [String: Bool] = [:],
        resolvedDynamicStringSites: [Int: String] = [:],
        resolvedDynamicBooleanSites: [Int: Bool] = [:],
        actionRecorder: RuntimeActionRecorder? = nil
    ) {
        self.resolvedDynamicStrings = resolvedDynamicStrings
        self.resolvedDynamicStringSites = resolvedDynamicStringSites
        self.resolvedDynamicConditions = resolvedDynamicConditions
        self.resolvedDynamicBooleans = resolvedDynamicBooleans
        self.resolvedDynamicBooleanSites = resolvedDynamicBooleanSites
        self.actionRecorder = actionRecorder
    }

    public func lower(_ source: String) throws -> RuntimeViewNode {
        let syntaxTree = try parseSyntaxTree(source)
        guard syntaxTree.statements.count == 1,
              let item = syntaxTree.statements.first?.item else {
            throw RuntimeViewLoweringError.expectedSingleExpression
        }
        if let expression = item.as(ExprSyntax.self) {
            return try lower(expression)
        }
        if let conditional = viewBuilderConditional(in: item) {
            return try lowerConditional(conditional)
        }
        throw RuntimeViewLoweringError.expectedSingleExpression
    }

    func lowerRecordingActions(_ source: String) throws -> LoweredRuntimeView {
        let recorder = RuntimeActionRecorder()
        let lowerer = SwiftUIViewExpressionLowerer(
            resolvedDynamicStrings: resolvedDynamicStrings,
            resolvedDynamicConditions: resolvedDynamicConditions,
            resolvedDynamicBooleans: resolvedDynamicBooleans,
            resolvedDynamicStringSites: resolvedDynamicStringSites,
            resolvedDynamicBooleanSites: resolvedDynamicBooleanSites,
            actionRecorder: recorder
        )
        let node = try lowerer.lower(source)
        return LoweredRuntimeView(node: node, actions: recorder.snapshot())
    }

    func dynamicStringExpressions(in source: String) throws -> [String] {
        Array(Set(try dynamicStringExpressionSites(in: source).map(\.expression))).sorted()
    }

    func dynamicStringExpressionSites(in source: String) throws -> [DynamicViewExpressionSite] {
        let syntaxTree = try parseSyntaxTree(source)
        let visitor = DynamicTextExpressionVisitor()
        visitor.walk(syntaxTree)
        return visitor.sites.sorted { $0.utf8Offset < $1.utf8Offset }
    }

    func dynamicBooleanConditions(in source: String) throws -> [String] {
        let syntaxTree = try parseSyntaxTree(source)
        let visitor = DynamicConditionExpressionVisitor()
        visitor.walk(syntaxTree)
        return visitor.expressions.sorted()
    }

    func dynamicBooleanModifierArguments(in source: String) throws -> [String] {
        Array(Set(try dynamicBooleanModifierArgumentSites(in: source).map(\.expression))).sorted()
    }

    func dynamicBooleanModifierArgumentSites(in source: String) throws -> [DynamicViewExpressionSite] {
        let syntaxTree = try parseSyntaxTree(source)
        let visitor = DynamicBooleanModifierExpressionVisitor()
        visitor.walk(syntaxTree)
        return visitor.sites.sorted { $0.utf8Offset < $1.utf8Offset }
    }

    private func parseSyntaxTree(_ source: String) throws -> SourceFileSyntax {
        let syntaxTree = Parser.parse(source: source)
        guard !syntaxTree.hasError else {
            throw RuntimeViewLoweringError.malformedSyntax
        }
        return syntaxTree
    }

    private func lower(_ expression: ExprSyntax) throws -> RuntimeViewNode {
        if let conditional = expression.as(IfExprSyntax.self) {
            return try lowerConditional(conditional)
        }

        if let memberAccess = expression.as(MemberAccessExprSyntax.self),
           memberAccess.base?.trimmedDescription == "Color",
           RuntimeColorStyle(rawValue: memberAccess.declName.baseName.text) != nil {
            return .color(try runtimeColorValue(expression))
        }

        if let call = expression.as(FunctionCallExprSyntax.self),
           let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.declName.baseName.text == "opacity" {
            return .color(try runtimeColorValue(expression))
        }

        guard let call = expression.as(FunctionCallExprSyntax.self) else {
            throw RuntimeViewLoweringError.unsupportedExpression(expression.trimmedDescription)
        }

        if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           let contentExpression = memberAccess.base {
            let content = try lower(contentExpression)
            return try lowerModifier(
                memberAccess.declName.baseName.text,
                call: call,
                content: content
            )
        }

        let name = call.calledExpression.trimmedDescription
        switch name {
        case "Text":
            return try lowerText(call)
        case "Button":
            return try lowerButton(call)
        case "Image":
            return try lowerImage(call)
        case "Color":
            return .color(try runtimeColorValue(expression))
        case "RoundedRectangle", "Rectangle", "Circle", "Capsule":
            return try lowerShape(name, call: call)
        case "VStack":
            return try lowerStack(call, isVertical: true)
        case "HStack":
            return try lowerStack(call, isVertical: false)
        case "Group":
            return try lowerGroup(call)
        case "EmptyView":
            guard call.arguments.isEmpty, hasNoTrailingClosures(call) else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            return .empty
        case "Spacer":
            return try lowerSpacer(call)
        case "Divider":
            guard call.arguments.isEmpty, hasNoTrailingClosures(call) else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            return .divider
        default:
            throw RuntimeViewLoweringError.unsupportedView(name)
        }
    }

    private func lowerText(_ call: FunctionCallExprSyntax) throws -> RuntimeViewNode {
        guard hasNoTrailingClosures(call),
              call.arguments.count == 1,
              let argument = call.arguments.first,
              argument.label == nil else {
            throw RuntimeViewLoweringError.unsupportedArgument("Text")
        }
        let sourceOffset = argument.expression.positionAfterSkippingLeadingTrivia.utf8Offset
        if let value = resolvedDynamicStringSites[sourceOffset]
            ?? resolvedDynamicStrings[argument.expression.trimmedDescription] {
            return .text(value)
        }
        return .text(try staticString(argument.expression, viewName: "Text"))
    }

    private func lowerButton(_ call: FunctionCallExprSyntax) throws -> RuntimeViewNode {
        var titleExpression: ExprSyntax?
        var actionArgument: ClosureExprSyntax?
        var labelArgument: ClosureExprSyntax?
        var role: RuntimeButtonRole?
        var sawRole = false

        for argument in call.arguments {
            guard let label = argument.label?.text else {
                guard case nil = titleExpression else {
                    throw RuntimeViewLoweringError.unsupportedArgument("Button")
                }
                titleExpression = argument.expression
                continue
            }

            switch label {
            case "role":
                guard !sawRole else {
                    throw RuntimeViewLoweringError.unsupportedArgument("Button")
                }
                sawRole = true
                role = try buttonRole(argument.expression)
            case "action":
                guard case nil = actionArgument,
                      let closure = argument.expression.as(ClosureExprSyntax.self) else {
                    throw RuntimeViewLoweringError.unsupportedArgument("Button action")
                }
                actionArgument = closure
            case "label":
                guard case nil = labelArgument,
                      let closure = argument.expression.as(ClosureExprSyntax.self) else {
                    throw RuntimeViewLoweringError.unsupportedArgument("Button label")
                }
                labelArgument = closure
            default:
                throw RuntimeViewLoweringError.unsupportedArgument("Button")
            }
        }

        let trailingClosures = Array(call.additionalTrailingClosures)
        let actionClosure: ClosureExprSyntax?
        let labelClosure: ClosureExprSyntax?

        if !trailingClosures.isEmpty {
            guard trailingClosures.count == 1,
                  trailingClosures[0].label.text == "label",
                  let trailingAction = call.trailingClosure,
                  case nil = actionArgument,
                  case nil = labelArgument,
                  case nil = titleExpression else {
                throw RuntimeViewLoweringError.unsupportedArgument("Button closures")
            }
            actionClosure = trailingAction
            labelClosure = trailingClosures[0].closure
        } else if let trailingClosure = call.trailingClosure {
            if let _ = titleExpression {
                guard case nil = actionArgument, case nil = labelArgument else {
                    throw RuntimeViewLoweringError.unsupportedArgument("Button closures")
                }
                actionClosure = trailingClosure
                labelClosure = nil
            } else if let actionArgument {
                guard case nil = labelArgument else {
                    throw RuntimeViewLoweringError.unsupportedArgument("Button closures")
                }
                actionClosure = actionArgument
                labelClosure = trailingClosure
            } else if let labelArgument {
                actionClosure = trailingClosure
                labelClosure = labelArgument
            } else {
                throw RuntimeViewLoweringError.unsupportedArgument("Button requires a label")
            }
        } else {
            actionClosure = actionArgument
            labelClosure = labelArgument
        }

        guard let actionClosure else {
            throw RuntimeViewLoweringError.unsupportedArgument("Button requires an action closure")
        }

        let label: RuntimeViewNode
        if let titleExpression {
            guard case nil = labelClosure else {
                throw RuntimeViewLoweringError.unsupportedArgument("Button label")
            }
            label = .text(try staticString(titleExpression, viewName: "Button"))
        } else if let labelClosure {
            label = try lowerViewBuilderStatements(labelClosure.statements)
        } else {
            throw RuntimeViewLoweringError.unsupportedArgument("Button requires a label")
        }

        let actionSource = actionClosure.statements.description
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actionID = actionRecorder?.record(actionSource) ?? RuntimeActionID()
        return .button(label: label, actionID: actionID, role: role)
    }

    private func buttonRole(_ expression: ExprSyntax) throws -> RuntimeButtonRole? {
        if expression.as(NilLiteralExprSyntax.self) != nil {
            return nil
        }
        guard let name = staticMemberName(expression),
              let role = RuntimeButtonRole(rawValue: name) else {
            throw RuntimeViewLoweringError.unsupportedArgument("Button role")
        }
        return role
    }

    private func lowerImage(_ call: FunctionCallExprSyntax) throws -> RuntimeViewNode {
        guard hasNoTrailingClosures(call),
              call.arguments.count == 1,
              let argument = call.arguments.first,
              argument.label?.text == "systemName" else {
            throw RuntimeViewLoweringError.unsupportedArgument("Image")
        }
        return .image(systemName: try staticString(argument.expression, viewName: "Image"))
    }

    private func lowerStack(
        _ call: FunctionCallExprSyntax,
        isVertical: Bool
    ) throws -> RuntimeViewNode {
        let name = isVertical ? "VStack" : "HStack"
        var seenLabels = Set<String>()
        for argument in call.arguments {
            guard let label = argument.label?.text,
                  (label == "alignment" || label == "spacing"),
                  seenLabels.insert(label).inserted else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
        }

        guard call.additionalTrailingClosures.isEmpty else {
            throw RuntimeViewLoweringError.unsupportedArgument(name)
        }
        guard let closure = call.trailingClosure else {
            throw RuntimeViewLoweringError.missingViewBuilderClosure(name)
        }

        let alignmentArgument = call.arguments.first { $0.label?.text == "alignment" }?.expression
        let spacingArgument = call.arguments.first { $0.label?.text == "spacing" }?.expression
        let children = try lowerViewBuilderStatements(closure.statements)
        let childNodes: [RuntimeViewNode]
        switch children {
        case .empty:
            childNodes = []
        case .group(let nodes):
            childNodes = nodes
        default:
            childNodes = [children]
        }

        if isVertical {
            let alignment = try horizontalAlignment(alignmentArgument, viewName: name)
            let spacing = try optionalNumber(spacingArgument, viewName: name)
            return .verticalStack(alignment: alignment, spacing: spacing, children: childNodes)
        } else {
            let alignment = try verticalAlignment(alignmentArgument, viewName: name)
            let spacing = try optionalNumber(spacingArgument, viewName: name)
            return .horizontalStack(alignment: alignment, spacing: spacing, children: childNodes)
        }
    }

    private func lowerConditional(_ conditional: IfExprSyntax) throws -> RuntimeViewNode {
        _ = try viewConditionalBindings(in: conditional.conditions)

        let condition: Bool
        if conditional.conditions.count == 1,
           let conditionElement = conditional.conditions.first,
           case .expression(let conditionExpression) = conditionElement.condition,
           let literalValue = staticBoolean(conditionExpression) {
            condition = literalValue
        } else if let resolvedValue = resolvedDynamicConditions[conditionKey(for: conditional)] {
            condition = resolvedValue
        } else {
            throw RuntimeViewLoweringError.unsupportedExpression(conditional.trimmedDescription)
        }

        // Lower both branches so an unsupported construct cannot hide in the
        // branch that happens to be inactive for this static condition.
        let trueBranch = try lowerViewBuilderStatements(conditional.body.statements)
        let falseBranch: RuntimeViewNode
        if let elseBody = conditional.elseBody {
            switch elseBody {
            case .codeBlock(let codeBlock):
                falseBranch = try lowerViewBuilderStatements(codeBlock.statements)
            case .ifExpr(let nestedConditional):
                falseBranch = try lowerConditional(nestedConditional)
            }
        } else {
            falseBranch = .empty
        }

        return condition ? trueBranch : falseBranch
    }

    private func conditionKey(for conditional: IfExprSyntax) -> String {
        if conditional.conditions.count == 1,
           let condition = conditional.conditions.first,
           case .expression(let expression) = condition.condition {
            return expression.trimmedDescription
        }
        return viewConditionalConditionSource(conditional.conditions)
    }

    private func lowerGroup(_ call: FunctionCallExprSyntax) throws -> RuntimeViewNode {
        guard call.arguments.isEmpty,
              call.additionalTrailingClosures.isEmpty,
              let closure = call.trailingClosure else {
            throw RuntimeViewLoweringError.unsupportedArgument("Group")
        }

        switch try lowerViewBuilderStatements(closure.statements) {
        case .empty:
            return .empty
        case .group(let children):
            if children.count == 1, let child = children.first {
                return child
            }
            return .group(children)
        case let child:
            return child
        }
    }

    private func lowerViewBuilderStatements(
        _ statements: CodeBlockItemListSyntax
    ) throws -> RuntimeViewNode {
        let children = try statements.map { item -> RuntimeViewNode in
            if let expression = item.item.as(ExprSyntax.self) {
                return try lower(expression)
            }
            if let conditional = viewBuilderConditional(in: item.item) {
                return try lowerConditional(conditional)
            }
            throw RuntimeViewLoweringError.unsupportedExpression(item.trimmedDescription)
        }

        switch children.count {
        case 0:
            return .empty
        case 1:
            return children[0]
        default:
            return .group(children)
        }
    }

    private func lowerSpacer(_ call: FunctionCallExprSyntax) throws -> RuntimeViewNode {
        guard hasNoTrailingClosures(call), call.arguments.count <= 1 else {
            throw RuntimeViewLoweringError.unsupportedArgument("Spacer")
        }
        if let argument = call.arguments.first, argument.label?.text != "minLength" {
            throw RuntimeViewLoweringError.unsupportedArgument("Spacer")
        }
        let expression = call.arguments.first?.expression
        return .spacer(minLength: try optionalNumber(expression, viewName: "Spacer"))
    }

    private func lowerModifier(
        _ name: String,
        call: FunctionCallExprSyntax,
        content: RuntimeViewNode
    ) throws -> RuntimeViewNode {
        if name == "overlay" {
            return try overlayModifier(call, content: content)
        }

        guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else {
            throw RuntimeViewLoweringError.unsupportedModifier(name)
        }

        let modifier: RuntimeViewModifier
        switch name {
        case "padding":
            modifier = try paddingModifier(call)
        case "frame":
            modifier = try frameModifier(call)
        case "foregroundStyle":
            guard call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            modifier = .foregroundStyle(try colorStyle(argument.expression))
        case "font":
            guard call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            modifier = .font(try staticFont(argument.expression))
        case "lineLimit":
            guard call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            modifier = .lineLimit(try lineLimit(argument.expression))
        case "multilineTextAlignment":
            guard call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil,
                  let value = staticMemberName(argument.expression),
                  let alignment = RuntimeHorizontalAlignment(rawValue: value) else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            modifier = .multilineTextAlignment(alignment)
        case "accessibilityLabel":
            guard call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            modifier = .accessibilityLabel(try staticString(argument.expression, viewName: name))
        case "disabled":
            guard call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            let value: Bool
            let sourceOffset = argument.expression.positionAfterSkippingLeadingTrivia.utf8Offset
            if let staticValue = staticBoolean(argument.expression) {
                value = staticValue
            } else if let resolvedValue = resolvedDynamicBooleanSites[sourceOffset] {
                value = resolvedValue
            } else if let resolvedValue = resolvedDynamicBooleans[argument.expression.trimmedDescription] {
                value = resolvedValue
            } else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            modifier = .disabled(value)
        case "background":
            modifier = try backgroundModifier(call)
        case "contentShape":
            guard call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil,
                  case .shape(let shape) = try lower(argument.expression) else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            modifier = .contentShape(shape)
        case "fill":
            guard case .shape(let shape) = content,
                  call.arguments.count == 1,
                  let colorArgument = call.arguments.first,
                  colorArgument.label == nil else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            return .filledShape(shape: shape, color: try runtimeColorValue(colorArgument.expression))
        case "stroke":
            guard case .shape(let shape) = content,
                  call.arguments.count == 2,
                  let colorArgument = call.arguments.first,
                  colorArgument.label == nil,
                  let widthArgument = call.arguments.last,
                  widthArgument.label?.text == "lineWidth",
                  let lineWidth = try nonnegativeNumber(widthArgument.expression, viewName: name) else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            return .strokedShape(
                shape: shape,
                color: try runtimeColorValue(colorArgument.expression),
                lineWidth: lineWidth
            )
        default:
            throw RuntimeViewLoweringError.unsupportedModifier(name)
        }

        return .modified(content: content, modifier: modifier)
    }

    private func overlayModifier(
        _ call: FunctionCallExprSyntax,
        content: RuntimeViewNode
    ) throws -> RuntimeViewNode {
        guard call.additionalTrailingClosures.isEmpty,
              call.arguments.count <= 1 else {
            throw RuntimeViewLoweringError.unsupportedArgument("overlay")
        }

        var alignment = RuntimeFrameAlignment.center
        if let argument = call.arguments.first {
            guard argument.label?.text == "alignment",
                  let alignmentName = staticMemberName(argument.expression),
                  let parsedAlignment = RuntimeFrameAlignment(rawValue: alignmentName) else {
                throw RuntimeViewLoweringError.unsupportedArgument("overlay")
            }
            alignment = parsedAlignment
        }

        guard let closure = call.trailingClosure else {
            throw RuntimeViewLoweringError.missingViewBuilderClosure("overlay")
        }
        let overlay = try lowerViewBuilderStatements(closure.statements)

        return .modified(
            content: content,
            modifier: .overlay(alignment: alignment, overlay: overlay)
        )
    }

    private func backgroundModifier(_ call: FunctionCallExprSyntax) throws -> RuntimeViewModifier {
        guard call.arguments.count == 1 || call.arguments.count == 2,
              let styleArgument = call.arguments.first,
              styleArgument.label == nil else {
            throw RuntimeViewLoweringError.unsupportedArgument("background")
        }

        let style = try runtimeBackgroundStyle(styleArgument.expression)
        let shape: RuntimeShape?
        if call.arguments.count == 2 {
            guard let shapeArgument = call.arguments.last,
                  shapeArgument.label?.text == "in",
                  case .shape(let parsedShape) = try lower(shapeArgument.expression) else {
                throw RuntimeViewLoweringError.unsupportedArgument("background")
            }
            shape = parsedShape
        } else {
            shape = nil
        }

        return .background(style: style, shape: shape)
    }

    private func lowerShape(_ name: String, call: FunctionCallExprSyntax) throws -> RuntimeViewNode {
        guard hasNoTrailingClosures(call) else {
            throw RuntimeViewLoweringError.unsupportedArgument(name)
        }

        switch name {
        case "Rectangle":
            guard call.arguments.isEmpty else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            return .shape(.rectangle)
        case "Circle":
            guard call.arguments.isEmpty else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            return .shape(.circle)
        case "Capsule":
            guard call.arguments.isEmpty else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            return .shape(.capsule)
        case "RoundedRectangle":
            var cornerRadius: Double?
            var style = RuntimeRoundedCornerStyle.circular
            var sawStyle = false
            for argument in call.arguments {
                switch argument.label?.text {
                case "cornerRadius":
                    guard cornerRadius == nil,
                          let value = try nonnegativeNumber(argument.expression, viewName: name) else {
                        throw RuntimeViewLoweringError.unsupportedArgument(name)
                    }
                    cornerRadius = value
                case "style":
                    guard !sawStyle,
                          let styleName = staticMemberName(argument.expression),
                          let parsedStyle = RuntimeRoundedCornerStyle(rawValue: styleName) else {
                        throw RuntimeViewLoweringError.unsupportedArgument(name)
                    }
                    style = parsedStyle
                    sawStyle = true
                default:
                    throw RuntimeViewLoweringError.unsupportedArgument(name)
                }
            }
            guard let cornerRadius else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
            return .shape(.roundedRectangle(cornerRadius: cornerRadius, style: style))
        default:
            throw RuntimeViewLoweringError.unsupportedView(name)
        }
    }

    private func paddingModifier(_ call: FunctionCallExprSyntax) throws -> RuntimeViewModifier {
        let name = "padding"
        guard call.arguments.allSatisfy({ $0.label == nil }),
              call.arguments.count <= 2 else {
            throw RuntimeViewLoweringError.unsupportedArgument(name)
        }

        guard let first = call.arguments.first?.expression else {
            return .padding(edges: .all, length: nil)
        }

        if call.arguments.count == 1 {
            if let edges = paddingEdges(first) {
                return .padding(edges: edges, length: nil)
            }
            return .padding(edges: .all, length: try optionalNumber(first, viewName: name))
        }

        guard let edges = paddingEdges(first),
              let length = call.arguments.last?.expression else {
            throw RuntimeViewLoweringError.unsupportedArgument(name)
        }
        return .padding(edges: edges, length: try optionalNumber(length, viewName: name))
    }

    private func frameModifier(_ call: FunctionCallExprSyntax) throws -> RuntimeViewModifier {
        let name = "frame"
        var labels = Set<String>()
        var width: Double?
        var height: Double?
        var maxWidth: RuntimeFrameDimension?
        var maxHeight: RuntimeFrameDimension?
        var alignment = RuntimeFrameAlignment.center

        for argument in call.arguments {
            guard let label = argument.label?.text,
                  ["width", "height", "maxWidth", "maxHeight", "alignment"].contains(label),
                  labels.insert(label).inserted else {
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }

            switch label {
            case "width":
                width = try nonnegativeNumber(argument.expression, viewName: name)
            case "height":
                height = try nonnegativeNumber(argument.expression, viewName: name)
            case "maxWidth":
                maxWidth = try frameDimension(argument.expression, viewName: name)
            case "maxHeight":
                maxHeight = try frameDimension(argument.expression, viewName: name)
            case "alignment":
                guard let value = staticMemberName(argument.expression),
                      let parsed = RuntimeFrameAlignment(rawValue: value) else {
                    throw RuntimeViewLoweringError.unsupportedArgument(name)
                }
                alignment = parsed
            default:
                throw RuntimeViewLoweringError.unsupportedArgument(name)
            }
        }

        guard !call.arguments.isEmpty,
              (width == nil && height == nil) || (maxWidth == nil && maxHeight == nil) else {
            throw RuntimeViewLoweringError.unsupportedArgument(name)
        }
        return .frame(
            width: width,
            height: height,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            alignment: alignment
        )
    }

    private func staticString(_ expression: ExprSyntax, viewName: String) throws -> String {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else {
            throw RuntimeViewLoweringError.invalidLiteral(viewName)
        }

        let token = literal.trimmedDescription
        guard token.hasPrefix("\""), token.hasSuffix("\""),
              !token.hasPrefix("\"\"\""), !token.hasSuffix("\"\"\"") else {
            throw RuntimeViewLoweringError.invalidLiteral(viewName)
        }

        let contents = token.dropFirst().dropLast()
        guard !contents.contains("\\") else {
            throw RuntimeViewLoweringError.invalidLiteral(viewName)
        }
        return String(contents)
    }

    private func horizontalAlignment(
        _ expression: ExprSyntax?,
        viewName: String
    ) throws -> RuntimeHorizontalAlignment {
        guard let expression else { return .center }
        guard let name = alignmentName(expression) else {
            throw RuntimeViewLoweringError.unsupportedArgument(viewName)
        }
        guard let alignment = RuntimeHorizontalAlignment(rawValue: name) else {
            throw RuntimeViewLoweringError.unsupportedArgument(viewName)
        }
        return alignment
    }

    private func verticalAlignment(
        _ expression: ExprSyntax?,
        viewName: String
    ) throws -> RuntimeVerticalAlignment {
        guard let expression else { return .center }
        guard let name = alignmentName(expression) else {
            throw RuntimeViewLoweringError.unsupportedArgument(viewName)
        }
        guard let alignment = RuntimeVerticalAlignment(rawValue: name) else {
            throw RuntimeViewLoweringError.unsupportedArgument(viewName)
        }
        return alignment
    }

    private func alignmentName(_ expression: ExprSyntax) -> String? {
        staticMemberName(expression)
    }

    private func staticMemberName(_ expression: ExprSyntax) -> String? {
        guard let memberAccess = expression.as(MemberAccessExprSyntax.self),
              memberAccess.base == nil else {
            return nil
        }
        return memberAccess.declName.baseName.text
    }

    private func paddingEdges(_ expression: ExprSyntax) -> RuntimePaddingEdges? {
        guard let name = staticMemberName(expression) else { return nil }
        return RuntimePaddingEdges(rawValue: name)
    }

    private func frameDimension(
        _ expression: ExprSyntax,
        viewName: String
    ) throws -> RuntimeFrameDimension? {
        if staticMemberName(expression) == "infinity" {
            return .infinity
        }
        guard let value = try nonnegativeNumber(expression, viewName: viewName) else {
            return nil
        }
        return .value(value)
    }

    private func colorStyle(_ expression: ExprSyntax) throws -> RuntimeColorStyle {
        let value = try runtimeColorValue(expression)
        guard value.opacity == 1 else {
            throw RuntimeViewLoweringError.invalidLiteral("foregroundStyle")
        }
        return value.style
    }

    private func runtimeColorValue(_ expression: ExprSyntax) throws -> RuntimeColorValue {
        if let call = expression.as(FunctionCallExprSyntax.self),
           let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.declName.baseName.text == "opacity",
           let base = memberAccess.base {
            guard hasNoTrailingClosures(call),
                  call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil,
                  let opacity = Double(argument.expression.trimmedDescription),
                  opacity.isFinite,
                  (0...1).contains(opacity) else {
                throw RuntimeViewLoweringError.invalidLiteral("Color.opacity")
            }
            let baseColor = try runtimeColorValue(base)
            return RuntimeColorValue(style: baseColor.style, opacity: baseColor.opacity * opacity)
        }

        if let call = expression.as(FunctionCallExprSyntax.self),
           call.calledExpression.trimmedDescription == "Color" {
            guard hasNoTrailingClosures(call),
                  call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label?.text == "uiColor",
                  staticMemberName(argument.expression) == "systemBackground" else {
                throw RuntimeViewLoweringError.invalidLiteral("Color")
            }
            return RuntimeColorValue(style: .systemBackground)
        }

        let styleName: String?
        if let name = staticMemberName(expression) {
            styleName = name
        } else if let memberAccess = expression.as(MemberAccessExprSyntax.self),
                  memberAccess.base?.trimmedDescription == "Color" {
            styleName = memberAccess.declName.baseName.text
        } else {
            styleName = nil
        }

        if let styleName, let style = RuntimeColorStyle(rawValue: styleName) {
            return RuntimeColorValue(style: style)
        }
        throw RuntimeViewLoweringError.invalidLiteral("Color")
    }

    private func runtimeBackgroundStyle(_ expression: ExprSyntax) throws -> RuntimeBackgroundStyle {
        if let name = staticMemberName(expression),
           let material = RuntimeMaterialStyle(rawValue: name) {
            return .material(material)
        }
        return .color(try runtimeColorValue(expression))
    }

    private func staticFont(_ expression: ExprSyntax) throws -> RuntimeFont {
        if let name = staticMemberName(expression),
           let style = RuntimeTextStyle(rawValue: name) {
            return RuntimeFont(size: .textStyle(style))
        }

        guard let call = expression.as(FunctionCallExprSyntax.self),
              call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty else {
            throw RuntimeViewLoweringError.invalidLiteral("font")
        }

        if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.declName.baseName.text == "weight",
           let base = memberAccess.base,
           call.arguments.count == 1,
           call.arguments.first?.label == nil,
           let weightName = call.arguments.first.flatMap({ staticMemberName($0.expression) }),
           let weight = RuntimeFontWeight(rawValue: weightName) {
            let baseFont = try staticFont(base)
            return RuntimeFont(size: baseFont.size, weight: weight, design: baseFont.design)
        }

        let calledExpression = call.calledExpression
        let isSystemFont = staticMemberName(calledExpression) == "system"
            || calledExpression.trimmedDescription == "Font.system"
        guard isSystemFont else {
            throw RuntimeViewLoweringError.invalidLiteral("font")
        }

        var size: RuntimeFontSize?
        var weight: RuntimeFontWeight?
        var design = RuntimeFontDesign.default
        var seenLabels = Set<String>()

        for argument in call.arguments {
            let label = argument.label?.text ?? ""
            guard ["", "size", "weight", "design"].contains(label),
                  seenLabels.insert(label).inserted else {
                throw RuntimeViewLoweringError.invalidLiteral("font")
            }

            switch label {
            case "":
                guard size == nil,
                      let styleName = staticMemberName(argument.expression),
                      let style = RuntimeTextStyle(rawValue: styleName) else {
                    throw RuntimeViewLoweringError.invalidLiteral("font")
                }
                size = .textStyle(style)
            case "size":
                guard size == nil,
                      let points = try nonnegativeNumber(argument.expression, viewName: "font"),
                      points > 0 else {
                    throw RuntimeViewLoweringError.invalidLiteral("font")
                }
                size = .points(points)
            case "weight":
                guard let weightName = staticMemberName(argument.expression),
                      let parsedWeight = RuntimeFontWeight(rawValue: weightName) else {
                    throw RuntimeViewLoweringError.invalidLiteral("font")
                }
                weight = parsedWeight
            case "design":
                guard let designName = staticMemberName(argument.expression),
                      let parsedDesign = RuntimeFontDesign(rawValue: designName) else {
                    throw RuntimeViewLoweringError.invalidLiteral("font")
                }
                design = parsedDesign
            default:
                throw RuntimeViewLoweringError.invalidLiteral("font")
            }
        }

        guard let size else {
            throw RuntimeViewLoweringError.invalidLiteral("font")
        }
        return RuntimeFont(size: size, weight: weight, design: design)
    }

    private func lineLimit(_ expression: ExprSyntax) throws -> RuntimeLineLimit {
        let token = expression.trimmedDescription
        if let value = Int(token), value >= 0 {
            return .fixed(value)
        }

        let rangeBounds = token.components(separatedBy: "...")
        if rangeBounds.count == 2,
           let minimum = Int(rangeBounds[0].trimmingCharacters(in: .whitespacesAndNewlines)),
           let maximum = Int(rangeBounds[1].trimmingCharacters(in: .whitespacesAndNewlines)),
           minimum >= 0,
           maximum >= minimum {
            return .range(minimum: minimum, maximum: maximum)
        }

        throw RuntimeViewLoweringError.unsupportedArgument("lineLimit")
    }

    private func staticBoolean(_ expression: ExprSyntax) -> Bool? {
        guard let literal = expression.as(BooleanLiteralExprSyntax.self) else { return nil }
        return literal.literal.text == "true"
    }

    private func optionalNumber(_ expression: ExprSyntax?, viewName: String) throws -> Double? {
        guard let expression else { return nil }
        let token = expression.trimmedDescription
        if token == "nil" { return nil }
        guard let value = Double(token), value.isFinite else {
            throw RuntimeViewLoweringError.unsupportedArgument(viewName)
        }
        return value
    }

    private func nonnegativeNumber(_ expression: ExprSyntax, viewName: String) throws -> Double? {
        guard let value = try optionalNumber(expression, viewName: viewName) else { return nil }
        guard value >= 0 else {
            throw RuntimeViewLoweringError.unsupportedArgument(viewName)
        }
        return value
    }

    private func hasNoTrailingClosures(_ call: FunctionCallExprSyntax) -> Bool {
        call.trailingClosure == nil && call.additionalTrailingClosures.isEmpty
    }
}

private final class DynamicTextExpressionVisitor: SyntaxVisitor {
    private(set) var sites: [DynamicViewExpressionSite] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if isInsideButtonActionClosure(node) {
            return .skipChildren
        }
        guard node.calledExpression.trimmedDescription == "Text",
              node.arguments.count == 1,
              let argument = node.arguments.first,
              argument.label == nil,
              node.trailingClosure == nil,
              node.additionalTrailingClosures.isEmpty,
              !isPlainStringLiteral(argument.expression) else {
            return .visitChildren
        }

        sites.append(
            DynamicViewExpressionSite(
                expression: argument.expression.trimmedDescription,
                utf8Offset: argument.expression.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        )
        return .visitChildren
    }

    private func isPlainStringLiteral(_ expression: ExprSyntax) -> Bool {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else { return false }
        let token = literal.trimmedDescription
        guard token.hasPrefix("\""), token.hasSuffix("\""),
              !token.hasPrefix("\"\"\""), !token.hasSuffix("\"\"\"") else {
            return false
        }
        return !token.dropFirst().dropLast().contains("\\")
    }
}

private final class DynamicConditionExpressionVisitor: SyntaxVisitor {
    private(set) var expressions: Set<String> = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        if isInsideButtonActionClosure(node) {
            return .skipChildren
        }
        if node.conditions.count == 1,
           let condition = node.conditions.first,
           case .expression(let expression) = condition.condition {
            if expression.as(BooleanLiteralExprSyntax.self) == nil {
                expressions.insert(expression.trimmedDescription)
            }
        } else {
            expressions.insert(viewConditionalConditionSource(node.conditions))
        }
        return .visitChildren
    }
}

private final class DynamicBooleanModifierExpressionVisitor: SyntaxVisitor {
    private(set) var sites: [DynamicViewExpressionSite] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if isInsideButtonActionClosure(node) {
            return .skipChildren
        }
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
              memberAccess.declName.baseName.text == "disabled",
              node.arguments.count == 1,
              let argument = node.arguments.first,
              argument.label == nil,
              node.trailingClosure == nil,
              node.additionalTrailingClosures.isEmpty,
              argument.expression.as(BooleanLiteralExprSyntax.self) == nil else {
            return .visitChildren
        }

        sites.append(
            DynamicViewExpressionSite(
                expression: argument.expression.trimmedDescription,
                utf8Offset: argument.expression.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        )
        return .visitChildren
    }
}

struct DynamicViewExpressionSite: Sendable, Hashable {
    let expression: String
    let utf8Offset: Int
}

struct LoweredRuntimeView: Sendable {
    let node: RuntimeViewNode
    let actions: [RuntimeActionID: String]
}

final class RuntimeActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [RuntimeActionID: String] = [:]

    func record(_ source: String) -> RuntimeActionID {
        lock.lock()
        defer { lock.unlock() }

        let id = RuntimeActionID()
        actions[id] = source
        return id
    }

    func snapshot() -> [RuntimeActionID: String] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }
}

func isInsideButtonActionClosure(_ node: some SyntaxProtocol) -> Bool {
    let nodeStart = node.positionAfterSkippingLeadingTrivia.utf8Offset
    let nodeEnd = node.endPositionBeforeTrailingTrivia.utf8Offset
    var ancestor = node.parent

    while let current = ancestor {
        if let call = current.as(FunctionCallExprSyntax.self),
           call.calledExpression.trimmedDescription == "Button",
           let action = buttonActionClosure(in: call) {
            let actionStart = action.positionAfterSkippingLeadingTrivia.utf8Offset
            let actionEnd = action.endPositionBeforeTrailingTrivia.utf8Offset
            if nodeStart >= actionStart && nodeEnd <= actionEnd {
                return true
            }
        }
        ancestor = current.parent
    }

    return false
}

private func buttonActionClosure(in call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
    let actionArgument = call.arguments.first { $0.label?.text == "action" }?
        .expression.as(ClosureExprSyntax.self)
    let hasPositionalTitle = call.arguments.contains { $0.label == nil }
    let hasAdditionalLabelClosure = call.additionalTrailingClosures.contains { $0.label.text == "label" }

    if let trailingClosure = call.trailingClosure {
        if hasAdditionalLabelClosure || hasPositionalTitle {
            return trailingClosure
        }
        if let actionArgument {
            return actionArgument
        }
        if call.arguments.contains(where: { $0.label?.text == "label" }) {
            return trailingClosure
        }
        return trailingClosure
    }
    return actionArgument
}
