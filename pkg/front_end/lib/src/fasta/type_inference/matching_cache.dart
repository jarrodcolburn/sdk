// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:kernel/src/printer.dart';

import '../../api_unstable/util.dart';
import '../names.dart';
import '../type_inference/external_ast_helper.dart';
import '../type_inference/inference_visitor_base.dart';
import 'delayed_expressions.dart';
import 'object_access_target.dart';
import 'type_schema.dart';

/// Cache used to create a set of pattern matching expressions.
///
/// A single cache is used for creating all pattern matches within a single
/// [PatternSwitchStatement], [SwitchExpression], [IfCaseStatement],
/// [PatternVariableDeclaration] and [PatternAssignment].
class MatchingCache {
  /// Index used to create unique variable names for synthesized variables.
  ///
  /// Currently the VM and dart2js need a non-null name for variables that are
  /// captured within local functions. Depending on caching encoding this can
  /// occur for most variable, so the matching cache conservatively assigns
  /// names to all variables.
  int _cachedExpressionIndex = 0;

  /// Used together with [_cachedExpressionIndex] to create unique indices.
  // TODO(johnniwinther): Can we avoid the need for this?
  final int _matchingCacheIndex;

  final InferenceVisitorBase _base;

  /// If `true`, late variables are lowered into an isSet variable, a caching
  /// variable and local function for accessing and initializing the variable.
  final bool useLowering;

  /// If `true` the encoding will use descriptive names and print statements
  /// in the late lowering.
  final bool useVerboseEncodingForDebugging = false;

  /// If `true`, cacheable are cache even when caching is not required.
  final bool eagerCaching = false;

  /// If `true`, the declarations created for the cached expressions have been
  /// finalized, and no new cached expressions can be created.
  bool _isClosed = false;

  /// The declarations need for the cached expressions.
  List<Statement> _declarations = [];

  /// Map for the known cached keys and their corresponding expressions.
  Map<CacheKey, Cache> _cacheKeyMap = {};

  /// Cache for constant expressions for fixed integer values.
  Map<int, CacheableExpression> _intConstantMap = {};

  /// Map for variable declarations to their aliases.
  ///
  /// This is used for using joint variables instead of the declared variables
  /// for instance in or patterns:
  ///
  ///   if (o case [int a, _] || [_, int a]) { ... }
  ///
  /// where a joint variable is used instead of the two declared 'a' variables.
  Map<VariableDeclaration, VariableDeclaration> _variableAliases = {};

  MatchingCache(this._matchingCacheIndex, this._base)
      : useLowering = _base.libraryBuilder.loader.target.backendTarget
            .isLateLocalLoweringEnabled(
                hasInitializer: true,
                isFinal: true,
                isPotentiallyNullable: true);

  /// Declares that [jointVariables] should be used as aliases of the variables
  /// of the same name in [variables1] and [variables2].
  ///
  /// This is used for instance in or patterns:
  ///
  ///   if (o case [int a, _] || [_, int a]) { ... }
  ///
  /// where a joint variable is used instead of the two declared 'a' variables.
  void declareJointVariables(
      List<VariableDeclaration> jointVariables,
      List<VariableDeclaration> variables1,
      List<VariableDeclaration> variables2) {
    Map<String, VariableDeclaration> jointVariablesMap = {};
    for (VariableDeclaration variable in jointVariables) {
      jointVariablesMap[variable.name!] = variable;
    }
    for (VariableDeclaration variable in variables1) {
      VariableDeclaration? jointVariable = jointVariablesMap[variable.name!];
      if (jointVariable != null) {
        _variableAliases[variable] = jointVariable;
      } else {
        // Error case. This variable is only declared one of the branches and
        // therefore not joint. Include the variable in the declarations.
        registerDeclaration(variable);
      }
    }
    for (VariableDeclaration variable in variables2) {
      VariableDeclaration? jointVariable = jointVariablesMap[variable.name!];
      if (jointVariable != null) {
        _variableAliases[variable] = jointVariable;
      } else {
        // Error case. This variable is only declared one of the branches and
        // therefore not joint. Include the variable in the declarations.
        registerDeclaration(variable);
      }
    }
  }

  /// Returns the unaliased variable for [variable] or [variable] itself, if it
  /// isn't aliased.
  ///
  /// This is used for instance in or patterns:
  ///
  ///   if (o case [int a, _] || [_, int a]) { ... }
  ///
  /// where a joint variable is the unaliased variable for  of the two
  /// declared 'a' variables.
  VariableDeclaration getUnaliasedVariable(VariableDeclaration variable) {
    VariableDeclaration? unalias = _variableAliases[variable];
    if (unalias != null) {
      // Joint variables might themselves be joint, for instance in nested
      // or patterns.
      unalias = getUnaliasedVariable(unalias);
    }
    return unalias ?? variable;
  }

