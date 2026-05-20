# Credo configuration for MosaicDB
# Includes ex_slop plugin for AI-generated code quality checks

%{
  configs: [
    %{
      name: "default",
      strict: false,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          # ── ex_slop: AI-generated code quality checks ──
          # Refactoring anti-patterns
          {ExSlop.Check.Refactor.CaseTrueFalse, []},
          {ExSlop.Check.Refactor.ExplicitSumReduce, []},
          {ExSlop.Check.Refactor.FilterNil, []},
          {ExSlop.Check.Refactor.FlatMapFilter, []},
          {ExSlop.Check.Refactor.GraphemesLength, []},
          {ExSlop.Check.Refactor.IdentityMap, []},
          {ExSlop.Check.Refactor.IdentityPassthrough, []},
          {ExSlop.Check.Refactor.LengthInGuard, []},
          {ExSlop.Check.Refactor.ListFold, []},
          {ExSlop.Check.Refactor.ListLast, []},
          {ExSlop.Check.Refactor.ManualStringReverse, []},
          {ExSlop.Check.Refactor.MapIntoLiteral, []},
          {ExSlop.Check.Refactor.PreferEnumSlice, []},
          {ExSlop.Check.Refactor.ReduceAsMap, []},
          {ExSlop.Check.Refactor.ReduceMapPut, []},
          {ExSlop.Check.Refactor.RedundantBooleanIf, []},
          {ExSlop.Check.Refactor.RedundantEnumJoinSeparator, []},
          {ExSlop.Check.Refactor.RejectNil, []},
          {ExSlop.Check.Refactor.SortForTopK, []},
          {ExSlop.Check.Refactor.SortThenAt, []},
          {ExSlop.Check.Refactor.SortThenReverse, []},
          {ExSlop.Check.Refactor.StringConcatInReduce, []},
          {ExSlop.Check.Refactor.TryRescueWithSafeAlternative, []},
          {ExSlop.Check.Refactor.UseMapJoin, []},
          {ExSlop.Check.Refactor.WithIdentityDo, []},
          {ExSlop.Check.Refactor.WithIdentityElse, []},

          # Readability anti-patterns (AI slop in docs/comments)
          {ExSlop.Check.Readability.BoilerplateDocParams, []},
          {ExSlop.Check.Readability.DocFalseOnPublicFunction, []},
          {ExSlop.Check.Readability.NarratorComment, []},
          {ExSlop.Check.Readability.NarratorDoc, []},
          {ExSlop.Check.Readability.ObviousComment, []},
          {ExSlop.Check.Readability.StepComment, []},
          {ExSlop.Check.Readability.UnaliasedModuleUse, []},

          # Warning anti-patterns
          {ExSlop.Check.Warning.BlanketRescue, []},
          {ExSlop.Check.Warning.DualKeyAccess, []},
          {ExSlop.Check.Warning.GenserverAsKvStore, []},
          {ExSlop.Check.Warning.PathExpandPriv, []},
          {ExSlop.Check.Warning.QueryInEnumMap, []},
          {ExSlop.Check.Warning.RepoAllThenFilter, []},
          {ExSlop.Check.Warning.RescueWithoutReraise, []},

          # ── Core credo checks ──
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          {Credo.Check.Design.AliasUsage, [priority: :low]},
          {Credo.Check.Design.TagTODO, false},
          {Credo.Check.Design.TagFIXME, []},

          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, false},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.Specs, false},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithSingleClause, false},

          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 6]},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapInto, false},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 5]},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},

          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, false},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.UnsafeToAtom, []}
        ]
      }
    }
  ],

  plugins: [
    {ExSlop, []}
  ]
}
