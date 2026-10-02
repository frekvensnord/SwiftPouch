import SwiftSyntax

/// Lexical scope, reference-typed so closures can hold a reference to their
/// enclosing scope and observe mutations to captured `var` bindings.
public final class Scope {
    public let parent: Scope?
    private var bindings: [String: Binding] = [:]
    /// Bodies of `defer` statements registered in this scope, to be run in
    /// reverse order when the scope exits.
    public var deferred: [CodeBlockSyntax] = []

    public init(parent: Scope? = nil) {
        self.parent = parent
    }

    public func bind(_ name: String, value: Value, mutable: Bool, declaredType: TypeSyntax? = nil) {
        bindings[name] = Binding(value: value, mutable: mutable, declaredType: declaredType)
    }

    /// A weak class capture is materialized only when the closure reads it.
    /// Keeping the ClassInstance in a Value.optional would retain it.
    func bindWeakClassInstance(_ name: String, instance: ClassInstance?) {
        bindings[name] = Binding(
            value: .opaque(typeName: "__SwiftScriptWeakClassCapture", value: WeakClassCapture(instance)),
            mutable: false
        )
    }

    /// Copy local lexical bindings around a weak capture without retaining
    /// the method scope that owns its original strong `self` binding.
    func detachedScopeForWeakBinding(_ name: String) -> Scope {
        guard let (_, owner) = lookupWithOwner(name) else { return self }
        var path: [Scope] = []
        var cursor: Scope? = self
        while let current = cursor {
            path.append(current)
            if current === owner { break }
            cursor = current.parent
        }
        var parent = owner.parent
        for original in path.reversed() {
            let copy = Scope(parent: parent)
            original.copyBindings(into: copy, excluding: name)
            parent = copy
        }
        return parent ?? self
    }

    private func materialize(_ binding: Binding) -> Binding {
        if case .opaque("__SwiftScriptWeakClassCapture", let value) = binding.value,
           let box = value as? WeakClassCapture {
            return Binding(
                value: .optional(box.instance.map { .classInstance($0) }),
                mutable: binding.mutable,
                declaredType: binding.declaredType
            )
        }
        return binding
    }

    public func lookup(_ name: String) -> Binding? {
        if let b = bindings[name] { return materialize(b) }
        return parent?.lookup(name)
    }

    /// Variant of `lookup` that also returns the scope where the binding
    /// was found. Used to decide whether an outer-captured var should
    /// lose to an implicit-self field (priority depends on whether the
    /// var lives above or at/below the self-binding scope).
    public func lookupWithOwner(_ name: String) -> (Binding, Scope)? {
        if let b = bindings[name] { return (materialize(b), self) }
        return parent?.lookupWithOwner(name)
    }

    /// True when `descendant` is reachable from `self` walking parent
    /// links (inclusive). Used by the implicit-self vs outer-capture
    /// resolver to decide which binding wins.
    public func isAncestor(of descendant: Scope) -> Bool {
        var cur: Scope? = descendant
        while let s = cur {
            if s === self { return true }
            cur = s.parent
        }
        return false
    }

    @discardableResult
    public func assign(_ name: String, value: Value) -> Bool {
        if let existing = bindings[name] {
            guard existing.mutable else { return false }
            bindings[name] = Binding(value: value, mutable: true, declaredType: existing.declaredType)
            return true
        }
        return parent?.assign(name, value: value) ?? false
    }

    public struct Binding {
        public var value: Value
        public let mutable: Bool
        /// Type annotation supplied at declaration (`var arr: [Int] = …`).
        /// Used by strict-element checks for mutating methods like
        /// `arr.append(x)` and `arr[i] = x`.
        public let declaredType: TypeSyntax?

        public init(value: Value, mutable: Bool, declaredType: TypeSyntax? = nil) {
            self.value = value
            self.mutable = mutable
            self.declaredType = declaredType
        }
    }

    /// Copy the local (non-inherited) bindings from this scope into `other`.
    /// Used when matching nested patterns: a pattern-match builds a child
    /// scope of bindings, and the caller wants those merged into its own.
    public func copyBindings(into other: Scope) {
        copyBindings(into: other, excluding: "")
    }

    private func copyBindings(into other: Scope, excluding excludedName: String) {
        for (bindingName, binding) in bindings {
            if bindingName == excludedName { continue }
            other.bind(bindingName, value: binding.value, mutable: binding.mutable,
                       declaredType: binding.declaredType)
        }
    }
}

private final class WeakClassCapture {
    weak var instance: ClassInstance?

    init(_ instance: ClassInstance?) {
        self.instance = instance
    }
}