  /// Creates a cacheable expression for the [cacheKey] using [expression] as
  /// the definition of the expression value.
  ///
  /// If [isLate] is `false`, a variable for the value is always created.
  /// Otherwise a late variable (or a lowering of a late variable) is required
  /// if [requiresCaching] `true` and the expression is used more than once.
  ///
  /// If [isConst] is `true`, a const variable is created. This cannot be used
  /// together with [isLate] set to `true`.
  Cache _createCacheableExpression(CacheKey cacheKey,
      {bool isLate = true,
      bool isConst = false,
      required int fileOffset,
      required bool requiresCaching}) {
    assert(!(isLate && isConst), "Cannot create a late const variable.");
    return _cacheKeyMap[cacheKey] = new Cache(
        cacheKey,
        this,
        '${useVerboseEncodingForDebugging ? '${cacheKey.name}' : ''}'
        '#${this._matchingCacheIndex}'
        '#${_cachedExpressionIndex++}',
        isLate: isLate,
        isConst: isConst,
        requiresCaching: requiresCaching,
        fileOffset: fileOffset);
  }

  /// Registers that the variable or local function [declaration] is need for
  /// the cached expressions.
  void registerDeclaration(Statement declaration) {
    assert(!_isClosed);
    _declarations.add(declaration);
  }

  /// Returns the variable or local function declarations needed for the
  /// cached expressions.
  ///
  /// Once called, the matching cache is closed and no new cacheable expressions
  /// can be created.
  Iterable<Statement> get declarations {
    _isClosed = true;
    return _declarations;
  }

