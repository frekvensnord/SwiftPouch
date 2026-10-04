import SwiftParser
import SwiftSyntax

/// Converts a view-builder switch into conditionals understood by the view
/// lowerer. The interpreter still chooses the active case at refresh time.
struct ViewSwitchSourceEditor: Sendable {
    func expand(in source: String) throws -> String {
        var result = source
        for _ in 0..<64 {
            let tree = Parser.parse(source: result)
            guard !tree.hasError else { throw RuntimeViewLoweringError.malformedSyntax }
            let visitor = ViewSwitchVisitor()
            visitor.walk(tree)
            guard let node = visitor.first else { return result }

            var branches: [(condition: String?, body: String)] = []
            for item in node.cases {
                guard let syntaxCase = item.as(SwitchCaseSyntax.self) else {
                    throw RuntimeViewLoweringError.unsupportedExpression("unknown view switch case")
                }
                let body = syntaxCase.statements.description
                switch syntaxCase.label {
                case .case(let label):
                    guard label.caseItems.count == 1, let pattern = label.caseItems.first,
                          pattern.whereClause == nil else {
                        throw RuntimeViewLoweringError.unsupportedExpression(
                            "view switch cases need one pattern without a where clause"
                        )
                    }
                    branches.append((
                        "case \(pattern.pattern.trimmedDescription) = \(node.subject.trimmedDescription)",
                        body
                    ))
                case .default:
                    branches.append((nil, body))
                }
            }
            var rewritten = "EmptyView()"
            for branch in branches.reversed() {
                if let condition = branch.condition {
                    rewritten = "if \(condition) {\n\(branch.body)\n} else {\n\(rewritten)\n}"
                } else {
                    rewritten = "Group {\n\(branch.body)\n}"
                }
            }
            var bytes = Array(result.utf8)
            bytes.replaceSubrange(
                node.positionAfterSkippingLeadingTrivia.utf8Offset
                    ..< node.endPositionBeforeTrailingTrivia.utf8Offset,
                with: rewritten.utf8
            )
            result = String(decoding: bytes, as: UTF8.self)
        }
        throw RuntimeViewLoweringError.unsupportedExpression("too many nested view switches")
    }
}

private final class ViewSwitchVisitor: SyntaxVisitor {
    private(set) var first: SwitchExprSyntax?
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        if isInsideButtonActionClosure(node) { return .skipChildren }
        if first == nil { first = node }
        return .skipChildren
    }
}
