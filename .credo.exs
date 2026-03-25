%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        excluded: [~r"/deps/", ~r"/_build/", ~r"/node_modules/"]
      },
      strict: true,
      checks: [
        {Credo.Check.Consistency.ExceptionNames, []},
        {Credo.Check.Consistency.LineEndings, []},
        {Credo.Check.Consistency.ParameterPatternMatching, []},
        {Credo.Check.Consistency.SpaceAroundOperators, []},
        {Credo.Check.Consistency.SpaceInParentheses, []},
        {Credo.Check.Consistency.TabsOrSpaces, []},
        {Credo.Check.Design.AliasUsage, [if_nested_deeper_than: 2, if_called_more_often_than: 0]},
        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Design.TagFIXME, []},
        {Credo.Check.Design.TagTODO, []},
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Readability.AliasOrder, []},
        {Credo.Check.Readability.FunctionNames, []},
        {Credo.Check.Readability.LargeNumbers, []},
        {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 100]},
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Readability.ModuleNames, []},
        {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
        {Credo.Check.Readability.PredicateFunctionNames, []},
        {Credo.Check.Readability.StringSigils, []},
        {Credo.Check.Readability.TrailingBlankLine, []},
        {Credo.Check.Readability.WithSingleClause, false},
        {Credo.Check.Refactor.Apply, false},
        {Credo.Check.Refactor.CondStatements, []},
        {Credo.Check.Refactor.CondStatements, false},
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
        {Credo.Check.Refactor.FunctionArity, [max_arity: 5]},
        {Credo.Check.Refactor.FunctionArity, false},
        {Credo.Check.Refactor.MapJoin, false},
        {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
        {Credo.Check.Refactor.Nesting, false},
        {Credo.Check.Refactor.RedundantWithClauseResult, false},
        {Credo.Check.Warning.IExPry, []},
        {Credo.Check.Warning.IoInspect, []},
        {Credo.Check.Warning.OperationOnSameValues, []},
        {Credo.Check.Warning.UnsafeExec, []}
      ]
    }
  ]
}