  /// Creates the cacheable expression for the scrutinee [expression] of the
  /// [expressionType]. For instance `o` in
  ///
  ///     if (o case <pattern>) { ... }
  ///     switch (o) {  case <pattern>: ... }
  ///     switch (o) {  <pattern> => ... }
  ///     var <pattern> = o;
  ///     <pattern> = o;
  ///
  // TODO(johnniwinther): Support _not_ caching the expression if it is a pure
  // expression like `this`.
  CacheableExpression createRootExpression(
      Expression expression, DartType expressionType) {
    CacheKey cacheKey = new ExpressionKey(expression);
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          isLate: false,
          requiresCaching: true,
          fileOffset: expression.fileOffset);
    }
    return cache.registerAccess(
        null, new FixedExpression(expression, expressionType), const []);
  }

  /// Creates a cacheable expression for integer constant [value].
  CacheableExpression createIntConstant(int value, {required int fileOffset}) {
    CacheableExpression? result = _intConstantMap[value];
    if (result == null) {
      result = _intConstantMap[value] = createConstantExpression(
          createIntLiteral(value, fileOffset: fileOffset),
          _base.coreTypes.intNonNullableRawType);
    }
    return result;
  }

  /// Creates a cacheable expression for the constant [expression] of the
  /// given [expressionType].
  // TODO(johnniwinther): Support using constant value identity to determine
  // the cache key.
  CacheableExpression createConstantExpression(
      Expression expression, DartType expressionType) {
    assert(isKnown(expressionType));
    CacheKey cacheKey = new ExpressionKey(expression);
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          isLate: false,
          isConst: true,
          requiresCaching: true,
          fileOffset: expression.fileOffset);
    }
    return cache.registerAccess(
        null, new FixedExpression(expression, expressionType), const []);
  }

  /// Creates a cacheable as expression of the [operand] against [type].
  CacheableExpression createAsExpression(
      CacheableExpression operand, DartType type,
      {required int fileOffset}) {
    CacheKey cacheKey = new AsKey(operand.cacheKey, type);
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: false, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        null,
        new DelayedAsExpression(operand, type, fileOffset: fileOffset),
        [operand]);
  }

  /// Creates a cacheable expression for a null assert pattern, which asserts
  /// that [operand] is non-null.
  CacheableExpression createNullAssertMatcher(CacheableExpression operand,
      {required int fileOffset}) {
    CacheKey cacheKey = new NullAssertKey(operand.cacheKey);
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: false, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        null,
        new DelayedNullAssertExpression(operand, fileOffset: fileOffset),
        [operand]);
  }

  /// Creates a cacheable expression for a null check pattern, which matches if
  /// [operand] is non-null.
  CacheableExpression createNullCheckMatcher(CacheableExpression operand,
      {required int fileOffset}) {
    CacheKey cacheKey = new NullCheckKey(operand.cacheKey);
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: false, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        null,
        new DelayedNullCheckExpression(operand, fileOffset: fileOffset),
        [operand]);
  }

  /// Creates a cacheable expression for an is test on [operand] against [type].
  CacheableExpression createIsExpression(
      CacheableExpression operand, DartType type,
      {required int fileOffset}) {
    CacheKey cacheKey = new IsKey(operand.cacheKey, type);
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: false, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        null,
        new DelayedIsExpression(operand, type, fileOffset: fileOffset),
        [operand]);
  }

  /// Creates a cacheable expression for accessing the [propertyName] property
  /// on [receiver] of type [receiverType].
  CacheableExpression createPropertyGetExpression(CacheableExpression receiver,
      Name propertyName, ObjectAccessTarget readTarget,
      {required int fileOffset}) {
    CacheKey cacheKey;
    if (readTarget.isStaticAccess) {
      cacheKey = new StaticAccessKey(
          receiver.cacheKey, readTarget.member!, propertyName.text);
    } else {
      cacheKey = new DynamicAccessKey(receiver.cacheKey, propertyName.text);
    }
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: true, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        receiver.getType(_base),
        new DelayedPropertyGetExpression(
            receiver.getType(_base), receiver, readTarget, propertyName,
            fileOffset: fileOffset),
        [receiver]);
  }

  /// Creates a cacheable expression that compares [left] of type [leftType]
  /// against [right] with the [operatorName] operator.
  CacheableExpression createComparisonExpression(
      CacheableExpression left, Name operatorName, CacheableExpression right,
      {required int fileOffset}) {
    ObjectAccessTarget invokeTarget = _base.findInterfaceMember(
        left.getType(_base), operatorName, fileOffset,
        includeExtensionMethods: true,
        callSiteAccessKind: CallSiteAccessKind.operatorInvocation);
    CacheKey cacheKey;
    if (invokeTarget.isStaticAccess) {
      cacheKey = new StaticAccessKey(left.cacheKey, invokeTarget.member!,
          operatorName.text, [right.cacheKey]);
    } else {
      cacheKey = new DynamicAccessKey(
          left.cacheKey, operatorName.text, [right.cacheKey]);
    }
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: true, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        left.getType(_base),
        new DelayedInvokeExpression(left, invokeTarget, operatorName, [right],
            fileOffset: fileOffset),
        [left, right]);
  }

  /// Creates a cacheable expression that checks [left] of type [leftType]
  /// for equality against [right]. If [isNot] is `true`, the result is negated.
  CacheableExpression createEqualsExpression(
      CacheableExpression left, CacheableExpression right,
      {required int fileOffset}) {
    ObjectAccessTarget invokeTarget = _base.findInterfaceMember(
        left.getType(_base), equalsName, fileOffset,
        includeExtensionMethods: true,
        callSiteAccessKind: CallSiteAccessKind.operatorInvocation);
    CacheKey cacheKey;
    if (invokeTarget.isStaticAccess) {
      cacheKey = new StaticAccessKey(left.cacheKey, invokeTarget.member!,
          equalsName.text, [right.cacheKey]);
    } else {
      cacheKey = new DynamicAccessKey(
          left.cacheKey, equalsName.text, [right.cacheKey]);
    }
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: true, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        left.getType(_base),
        new DelayedEqualsExpression(left, invokeTarget, right,
            fileOffset: fileOffset),
        [left, right]);
  }

  /// Creates a cacheable lazy-and expression of [left] and [right].
  CacheableExpression createAndExpression(
      CacheableExpression left, CacheableExpression right,
      {required int fileOffset}) {
    CacheKey cacheKey = new AndKey(left.cacheKey, right.cacheKey);
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: false, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        null,
        new DelayedAndExpression(left, right, fileOffset: fileOffset),
        [left, right]);
  }

  /// Creates a cacheable lazy-or expression of [left] and [right].
  CacheableExpression createOrExpression(InferenceVisitorBase base,
      CacheableExpression left, CacheableExpression right,
      {required int fileOffset}) {
    CacheKey cacheKey = new OrKey(left.cacheKey, right.cacheKey);
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: false, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        null,
        new DelayedOrExpression(left, right, fileOffset: fileOffset),
        [left, right]);
  }

  /// Creates a cacheable expression that accesses the `List.[]` operator on
  /// [receiver] of type [receiverType] with index [headSize].
  ///
  /// This is used access the first elements in a list.
  CacheableExpression createHeadIndexExpression(
      CacheableExpression receiver, int headSize,
      {required int fileOffset}) {
    ObjectAccessTarget invokeTarget = _base.findInterfaceMember(
        receiver.getType(_base), indexGetName, fileOffset,
        includeExtensionMethods: true,
        callSiteAccessKind: CallSiteAccessKind.operatorInvocation);
    CacheKey cacheKey;
    if (invokeTarget.isStaticAccess) {
      cacheKey = new StaticAccessKey(receiver.cacheKey, invokeTarget.member!,
          indexGetName.text, [new IntegerKey(headSize)]);
    } else {
      cacheKey = new DynamicAccessKey(
          receiver.cacheKey, indexGetName.text, [new IntegerKey(headSize)]);
    }
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: true, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        receiver.getType(_base),
        new DelayedInvokeExpression(receiver, invokeTarget, indexGetName,
            [new IntegerExpression(headSize, fileOffset: fileOffset)],
            fileOffset: fileOffset),
        [receiver]);
  }

  /// Creates a cacheable expression that accesses the `List.[]` operator on
  /// [receiver] of type [receiverType] with an index that is [lengthGet], the
  /// `.length` on the [receiver], minus [tailSize].
  ///
  /// This is used access the last elements in a list.
  CacheableExpression createTailIndexExpression(
      CacheableExpression receiver, CacheableExpression length, int tailSize,
      {required int fileOffset}) {
    ObjectAccessTarget invokeTarget = _base.findInterfaceMember(
        receiver.getType(_base), indexGetName, fileOffset,
        includeExtensionMethods: true,
        callSiteAccessKind: CallSiteAccessKind.operatorInvocation);
    const String propertyName = 'tail[]';
    CacheKey cacheKey;
    if (invokeTarget.isStaticAccess) {
      cacheKey = new StaticAccessKey(receiver.cacheKey, invokeTarget.member!,
          propertyName, [new IntegerKey(tailSize)]);
    } else {
      cacheKey = new DynamicAccessKey(
          receiver.cacheKey, propertyName, [new IntegerKey(tailSize)]);
    }
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: true, fileOffset: fileOffset);
    }
    ObjectAccessTarget minusTarget = _base.findInterfaceMember(
        length.getType(_base), minusName, fileOffset,
        includeExtensionMethods: true,
        callSiteAccessKind: CallSiteAccessKind.operatorInvocation);
    return cache.registerAccess(
        receiver.getType(_base),
        new DelayedInvokeExpression(
            receiver,
            invokeTarget,
            indexGetName,
            [
              new DelayedInvokeExpression(length, minusTarget, minusName,
                  [new IntegerExpression(tailSize, fileOffset: fileOffset)],
                  fileOffset: fileOffset)
            ],
            fileOffset: fileOffset),
        [receiver, length]);
  }

  /// Creates a cacheable expression that calls the `List.sublist` method on
  /// [receiver] of type [receiverType] with start index [headIndex] and end
  /// index that is [lengthGet], the `.length` on the [receiver], minus
  /// [tailSize].
  CacheableExpression createSublistExpression(CacheableExpression receiver,
      CacheableExpression length, int headSize, int tailSize,
      {required int fileOffset}) {
    ObjectAccessTarget invokeTarget = _base.findInterfaceMember(
        receiver.getType(_base), sublistName, fileOffset,
        includeExtensionMethods: true,
        callSiteAccessKind: CallSiteAccessKind.operatorInvocation);
    const String propertyName = 'sublist[]';
    CacheKey cacheKey;
    if (invokeTarget.isStaticAccess) {
      cacheKey = new StaticAccessKey(receiver.cacheKey, invokeTarget.member!,
          propertyName, [new IntegerKey(tailSize)]);
    } else {
      cacheKey = new DynamicAccessKey(
          receiver.cacheKey, propertyName, [new IntegerKey(tailSize)]);
    }
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: true, fileOffset: fileOffset);
    }
    DelayedExpression startIndex =
        new IntegerExpression(headSize, fileOffset: fileOffset);
    DelayedExpression? endIndex;
    if (tailSize > 0) {
      ObjectAccessTarget minusTarget = _base.findInterfaceMember(
          length.getType(_base), minusName, fileOffset,
          includeExtensionMethods: true,
          callSiteAccessKind: CallSiteAccessKind.operatorInvocation);
      endIndex = new DelayedInvokeExpression(length, minusTarget, minusName,
          [new IntegerExpression(tailSize, fileOffset: fileOffset)],
          fileOffset: fileOffset);
    }
    return cache.registerAccess(
        receiver.getType(_base),
        new DelayedInvokeExpression(receiver, invokeTarget, sublistName,
            [startIndex, if (endIndex != null) endIndex],
            fileOffset: fileOffset),
        [receiver, length]);
  }

  /// Creates a cacheable expression that calls the `Map.containsKey` on
  /// [receiver] of type [receiverType] with the given [key].
  CacheableExpression createContainsKeyExpression(
      CacheableExpression receiver, CacheableExpression key,
      {required int fileOffset}) {
    ObjectAccessTarget invokeTarget = _base.findInterfaceMember(
        receiver.getType(_base), containsKeyName, fileOffset,
        includeExtensionMethods: true,
        callSiteAccessKind: CallSiteAccessKind.methodInvocation);
    CacheKey cacheKey;
    if (invokeTarget.isStaticAccess) {
      cacheKey = new StaticAccessKey(receiver.cacheKey, invokeTarget.member!,
          containsKeyName.text, [key.cacheKey]);
    } else {
      cacheKey = new DynamicAccessKey(
          receiver.cacheKey, containsKeyName.text, [key.cacheKey]);
    }
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: true, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        receiver.getType(_base),
        new DelayedInvokeExpression(
            receiver, invokeTarget, containsKeyName, [key],
            fileOffset: fileOffset),
        [receiver, key]);
  }

  /// Creates a cacheable expression that access the `Map.[]` on [receiver] of
  /// type [receiverType] with the given [key].
  CacheableExpression createIndexExpression(CacheableExpression receiver,
      CacheableExpression key, ObjectAccessTarget invokeTarget,
      {required int fileOffset}) {
    CacheKey cacheKey;
    if (invokeTarget.isStaticAccess) {
      cacheKey = new StaticAccessKey(receiver.cacheKey, invokeTarget.member!,
          indexGetName.text, [key.cacheKey]);
    } else {
      cacheKey = new DynamicAccessKey(
          receiver.cacheKey, indexGetName.text, [key.cacheKey]);
    }
    Cache? cache = _cacheKeyMap[cacheKey];
    if (cache == null) {
      cache = _createCacheableExpression(cacheKey,
          requiresCaching: true, fileOffset: fileOffset);
    }
    return cache.registerAccess(
        receiver.getType(_base),
        new DelayedInvokeExpression(receiver, invokeTarget, indexGetName, [key],
            fileOffset: fileOffset),
        [receiver, key]);
  }
}

