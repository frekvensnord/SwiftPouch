import Foundation
import SwiftParser
import SwiftSyntax

struct ViewScrollReaderContext: Sendable {
    let readerID: String
    let proxyName: String
}

/// Keeps the interpreted proxy lexical to its reader. Scroll requests are
/// recorded in the interpreter and delivered to the matching native reader.
enum ViewScrollSourceEditor {
    static func context(for call: FunctionCallExprSyntax) throws -> ViewScrollReaderContext {
        guard call.calledExpression.trimmedDescription == "ScrollViewReader",
              call.arguments.isEmpty,
              call.additionalTrailingClosures.isEmpty,
              let closure = call.trailingClosure,
              let signature = closure.signature?.trimmedDescription,
              signature.hasSuffix(" in") else {
            throw RuntimeViewLoweringError.unsupportedArgument("ScrollViewReader")
        }
        let name = String(signature.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first),
              name.unicodeScalars.dropFirst().allSatisfy({
                  $0 == "_" || CharacterSet.alphanumerics.contains($0)
              }) else {
            throw RuntimeViewLoweringError.unsupportedArgument(
                "ScrollViewReader requires one named proxy parameter"
            )
        }
        return ViewScrollReaderContext(
            readerID: "reader:\(call.positionAfterSkippingLeadingTrivia.utf8Offset)",
            proxyName: name
        )
    }

    static func context(enclosing node: some SyntaxProtocol) throws -> ViewScrollReaderContext? {
        var ancestor = node.parent
        while let current = ancestor {
            if let call = current.as(FunctionCallExprSyntax.self),
               call.calledExpression.trimmedDescription == "ScrollViewReader" {
                return try context(for: call)
            }
            ancestor = current.parent
        }
        return nil
    }

    static func rewriteAction(_ source: String, context: ViewScrollReaderContext?) throws -> String {
        let source = try unwrapViewAnimation(source)
        let tree = Parser.parse(source: source)
        guard !tree.hasError else { throw RuntimeViewLoweringError.malformedSyntax }
        guard let context else { return source }

        let visitor = ScrollCallVisitor(proxyName: context.proxyName)
        visitor.walk(tree)
        var bytes = Array(source.utf8)
        for call in visitor.calls.reversed() {
            guard call.trailingClosure == nil,
                  call.additionalTrailingClosures.isEmpty,
                  call.arguments.count == 1 || call.arguments.count == 2,
                  let target = call.arguments.first,
                  target.label == nil else {
                throw RuntimeViewLoweringError.unsupportedArgument("ScrollViewProxy.scrollTo")
            }
            let anchor: String
            if call.arguments.count == 2 {
                guard let argument = call.arguments.last,
                      argument.label?.text == "anchor",
                      let member = argument.expression.as(MemberAccessExprSyntax.self),
                      member.base == nil,
                      RuntimeScrollAnchor(rawValue: member.declName.baseName.text) != nil else {
                    throw RuntimeViewLoweringError.unsupportedArgument("ScrollViewProxy.scrollTo anchor")
                }
                anchor = member.declName.baseName.text
            } else {
                anchor = ""
            }
            let replacement = """
            ({ __swiftpouch_scroll_target = \(target.expression.trimmedDescription); \
            __swiftpouch_scroll_reader = \(String(reflecting: context.readerID)); \
            __swiftpouch_scroll_anchor = \(String(reflecting: anchor)); \
            __swiftpouch_scroll_requested = true })()
            """
            let range = call.positionAfterSkippingLeadingTrivia.utf8Offset..<call.endPositionBeforeTrailingTrivia.utf8Offset
            bytes.replaceSubrange(range, with: replacement.utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// SwiftUI's animation wrapper is a host display instruction. Run the
    /// enclosed interpreted state/scroll action without evaluating that host
    /// function as user code.
    private static func unwrapViewAnimation(_ source: String) throws -> String {
        var result = source
        for _ in 0..<64 {
            let tree = Parser.parse(source: result)
            guard !tree.hasError else { throw RuntimeViewLoweringError.malformedSyntax }
            let visitor = AnimationCallVisitor()
            visitor.walk(tree)
            guard let call = visitor.call else { return result }
            guard call.arguments.count <= 1, call.additionalTrailingClosures.isEmpty,
                  let closure = call.trailingClosure, closure.signature == nil else {
                throw RuntimeViewLoweringError.unsupportedArgument("withAnimation")
            }
            let range = call.positionAfterSkippingLeadingTrivia.utf8Offset..<call.endPositionBeforeTrailingTrivia.utf8Offset
            var bytes = Array(result.utf8)
            bytes.replaceSubrange(range, with: closure.statements.description.utf8)
            result = String(decoding: bytes, as: UTF8.self)
        }
        throw RuntimeViewLoweringError.unsupportedArgument("withAnimation nesting")
    }
}

private final class AnimationCallVisitor: SyntaxVisitor {
    private(set) var call: FunctionCallExprSyntax?
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if call == nil, node.calledExpression.trimmedDescription == "withAnimation" {
            call = node
            return .skipChildren
        }
        return .visitChildren
    }
}

private final class ScrollCallVisitor: SyntaxVisitor {
    private let proxyName: String
    private(set) var calls: [FunctionCallExprSyntax] = []

    init(proxyName: String) {
        self.proxyName = proxyName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "scrollTo",
           member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == proxyName {
            calls.append(node)
            return .skipChildren
        }
        return .visitChildren
    }
}
