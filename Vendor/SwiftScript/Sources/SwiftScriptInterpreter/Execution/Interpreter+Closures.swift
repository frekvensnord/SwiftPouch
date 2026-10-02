import SwiftSyntax

extension Interpreter {
    /// Build a closure value from a `ClosureExprSyntax`, capturing the
    /// surrounding lexical scope by reference.
    ///
    /// Three forms are recognised:
    /// - `{ x, y in … }`        — shorthand parameters (no types)
    /// - `{ (x: Int) -> Int in … }` — full signature
    /// - `{ $0 + $1 }`          — anonymous; `$N` references resolved at
    ///   call time (the caller binds `$0..$(n-1)` to the passed args).
    func evaluate(closure: ClosureExprSyntax, in scope: Scope) async throws -> Value {
        var parameters: [Function.Parameter] = []
        var returnType: TypeSyntax? = nil
        var captureScope: Scope? = nil

        if let signature = closure.signature {
            // Capture list `[x, y = expr]` — snapshot each named expression
            // *now* and bind into a child scope that becomes the closure's
            // captured environment. `[x]` is shorthand for `[x = x]`.
            if let captureClause = signature.capture {
                let weakNames = captureClause.items.compactMap { item -> String? in
                    item.specifier?.trimmedDescription == "weak" ? item.name.text : nil
                }
                let parent = weakNames.reduce(scope) { current, name in
                    current.detachedScopeForWeakBinding(name)
                }
                let snapshot = Scope(parent: parent)
                for item in captureClause.items {
                    // `[x]`            → name=x, initializer=nil
                    // `[y = expr]`     → name=y, initializer=expr
                    // `[weak self]` stores only a weak reference; reading
                    // it later produces an Optional<ClassInstance>.
                    let bindingName = item.name.text
                    let expression = item.initializer?.value
                        ?? ExprSyntax(DeclReferenceExprSyntax(baseName: item.name))
                    let value = try await evaluate(expression, in: scope)
                    if item.specifier?.trimmedDescription == "weak" {
                        switch value {
                        case .classInstance(let instance):
                            snapshot.bindWeakClassInstance(bindingName, instance: instance)
                        case .optional(.some(.classInstance(let instance))):
                            snapshot.bindWeakClassInstance(bindingName, instance: instance)
                        case .optional(.none):
                            snapshot.bindWeakClassInstance(bindingName, instance: nil)
                        default:
                            throw RuntimeError.invalid("weak capture requires a class instance")
                        }
                    } else {
                        snapshot.bind(bindingName, value: value, mutable: false)
                    }
                }
                captureScope = snapshot
            }
            if let paramClause = signature.parameterClause {
                switch paramClause {
                case .simpleInput(let names):
                    for paramSyntax in names {
                        parameters.append(Function.Parameter(
                            label: nil,
                            name: paramSyntax.name.text,
                            type: nil
                        ))
                    }
                case .parameterClause(let typed):
                    for paramSyntax in typed.parameters {
                        let firstName = paramSyntax.firstName.text
                        let internalName = paramSyntax.secondName?.text ?? firstName
                        parameters.append(Function.Parameter(
                            label: firstName == "_" ? nil : firstName,
                            name: internalName,
                            type: paramSyntax.type
                        ))
                    }
                }
            }
            returnType = signature.returnClause?.type
        }

        let function = Function(
            name: "<closure>",
            parameters: parameters,
            returnType: returnType,
            kind: .user(body: closure.statements, capturedScope: captureScope ?? scope)
        )
        return .function(function)
    }
}