/// A key that identifies the value computed by a [CacheableExpression].
///
/// This is related to the "invocation key" concept found in the patterns
/// specification, but doesn't fully match, since it always for caching of
/// more properties that necessary but also doesn't handle the constant value
/// identity of the constant expressions.
abstract class CacheKey {
  /// Descriptor name of the key used for verbose encoding of cached variables.
  String get name;
}

/// A key that is defined by the [expression] node that created it.
// TODO(johnniwinther): Handle constant expressions differently.
class ExpressionKey extends CacheKey {
  final Expression expression;

  ExpressionKey(this.expression);

  @override
  String get name => '${expression.toText(defaultAstTextStrategy)}';

  @override
  int get hashCode => expression.hashCode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ExpressionKey && expression == other.expression;
  }
}

/// A key for a constant integer value.
class IntegerKey extends CacheKey {
  final int value;

  IntegerKey(this.value);

  @override
  String get name => '$value';

  @override
  int get hashCode => value;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is IntegerKey && value == other.value;
  }
}

/// A key for an is-test, defined by the [receiver] key of the [type].
class IsKey extends CacheKey {
  final CacheKey receiver;
  final DartType type;

  IsKey(this.receiver, this.type);

  @override
  String get name =>
      '${receiver.name}_is_${type.toText(defaultAstTextStrategy)}';

