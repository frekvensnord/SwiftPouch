import Foundation
import SwiftParser
import SwiftSyntax
import SwiftScriptInterpreter

/// One collection element bound while a repeated view-builder body is lowered.
struct RuntimeForEachItemBinding: Sendable, Hashable {
    let name: String
    let value: Value
}

/// Source range for one repeated closure body and its lexical item binding.
struct RuntimeForEachBindingScope: Sendable {
    let lowerBound: Int
    let upperBound: Int
    let binding: RuntimeForEachItemBinding
}

struct ViewForEachSite: Sendable {
    let collectionExpression: String
    let idKeyPath: String?
    let itemName: String
    let bodySource: String
    let startUTF8Offset: Int
    let endUTF8Offset: Int
}

struct ViewForEachExpandedElement: Sendable {
    let id: RuntimeForEachID
    let binding: RuntimeForEachItemBinding
    let bodySource: String
}

struct ViewForEachSourceReplacement: Sendable {
    let source: String
    let bindingScopes: [RuntimeForEachBindingScope]
}

/// Finds and expands one `ForEach` call at a time. The kernel supplies current
/// collection values and recursively expands nested collections so each body
/// keeps its own captured element and stable identity.
struct ViewForEachSourceEditor: Sendable {
    func firstForEach(in source: String) throws -> ViewForEachSite? {
        let syntaxTree = Parser.parse(source: source)
        guard !syntaxTree.hasError else {
            throw RuntimeViewLoweringError.malformedSyntax
        }

        let visitor = FirstForEachVisitor()
        visitor.walk(syntaxTree)
        guard let call = visitor.call else { return nil }
        return try site(for: call)
    }

    func replacing(
        _ site: ViewForEachSite,
        in source: String,
        with elements: [ViewForEachExpandedElement]
    ) throws -> ViewForEachSourceReplacement {
        let sourceBytes = Array(source.utf8)
        guard site.startUTF8Offset <= site.endUTF8Offset,
              site.endUTF8Offset <= sourceBytes.count else {
            throw RuntimeViewLoweringError.malformedSyntax
        }

        var replacement = "__SwiftPouchForEachGroup { "
        var scopes: [RuntimeForEachBindingScope] = []
        for element in elements {
            replacement += "__SwiftPouchForEachItem(id: \(String(reflecting: element.id.rawValue))) { "
            let lowerBound = replacement.utf8.count
            replacement += element.bodySource
            let upperBound = replacement.utf8.count
            scopes.append(RuntimeForEachBindingScope(
                lowerBound: lowerBound,
                upperBound: upperBound,
                binding: element.binding
            ))
            replacement += " }; "
        }
        replacement += "}"

        var rewrittenBytes = sourceBytes
        rewrittenBytes.replaceSubrange(
            site.startUTF8Offset..<site.endUTF8Offset,
            with: replacement.utf8
        )
        return ViewForEachSourceReplacement(
            source: String(decoding: rewrittenBytes, as: UTF8.self),
            bindingScopes: scopes.map { scope in
                RuntimeForEachBindingScope(
                    lowerBound: scope.lowerBound + site.startUTF8Offset,
                    upperBound: scope.upperBound + site.startUTF8Offset,
                    binding: scope.binding
                )
            }
        )
    }

    /// Makes each loop body visible to the structural lowerer without asking
    /// the interpreter to resolve its element parameter. This validates the
    /// body shape even when the current collection is empty.
    func replacingForEachWithBodies(in source: String) throws -> String {
        var rewritten = source
        var replacements = 0
        while let site = try firstForEach(in: rewritten) {
            guard replacements < 1_024 else {
                throw RuntimeViewLoweringError.unsupportedForEach("too many nested or sibling ForEach expressions")
            }
            let sourceBytes = Array(rewritten.utf8)
            let replacement = "Group { \(site.bodySource) }"
            guard site.startUTF8Offset <= site.endUTF8Offset,
                  site.endUTF8Offset <= sourceBytes.count else {
                throw RuntimeViewLoweringError.malformedSyntax
            }
            var nextBytes = sourceBytes
            nextBytes.replaceSubrange(
                site.startUTF8Offset..<site.endUTF8Offset,
                with: replacement.utf8
            )
            rewritten = String(decoding: nextBytes, as: UTF8.self)
            replacements += 1
        }
        return rewritten
    }

    private func site(for call: FunctionCallExprSyntax) throws -> ViewForEachSite {
        guard call.additionalTrailingClosures.isEmpty,
              let closure = call.trailingClosure,
              call.arguments.count == 1 || call.arguments.count == 2,
              let collectionArgument = call.arguments.first,
              collectionArgument.label == nil else {
            throw RuntimeViewLoweringError.unsupportedForEach(
                "expected ForEach(collection) or ForEach(collection, id: keyPath) with one trailing closure"
            )
        }

        let idKeyPath: String?
        if call.arguments.count == 2 {
            guard let idArgument = call.arguments.last,
                  idArgument.label?.text == "id" else {
                throw RuntimeViewLoweringError.unsupportedForEach("only the `id:` argument is supported")
            }
            let keyPath = idArgument.expression.trimmedDescription
            guard keyPathComponents(keyPath) != nil else {
                throw RuntimeViewLoweringError.unsupportedForEach(
                    "the `id:` argument must be a direct key path such as \\.id or \\.self"
                )
            }
            idKeyPath = keyPath
        } else {
            idKeyPath = nil
        }

        guard let itemName = closureParameterName(closure) else {
            throw RuntimeViewLoweringError.unsupportedForEach(
                "the closure must declare one simple element name, for example `{ item in ... }`"
            )
        }

        return ViewForEachSite(
            collectionExpression: collectionArgument.expression.trimmedDescription,
            idKeyPath: idKeyPath,
            itemName: itemName,
            bodySource: closure.statements.description.trimmingCharacters(in: .whitespacesAndNewlines),
            startUTF8Offset: call.positionAfterSkippingLeadingTrivia.utf8Offset,
            endUTF8Offset: call.endPositionBeforeTrailingTrivia.utf8Offset
        )
    }

    func keyPathComponents(_ keyPath: String) -> [String]? {
        guard keyPath.hasPrefix("\\.") else { return nil }
        let components = keyPath.dropFirst(2).split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  component == "self" || isIdentifier(String(component))
              }) else {
            return nil
        }
        return components.map(String.init)
    }

    private func closureParameterName(_ closure: ClosureExprSyntax) -> String? {
        guard let signature = closure.signature else { return nil }
        let signatureText = signature.trimmedDescription
        guard let inRange = signatureText.range(of: " in") else { return nil }
        let parameterText = signatureText[..<inRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = parameterText
        if candidate.hasPrefix("("), candidate.hasSuffix(")") {
            candidate.removeFirst()
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !candidate.contains(",") else { return nil }
        guard let rawName = candidate
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first else { return nil }
        let name = String(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIdentifier(name) else { return nil }
        return name
    }

    private func isIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first),
              value.unicodeScalars.dropFirst().allSatisfy({
                  $0 == "_" || CharacterSet.alphanumerics.contains($0)
              }) else {
            return false
        }
        return true
    }
}

private final class FirstForEachVisitor: SyntaxVisitor {
    private(set) var call: FunctionCallExprSyntax?

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard call == nil else { return .skipChildren }
        guard node.calledExpression.trimmedDescription == "ForEach",
              !isInsideButtonActionClosure(node) else {
            return .visitChildren
        }
        call = node
        return .skipChildren
    }
}