  @override
  int get hashCode => Object.hash(receiver, type);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is IsKey && receiver == other.receiver && type == other.type;
  }
}

/// A key for an as-cast, defined by the [receiver] key of the [type].
class AsKey extends CacheKey {
  final CacheKey receiver;
  final DartType type;

  AsKey(this.receiver, this.type);

  @override
  String get name => '${receiver.name}_as_${type}';

  @override
  int get hashCode => Object.hash(receiver, type);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AsKey && receiver == other.receiver && type == other.type;
  }
}

/// A key for a null check, defined by the [operand] key.
class NullCheckKey extends CacheKey {
  final CacheKey operand;

  NullCheckKey(this.operand);

  @override
  String get name => '${operand.name}?';

  @override
  int get hashCode => operand.hashCode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NullCheckKey && operand == other.operand;
  }
}

/// A key for a null check, defined by the [operand] key.
class NullAssertKey extends CacheKey {
  final CacheKey operand;

  NullAssertKey(this.operand);

  @override
  String get name => '${operand.name}!';

  @override
  int get hashCode => operand.hashCode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NullAssertKey && operand == other.operand;
  }
}

/// A key for a dynamically bound access, defined by the [receiver] key,
/// the [propertyName], and the [arguments].
class DynamicAccessKey extends CacheKey {
  final CacheKey receiver;
  final String propertyName;
  final List<CacheKey>? arguments;

  DynamicAccessKey(this.receiver, this.propertyName, [this.arguments]);

  @override
  String get name {
    StringBuffer sb = new StringBuffer();
    sb.write('${receiver.name}_${propertyName}');
    if (arguments != null) {
      for (CacheKey argument in arguments!) {
        sb.write('_${argument.name}');
      }
    }
    return sb.toString();
  }

  @override
  int get hashCode => Object.hash(receiver, propertyName,
      arguments != null ? Object.hashAll(arguments!) : null);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DynamicAccessKey &&
        receiver == other.receiver &&
        propertyName == other.propertyName &&
        equalLists(arguments, other.arguments);
  }
}

/// A key for a statically bound access, defined by the [receiver] key, the
/// [target], the [propertyName], and the [arguments].
class StaticAccessKey extends CacheKey {
  final CacheKey receiver;
  final Member target;
  final String propertyName;
  final List<CacheKey>? arguments;

  StaticAccessKey(this.receiver, this.target, this.propertyName,
      [this.arguments]);

  @override
  String get name {
    StringBuffer sb = new StringBuffer();
    sb.write('${receiver.name}_${target}');
    if (arguments != null) {
      for (CacheKey argument in arguments!) {
        sb.write('_${argument.name}');
      }
    }
    return sb.toString();
  }

  @override
  int get hashCode => Object.hash(receiver, target, propertyName,
      arguments != null ? Object.hashAll(arguments!) : null);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StaticAccessKey &&
        receiver == other.receiver &&
        target == other.target &&
        propertyName == other.propertyName &&
        equalLists(arguments, other.arguments);
  }
}

/// A key for a lazy-and, defined by the [left] key and [right] key.
class AndKey extends CacheKey {
  final CacheKey left;
  final CacheKey right;

  AndKey(this.left, this.right);

  @override
  String get name => '${left.name}_&&_${right.name}';

  @override
  int get hashCode => Object.hash(left, right);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AndKey && left == other.left && right == other.right;
  }
}

/// A key for a lazy-or, defined by the [left] key and [right] key.
class OrKey extends CacheKey {
  final CacheKey left;
  final CacheKey right;

  OrKey(this.left, this.right);

  @override
  String get name => '${left.name}_||_${right.name}';

  @override
  int get hashCode => Object.hash(left, right);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OrKey && left == other.left && right == other.right;
  }
}

/// A [DelayedExpression] that supports caching of the expression value.
abstract class CacheableExpression implements DelayedExpression {
  /// The [CacheKey] that identifies the computed by the [_expression].
  CacheKey get cacheKey;

  /// Returns `true` if this cacheable expression only has one definition.
  ///
  /// For instance
  ///
  ///    switch (o) {
  ///      case [...]:
  ///      case {...}:
  ///    }
  ///
  /// both cases have an access to `o.length` which must therefore be cached,
  /// but the definitions refer to different interface targets, `List.length`
  /// and `Map.length`, respectively, so we must generated two different
  /// expressions to have statically typed access to each.
  bool get isUniquelyDefined;
}

/// A cacheable expression that can promote the type of the underlying
/// expression upon access.
///
/// This is used to ensure that uses of a cached variable is promoted through
/// the previous matchers. For instance
///
///    switch (o) {
///      case [...]:
///      case {...}:
///    }
///
/// Here two different accesses to `o.length` is generated on the same cached
/// variable, `o`, but with different promoted types, `List<dynamic>` and
/// `Map<dynamic, dynamic>`, respectively, as guarded by the preceding is-tests.
class PromotedCacheableExpression implements CacheableExpression {
  final CacheableExpression _expression;

  final DartType _promotedType;

  PromotedCacheableExpression(this._expression, this._promotedType);

  @override
  CacheKey get cacheKey => _expression.cacheKey;

  @override
  Expression createExpression(InferenceVisitorBase base) {
    Expression result = _expression.createExpression(base);
    if (!base.isAssignable(_promotedType, _expression.getType(base)) ||
        (_promotedType is! DynamicType &&
            _expression.getType(base) is DynamicType)) {
      if (result is VariableGet) {
        result.promotedType = _promotedType;
      } else {
        result = createAsExpression(result, _promotedType,
            forNonNullableByDefault: base.isNonNullableByDefault,
            isUnchecked: true,
            fileOffset: result.fileOffset);
      }
    }
    return result;
  }

  @override
  DartType getType(InferenceVisitorBase base) {
    return _promotedType;
  }

  @override
  bool get isUniquelyDefined => _expression.isUniquelyDefined;

  @override
  void registerUse() {
    _expression.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) {
    return identical(this, expression) || _expression.uses(expression);
  }
}

/// A [CacheableExpression] created using a potentially shared [Cache].
class CacheExpression implements CacheableExpression {
  @override
  final CacheKey cacheKey;

  final Cache _cache;
  final DartType? receiverType;
  final DelayedExpression expression;
  final List<CacheableExpression> _dependencies;

  CacheExpression(this.cacheKey, this._cache, this.receiverType,
      this.expression, this._dependencies);

  @override
  Expression createExpression(InferenceVisitorBase base) {
    return _cache.createExpression(base, receiverType);
  }

  @override
  DartType getType(InferenceVisitorBase base) {
    return expression.getType(base);
  }

  @override
  void registerUse() {
    if (_cache.registerUse()) {
      expression.registerUse();
    }
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || expression.uses(expression);

  @override
  bool get isUniquelyDefined {
    if (!_cache.isUniquelyDefined) {
      return false;
    }
    for (CacheableExpression dependency in _dependencies) {
      if (!dependency.isUniquelyDefined) {
        return false;
      }
    }
    return true;
  }
}

/// Object that tracks computation of cacheable value.
class Cache {
  /// The [CacheKey] that identifies the computed by the [_expression].
  final CacheKey cacheKey;

  /// The matching cache in which this cacheable expression was created.
  final MatchingCache _matchingCache;

  /// Track that number of times the expression is used, as registered through
  /// [registerUser]. This is used to determine whether a caching variable is
  /// needed or the expression can be used in-place.
  int _useCount = 0;

  /// Set to `true` when the encoding of this expression has been chosen
  /// (cached or in-place). No more uses can be registered once it the encoding
  /// has been chosen.
  bool _hasBeenCreated = false;

  /// If cached, the variable that stores the cached value.
  ///
  /// If the caching uses late variables, this will be a late final variable
  /// whose initializer is the expression created by [_expression].
  ///
  /// If the caching uses late lowering, this will be an uninitialized non-final
  /// non-late variable.
  ///
  /// Otherwise [_variable] is unused.
  VariableDeclaration? _variable;

  /// If cached using late lowering, this will be the boolean variable that
  /// tracks whether [_variable] as been initialized.
  ///
  /// Otherwise [_isSetVariable] is unused.
  VariableDeclaration? _isSetVariable;

  /// If cached using late lowering, this will be the variable for the local
  /// function that initializes or reads [_variable].
  ///
  /// Otherwise [_getVariable] is unused.
  VariableDeclaration? _getVariable;

  /// The name used to name [_variable], [_isSetVariable] and [_getVariable].
  final String _name;

  /// If `true`, the expression is lazily cached, if at all.
  final bool _isLate;

  /// If `true`, the [_variable] will be a const variable.
  final bool _isConst;

  /// If `true`, the expression needs to be cached if used more than once.
  final bool _requiresCaching;

  /// The file offset used for synthesized AST nodes.
  final int _fileOffset;

  /// The [CacheExpression] that creates the expression value.
  ///
  /// The key is the receiver type of of the [CacheExpression], or null if the
  /// expression doesn't depend on the receiver type.
  Map<DartType?, CacheExpression> _accesses = {};

  Cache(this.cacheKey, this._matchingCache, this._name,
      {required bool isLate,
      required bool isConst,
      required bool requiresCaching,
      required int fileOffset})
      : this._isLate = isLate,
        this._isConst = isConst,
        this._requiresCaching = requiresCaching,
        this._fileOffset = fileOffset;

  /// Registers that [expression] can be used to compute this value.
  ///
  /// The [receiverType] is the receiver type of of the [expression], or null
  /// if the expression doesn't depend on the receiver type.
  ///
  /// [dependencies] are the cacheable expression used to create [expression].
  ///
  /// Returns a [CacheableExpression] for the [expression].
  CacheableExpression registerAccess(DartType? receiverType,
      DelayedExpression expression, List<CacheableExpression> dependencies) {
    return _accesses[receiverType] ??= new CacheExpression(
        cacheKey, this, receiverType, expression, dependencies);
  }

  /// Returns `true` if there is only one way to compute this cacheable value.
  bool get isUniquelyDefined => _accesses.length <= 1;

  /// Creates an [Expression] for the cacheable value for the given
  /// [receiverType], corresponding to the receiver type provided to
  /// [registerAccess].
  ///
  /// If cached, the value is accessed through a caching variable, otherwise
  /// a fresh [Expression] is created.
  Expression createExpression(
      InferenceVisitorBase base, DartType? receiverType) {
    assert(_useCount >= 1);
    assert(_accesses.isNotEmpty);
    CacheExpression cacheableExpression = _accesses[receiverType]!;
    _hasBeenCreated = true;
    bool createCache;
    if (_isLate) {
      if (_useCount == 1) {
        createCache = false;
      } else {
        createCache = _requiresCaching || _matchingCache.eagerCaching;
      }
    } else {
      createCache = true;
    }
    Expression result;
    if (!createCache) {
      result = cacheableExpression.expression.createExpression(base);
    } else {
      if (_accesses.length == 1 && cacheableExpression.isUniquelyDefined) {
        VariableDeclaration? variable = _variable;
        VariableDeclaration? isSetVariable = _isSetVariable;
        if (variable == null) {
          DartType type = cacheableExpression.getType(base);
          if (_matchingCache.useLowering && _isLate) {
            variable = _variable =
                createUninitializedVariable(type, fileOffset: _fileOffset)
                  ..name = _name;
            _matchingCache.registerDeclaration(variable);
            isSetVariable = _isSetVariable = createInitializedVariable(
                createBoolLiteral(false, fileOffset: _fileOffset),
                base.coreTypes.boolNonNullableRawType,
                fileOffset: _fileOffset)
              ..name = '$_name#isSet';
            _matchingCache.registerDeclaration(isSetVariable);
            VariableDeclaration getVariable =
                _getVariable = createUninitializedVariable(
                    new FunctionType([], type, Nullability.nonNullable),
                    fileOffset: _fileOffset)
                  ..name = '$_name#func'
                  ..isFinal = true;

            Statement body;
            if (_matchingCache.useVerboseEncodingForDebugging) {
              body = createBlock([
                createIfStatement(
                    createNot(createVariableGet(isSetVariable)),
                    createBlock([
                      createExpressionStatement(createStaticInvocation(
                          base.coreTypes.printProcedure,
                          createArguments([
                            createStringConcatenation([
                              createStringLiteral('compute $_name',
                                  fileOffset: _fileOffset),
                            ], fileOffset: _fileOffset)
                          ], fileOffset: _fileOffset),
                          fileOffset: _fileOffset)),
                      createExpressionStatement(createVariableSet(isSetVariable,
                          createBoolLiteral(true, fileOffset: _fileOffset),
                          fileOffset: _fileOffset)),
                      createExpressionStatement(createVariableSet(variable,
                          cacheableExpression.expression.createExpression(base),
                          fileOffset: _fileOffset)),
                    ], fileOffset: _fileOffset),
                    fileOffset: _fileOffset),
                createExpressionStatement(createStaticInvocation(
                    base.coreTypes.printProcedure,
                    createArguments([
                      createStringConcatenation([
                        createStringLiteral('$_name = ',
                            fileOffset: _fileOffset),
                        createVariableGet(variable)
                      ], fileOffset: _fileOffset)
                    ], fileOffset: _fileOffset),
                    fileOffset: _fileOffset)),
                createReturnStatement(createVariableGet(variable),
                    fileOffset: _fileOffset),
              ], fileOffset: _fileOffset)
                ..fileOffset = _fileOffset;
            } else {
              body = createReturnStatement(
                  createConditionalExpression(
                      createVariableGet(isSetVariable),
                      createVariableGet(variable),
                      createLetEffect(
                          effect: createVariableSet(isSetVariable,
                              createBoolLiteral(true, fileOffset: _fileOffset),
                              fileOffset: _fileOffset),
                          result: createVariableSet(
                              variable,
                              cacheableExpression.expression
                                  .createExpression(base),
                              fileOffset: _fileOffset)),
                      staticType: type,
                      fileOffset: _fileOffset),
                  fileOffset: _fileOffset);
            }
            FunctionDeclaration functionDeclaration = new FunctionDeclaration(
                    getVariable, new FunctionNode(body, returnType: type))
                // TODO(johnniwinther): Reinsert the file offset when the vm
                //  doesn't use it for function declaration identity.
                /*..fileOffset = fileOffset*/;
            getVariable.type = functionDeclaration.function
                .computeFunctionType(Nullability.nonNullable);
            _matchingCache.registerDeclaration(functionDeclaration);
          } else {
            variable = _variable = createVariableCache(
                cacheableExpression.expression.createExpression(base),
                cacheableExpression.getType(base))
              ..isConst = _isConst
              ..isLate = _isLate
              ..name = _name;
            _matchingCache.registerDeclaration(variable);
          }
        }
        if (_matchingCache.useLowering && _isLate) {
          result = createLocalFunctionInvocation(_getVariable!,
              fileOffset: _fileOffset);
        } else {
          result = createVariableGet(variable);
        }
      } else {
        assert(_isLate, "Unexpected non-late cache ${cacheKey.name}");

        VariableDeclaration? variable = _variable;
        VariableDeclaration? isSetVariable = _isSetVariable;
        if (variable == null) {
          DartType? cacheType;
          for (CacheExpression expression in _accesses.values) {
            if (cacheType == null) {
              cacheType = expression.getType(base);
            } else if (cacheType != expression.getType(base)) {
              cacheType = const DynamicType();
              break;
            }
          }
          variable = _variable =
              createUninitializedVariable(cacheType!, fileOffset: _fileOffset)
                ..name = _name;
          _matchingCache.registerDeclaration(variable);
          isSetVariable = _isSetVariable = createInitializedVariable(
              createBoolLiteral(false, fileOffset: _fileOffset),
              base.coreTypes.boolNonNullableRawType,
              fileOffset: _fileOffset)
            ..name = '$_name#isSet';
          _matchingCache.registerDeclaration(isSetVariable);
        }
        result = createConditionalExpression(
            createVariableGet(isSetVariable!),
            createVariableGet(variable,
                promotedType: cacheableExpression.getType(base)),
            createLetEffect(
                effect: createVariableSet(isSetVariable,
                    createBoolLiteral(true, fileOffset: _fileOffset),
                    fileOffset: _fileOffset),
                result: createVariableSet(variable,
                    cacheableExpression.expression.createExpression(base),
                    fileOffset: _fileOffset)),
            staticType: cacheableExpression.getType(base),
            fileOffset: _fileOffset);
      }
    }
    return result;
  }

  bool registerUse() {
    assert(!_hasBeenCreated, "Expression has already been created.");
    _useCount++;
    if (_useCount == 1) {
      return true;
    } else {
      bool createCache;
      if (_isLate) {
        createCache = _requiresCaching || _matchingCache.eagerCaching;
      } else {
        createCache = true;
      }
      if (!createCache) {
        return true;
      }
    }
    return false;
  }
}

extension _ on ObjectAccessTarget {
  bool get isStaticAccess {
    switch (kind) {
      case ObjectAccessTargetKind.instanceMember:
      case ObjectAccessTargetKind.nullableInstanceMember:
      case ObjectAccessTargetKind.objectMember:
      case ObjectAccessTargetKind.superMember:
      case ObjectAccessTargetKind.callFunction:
      case ObjectAccessTargetKind.nullableCallFunction:
      case ObjectAccessTargetKind.dynamic:
      case ObjectAccessTargetKind.never:
      case ObjectAccessTargetKind.invalid:
      case ObjectAccessTargetKind.missing:
      case ObjectAccessTargetKind.ambiguous:
      case ObjectAccessTargetKind.recordIndexed:
      case ObjectAccessTargetKind.recordNamed:
      case ObjectAccessTargetKind.nullableRecordIndexed:
      case ObjectAccessTargetKind.nullableRecordNamed:
      case ObjectAccessTargetKind.inlineClassRepresentation:
      case ObjectAccessTargetKind.nullableInlineClassRepresentation:
        return false;
      case ObjectAccessTargetKind.extensionMember:
      case ObjectAccessTargetKind.nullableExtensionMember:
      case ObjectAccessTargetKind.inlineClassMember:
      case ObjectAccessTargetKind.nullableInlineClassMember:
        return true;
    }
  }
}
