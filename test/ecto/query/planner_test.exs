Code.require_file "../../../integration_test/support/types.exs", __DIR__

defmodule Ecto.Query.PlannerTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Query.Planner
  alias Ecto.Query.JoinExpr

  defmodule Comment do
    use Ecto.Schema

    schema "comments" do
      field :text, :string
      field :temp, :string, virtual: true
      field :posted, :naive_datetime
      field :uuid, :binary_id
      field :special, :boolean
      field :crazy_comment, :string

      belongs_to :post, Ecto.Query.PlannerTest.Post

      belongs_to :crazy_post, Ecto.Query.PlannerTest.Post,
        where: {Ecto.Query.PlannerTest.Post, :crazy, []}

      belongs_to :crazy_post_by_parameter, Ecto.Query.PlannerTest.Post,
        where: {Ecto.Query.PlannerTest.Post, :crazy_by_parameter, []},
        foreign_key: :crazy_post_id,
        define_field: false

      has_many :post_comments, through: [:post, :comments]
      has_many :comment_posts, Ecto.Query.PlannerTest.CommentPost
    end

    def crazy() do
      dynamic([row], row.crazy_comment == "crazy")
    end

    def crazy_by_parameter() do
      dynamic([row], row.crazy_comment == ^"crazy")
    end

    def special() do
      dynamic([row], row.special)
    end
  end

  defmodule CommentPost do
    use Ecto.Schema

    schema "comment_posts" do
      belongs_to :comment, Comment
      belongs_to :post, Post
      belongs_to :special_comment, Comment, where: {Comment, :special, []}

      field :deleted, :boolean
    end

    def inactive() do
      dynamic([row], row.deleted)
    end
  end

  defmodule Post do
    use Ecto.Schema

    @primary_key {:id, Custom.Permalink, []}
    @schema_prefix "my_prefix"
    schema "posts" do
      field :title, :string, source: :post_title
      field :text, :string
      field :code, :binary
      field :posted, :naive_datetime
      field :visits, :integer
      field :links, {:array, Custom.Permalink}
      field :crazy_post, :string
      has_many :comments, Ecto.Query.PlannerTest.Comment
      has_many :extra_comments, Ecto.Query.PlannerTest.Comment
      has_many :special_comments, Ecto.Query.PlannerTest.Comment, where: {Ecto.Query.PlannerTest.Comment, :special, []}
      many_to_many :crazy_comments, Comment, join_through: CommentPost, where: {Comment, :crazy, []}
      many_to_many :crazy_comments_by_parameter, Comment, join_through: CommentPost, where: {Comment, :crazy_by_parameter, []}

      many_to_many :shared_special_comments, Comment, join_through: CommentPost, where: {Comment, :special, []}, join_through_where: {CommentPost, :inactive, []}
    end

    def crazy() do
      Ecto.Query.dynamic([row], row.crazy_post == "crazy")
    end

    def crazy_by_parameter() do
      Ecto.Query.dynamic([row], row.crazy_post == ^"crazy")
    end
  end

  defp plan(query, operation \\ :all) do
    Planner.plan(query, operation, Ecto.TestAdapter, 0)
  end

  defp normalize(query, operation \\ :all) do
    normalize_with_params(query, operation) |> elem(0)
  end

  defp normalize_with_params(query, operation \\ :all) do
    {query, params, _key} = plan(query, operation)

    {query, _} =
      query
      |> Planner.ensure_select(operation == :all)
      |> Planner.normalize(operation, Ecto.TestAdapter, 0)

    {query, params}
  end

  defp select_fields(fields, ix) do
    for field <- fields do
      {{:., [], [{:&, [], [ix]}, field]}, [], []}
    end
  end

  test "plan: merges all parameters" do
    query =
      from p in Post,
        select: {p.title, ^"0"},
        join: c in Comment,
        on: c.text == ^"1",
        left_join: d in assoc(p, :comments),
        where: p.title == ^"2",
        group_by: p.title == ^"3",
        having: p.title == ^"4",
        order_by: [asc: fragment("?", ^"5")],
        limit: ^6,
        offset: ^7

    {_query, params, _key} = plan(query)
    assert params == ["0", "1", "2", "3", "4", "5", 6, 7]
  end

  test "plan: checks from" do
    assert_raise Ecto.QueryError, ~r"query must have a from expression", fn ->
      plan(%Ecto.Query{})
    end
  end

  test "plan: casts values" do
    {_query, params, _key} = plan(Post |> where([p], p.id == ^"1"))
    assert params == [1]

    exception = assert_raise Ecto.Query.CastError, fn ->
      plan(Post |> where([p], p.title == ^1))
    end

    assert Exception.message(exception) =~ "value `1` in `where` cannot be cast to type :string"
    assert Exception.message(exception) =~ "where: p.title == ^1"
  end

  test "plan: raises readable error on dynamic expressions/keyword lists" do
    dynamic = dynamic([p], p.id == ^"1")
    {_query, params, _key} = plan(Post |> where([p], ^dynamic))
    assert params == [1]

    assert_raise Ecto.QueryError, ~r/dynamic expressions can only be interpolated/, fn ->
      plan(Post |> where([p], p.title == ^dynamic))
    end

    assert_raise Ecto.QueryError, ~r/keyword lists can only be interpolated/, fn ->
      plan(Post |> where([p], p.title == ^[foo: 1]))
    end
  end

  test "plan: casts and dumps custom types" do
    permalink = "1-hello-world"
    {_query, params, _key} = plan(Post |> where([p], p.id == ^permalink))
    assert params == [1]
  end

  test "plan: casts and dumps binary ids" do
    uuid = "00010203-0405-4607-8809-0a0b0c0d0e0f"
    {_query, params, _key} = plan(Comment |> where([c], c.uuid == ^uuid))
    assert params == [<<0, 1, 2, 3, 4, 5, 70, 7, 136, 9, 10, 11, 12, 13, 14, 15>>]

    assert_raise Ecto.Query.CastError,
                 ~r/`"00010203-0405-4607-8809"` cannot be dumped to type :binary_id/, fn ->
      uuid = "00010203-0405-4607-8809"
      plan(Comment |> where([c], c.uuid == ^uuid))
    end
  end

  test "plan: casts and dumps custom types in left side of in-expressions" do
    permalink = "1-hello-world"
    {_query, params, _key} = plan(Post |> where([p], ^permalink in p.links))
    assert params == [1]

    message = ~r"value `\"1-hello-world\"` in `where` expected to be part of an array but matched type is :string"
    assert_raise Ecto.Query.CastError, message, fn ->
      plan(Post |> where([p], ^permalink in p.text))
    end
  end

  test "plan: casts and dumps custom types in right side of in-expressions" do
    datetime = ~N[2015-01-07 21:18:13.0]
    {_query, params, _key} = plan(Comment |> where([c], c.posted in ^[datetime]))
    assert params == [~N[2015-01-07 21:18:13]]

    permalink = "1-hello-world"
    {_query, params, _key} = plan(Post |> where([p], p.id in ^[permalink]))
    assert params == [1]

    datetime = ~N[2015-01-07 21:18:13.0]
    {_query, params, _key} = plan(Comment |> where([c], c.posted in [^datetime]))
    assert params == [~N[2015-01-07 21:18:13]]

    permalink = "1-hello-world"
    {_query, params, _key} = plan(Post |> where([p], p.id in [^permalink]))
    assert params == [1]

    {_query, params, _key} = plan(Post |> where([p], p.code in [^"abcd"]))
    assert params == ["abcd"]

    {_query, params, _key} = plan(Post |> where([p], p.code in ^["abcd"]))
    assert params == ["abcd"]
  end

  test "plan: casts values on update_all" do
    {_query, params, _key} = plan(Post |> update([p], set: [id: ^"1"]), :update_all)
    assert params == [1]

    {_query, params, _key} = plan(Post |> update([p], set: [title: ^nil]), :update_all)
    assert params == [nil]

    {_query, params, _key} = plan(Post |> update([p], set: [title: nil]), :update_all)
    assert params == []
  end

  test "plan: joins" do
    query = from(p in Post, join: c in "comments") |> plan |> elem(0)
    assert hd(query.joins).source == {"comments", nil}

    query = from(p in Post, join: c in Comment) |> plan |> elem(0)
    assert hd(query.joins).source == {"comments", Comment}

    query = from(p in Post, join: c in {"post_comments", Comment}) |> plan |> elem(0)
    assert hd(query.joins).source == {"post_comments", Comment}
  end

  test "plan: joins associations" do
    query = from(p in Post, join: assoc(p, :comments)) |> plan |> elem(0)
    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :inner} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id()"

    query = from(p in Post, left_join: assoc(p, :comments)) |> plan |> elem(0)
    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :left} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id()"

    query = from(p in Post, left_join: c in assoc(p, :comments), on: p.title == c.text) |> plan |> elem(0)
    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :left} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id() and &0.title() == &1.text()"
  end

  test "plan: nested joins associations" do
    query = from(c in Comment, left_join: assoc(c, :post_comments)) |> plan |> elem(0)
    assert {{"comments", _, _}, {"comments", _, _}, {"posts", _, _}} = query.sources
    assert [join1, join2] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [2, 1]
    assert Macro.to_string(join1.on.expr) == "&2.id() == &0.post_id()"
    assert Macro.to_string(join2.on.expr) == "&1.post_id() == &2.id()"

    query = from(p in Comment, left_join: assoc(p, :post),
                               left_join: assoc(p, :post_comments)) |> plan |> elem(0)
    assert {{"comments", _, _}, {"posts", _, _}, {"comments", _, _}, {"posts", _, _}} = query.sources
    assert [join1, join2, join3] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [1, 3, 2]
    assert Macro.to_string(join1.on.expr) == "&1.id() == &0.post_id()"
    assert Macro.to_string(join2.on.expr) == "&3.id() == &0.post_id()"
    assert Macro.to_string(join3.on.expr) == "&2.post_id() == &3.id()"

    query = from(p in Comment, left_join: assoc(p, :post_comments),
                               left_join: assoc(p, :post)) |> plan |> elem(0)
    assert {{"comments", _, _}, {"comments", _, _}, {"posts", _, _}, {"posts", _, _}} = query.sources
    assert [join1, join2, join3] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [3, 1, 2]
    assert Macro.to_string(join1.on.expr) == "&3.id() == &0.post_id()"
    assert Macro.to_string(join2.on.expr) == "&1.post_id() == &3.id()"
    assert Macro.to_string(join3.on.expr) == "&2.id() == &0.post_id()"
  end

  test "plan: joins associations with custom queries" do
    query = from(p in Post, left_join: assoc(p, :special_comments)) |> plan |> elem(0)

    assert {{"posts", _, _}, {"comments", _, _}} = query.sources
    assert [join] = query.joins
    assert join.ix == 1
    assert Macro.to_string(join.on.expr) == "&1.special() and &1.post_id() == &0.id()"

    query = from(p in Post, left_join: assoc(p, :shared_special_comments)) |> plan |> elem(0)

    assert {{"posts", _, _}, {"comments", _, _}, {"comment_posts", _, _}} = query.sources
    assert [join1, join2] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [2, 1]
    assert Macro.to_string(join1.on.expr) == "&2.deleted() and &2.post_id() == &0.id()"
    assert Macro.to_string(join2.on.expr) == "&1.special() and &2.comment_id() == &1.id()"
  end

  test "plan: nested joins associations with custom queries" do
    query = from(p in Post,
                   join: c in assoc(p, :special_comments),
                   join: p2 in assoc(c, :post),
                   join: c1 in assoc(p, :shared_special_comments),
                   join: cp in assoc(c1, :comment_posts),
                   join: c2 in assoc(cp, :special_comment))
                   |> plan
                   |> elem(0)

    assert [join1, join2, join3, join4, join5, join6] = query.joins
    assert {{"posts", _, _}, {"comments", _, _}, {"posts", _, _}, {"comments", _, _},
            {"comment_posts", _, _}, {"comments", _, _}, {"comment_posts", _, _}} = query.sources

    assert Macro.to_string(join1.on.expr) == "&1.special() and &1.post_id() == &0.id()"
    assert Macro.to_string(join2.on.expr) == "&2.id() == &1.post_id()"
    assert Macro.to_string(join3.on.expr) == "&6.deleted() and &6.post_id() == &0.id()"
    assert Macro.to_string(join4.on.expr) == "&3.special() and &6.comment_id() == &3.id()"
    assert Macro.to_string(join5.on.expr) == "&4.comment_id() == &3.id()"
    assert Macro.to_string(join6.on.expr) == "&5.special() and &5.id() == &4.special_comment_id()"
  end

  test "plan: cannot associate without schema" do
    query   = from(p in "posts", join: assoc(p, :comments))
    message = ~r"cannot perform association join on \"posts\" because it does not have a schema"

    assert_raise Ecto.QueryError, message, fn ->
      plan(query)
    end
  end

  test "plan: requires an association field" do
    query = from(p in Post, join: assoc(p, :title))

    assert_raise Ecto.QueryError, ~r"could not find association `title`", fn ->
      plan(query)
    end
  end

  test "plan: generates a cache key" do
    {_query, _params, key} = plan(from(Post, []))
    assert key == [:all, 0, {"posts", Post, 11832799, "my_prefix"}]

    query =
      from(
        p in Post,
        prefix: "hello",
        select: 1,
        lock: "foo",
        where: is_nil(nil),
        or_where: is_nil(nil),
        join: c in Comment,
        prefix: "world",
        preload: :comments
      )

    {_query, _params, key} = plan(%{query | prefix: "foo"})
    assert key == [:all, 0,
                   {:lock, "foo"},
                   {:prefix, "foo"},
                   {:where, [{:and, {:is_nil, [], [nil]}}, {:or, {:is_nil, [], [nil]}}]},
                   {:join, [{:inner, {"comments", Comment, 47313942, "world"}, true}]},
                   {"posts", Post, 11832799, "hello"},
                   {:select, 1}]
  end

  test "plan: generates a cache key for in based on the adapter" do
    query = from(p in Post, where: p.id in ^[1, 2, 3])

    {_query, _params, key} = Planner.plan(query, :all, Ecto.TestAdapter, 0)
    assert key == :nocache

    {_query, _params, key} = Planner.plan(query, :all, Ecto.Adapters.Postgres, 0)
    assert key != :nocache
  end

  test "plan: normalizes prefixes" do
    # No schema prefix in from
    {query, _, _} = from(Comment, select: 1) |> plan()
    assert query.sources == {{"comments", Comment, nil}}

    {query, _, _} = from(Comment, select: 1) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}}

    {query, _, _} = from(Comment, prefix: "local", select: 1) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "local"}}

    # Schema prefix in from
    {query, _, _} = from(Post, select: 1) |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}}

    {query, _, _} = from(Post, select: 1) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}}

    {query, _, _} = from(Post, prefix: "local", select: 1) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "local"}}

    # Schema prefix in join
    {query, _, _} = from(c in Comment, join: assoc(c, :post)) |> plan()
    assert query.sources == {{"comments", Comment, nil}, {"posts", Post, "my_prefix"}}

    {query, _, _} = from(c in Comment, join: assoc(c, :post)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}, {"posts", Post, "my_prefix"}}

    {query, _, _} = from(c in Comment, join: assoc(c, :post), prefix: "local") |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}, {"posts", Post, "local"}}
  end

  test "prepare: prepare combination queries" do
    {%{combinations: [{_, query}]}, _, _} = from(c in Comment, union: from(c in Comment)) |> plan()
    assert query.sources == {{"comments", Comment, nil}}
    assert %Ecto.Query.SelectExpr{expr: {:&, [], [0]}} = query.select
  end

  test "normalize: validates literal types" do
    assert_raise Ecto.QueryError, fn ->
      Comment |> where([c], c.text == 123) |> normalize()
    end

    assert_raise Ecto.QueryError, fn ->
      Comment |> where([c], c.text == '123') |> normalize()
    end
  end

  test "normalize: tagged types" do
    {query, params} = from(Post, []) |> select([p], type(^"1", :integer))
                                     |> normalize_with_params
    assert query.select.expr ==
           %Ecto.Query.Tagged{type: :integer, value: {:^, [], [0]}, tag: :integer}
    assert params == [1]

    {query, params} = from(Post, []) |> select([p], type(^"1", Custom.Permalink))
                                     |> normalize_with_params
    assert query.select.expr ==
           %Ecto.Query.Tagged{type: :id, value: {:^, [], [0]}, tag: Custom.Permalink}
    assert params == [1]

    {query, params} = from(Post, []) |> select([p], type(^"1", p.visits))
                                     |> normalize_with_params
    assert query.select.expr ==
           %Ecto.Query.Tagged{type: :integer, value: {:^, [], [0]}, tag: :integer}
    assert params == [1]

    assert_raise Ecto.Query.CastError, ~r/value `"1"` in `select` cannot be cast to type Ecto.UUID/, fn ->
      from(Post, []) |> select([p], type(^"1", Ecto.UUID)) |> normalize
    end
  end

  test "normalize: assoc join with wheres that have tagged types" do
    {_query, params} =
      from(post in Post,
        join: comment in assoc(post, :crazy_comments),
        join: post in assoc(comment, :crazy_post)) |> normalize_with_params()

    assert(params == [])
  end

  test "normalize: assoc join with wheres that have parameters" do
    {_query, params} =
      from(post in Post,
        join: comment in assoc(post, :crazy_comments_by_parameter),
        join: post in assoc(comment, :crazy_post_by_parameter)) |> normalize_with_params()

    assert(params == ["crazy", "crazy"])
  end

  test "normalize: dumps in query expressions" do
    assert_raise Ecto.QueryError, ~r"cannot be dumped", fn ->
      normalize(from p in Post, where: p.posted == "2014-04-17 00:00:00")
    end
  end

  test "normalize: validate fields" do
    message = ~r"field `unknown` in `select` does not exist in schema Ecto.Query.PlannerTest.Comment"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(Comment, []) |> select([c], c.unknown)
      normalize(query)
    end

    message = ~r"field `temp` in `select` is a virtual field in schema Ecto.Query.PlannerTest.Comment"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(Comment, []) |> select([c], c.temp)
      normalize(query)
    end
  end

  test "normalize: validate fields in left side of in expressions" do
    query = from(Post, []) |> where([p], p.id in [1, 2, 3])
    normalize(query)

    message = ~r"value `\[1, 2, 3\]` cannot be dumped to type \{:array, :string\}"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(Comment, []) |> where([c], c.text in [1, 2, 3])
      normalize(query)
    end
  end

  test "normalize: flattens and expands right side of in expressions" do
    {query, params} = where(Post, [p], p.id in [1, 2, 3]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in [1, 2, 3]"
    assert params == []

    {query, params} = where(Post, [p], p.id in [^1, 2, ^3]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in [^0, 2, ^1]"
    assert params == [1, 3]

    {query, params} = where(Post, [p], p.id in ^[]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in ^(0, 0)"
    assert params == []

    {query, params} = where(Post, [p], p.id in ^[1, 2, 3]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in ^(0, 3)"
    assert params == [1, 2, 3]

    {query, params} = where(Post, [p], p.title == ^"foo" and p.id in ^[1, 2, 3] and
                                       p.title == ^"bar") |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) ==
           "&0.post_title() == ^0 and &0.id() in ^(1, 3) and &0.post_title() == ^4"
    assert params == ["foo", 1, 2, 3, "bar"]
  end

  test "normalize: reject empty order by and group by" do
    query = order_by(Post, [], []) |> normalize()
    assert query.order_bys == []

    query = order_by(Post, [], ^[]) |> normalize()
    assert query.order_bys == []

    query = group_by(Post, [], []) |> normalize()
    assert query.group_bys == []
  end

  test "normalize: select" do
    query = from(Post, []) |> normalize()
    assert query.select.expr ==
             {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links, :crazy_post], 0)

    query = from(Post, []) |> select([p], {p, p.title}) |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links, :crazy_post], 0) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]

    query = from(Post, []) |> select([p], {p.title, p}) |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links, :crazy_post], 0) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]

    query =
      from(Post, [])
      |> join(:inner, [_], c in Comment)
      |> preload([_, c], comments: c)
      |> select([p, _], {p.title, p})
      |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links, :crazy_post], 0) ++
           select_fields([:id, :text, :posted, :uuid, :special, :crazy_comment, :post_id, :crazy_post_id], 1) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]
  end

  test "normalize: select with struct/2" do
    assert_raise Ecto.QueryError, ~r"struct/2 in select expects a source with a schema", fn ->
      "posts" |> select([p], struct(p, [:id, :title])) |> normalize()
    end

    query = Post |> select([p], struct(p, [:id, :title])) |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields == select_fields([:id, :post_title], 0)

    query = Post |> select([p], {struct(p, [:id, :title]), p.title}) |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]

    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], {p, struct(c, [:id, :text])})
      |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links, :crazy_post], 0) ++
           select_fields([:id, :text], 1)
  end

  test "normalize: select with struct/2 on assoc" do
    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], struct(p, [:id, :title, comments: [:id, :text]]))
      |> preload([p, c], comments: c)
      |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           select_fields([:id, :text], 1)

    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], struct(p, [:id, :title, comments: [:id, :text, post: :id], extra_comments: :id]))
      |> preload([p, c], comments: {c, post: p}, extra_comments: c)
      |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           select_fields([:id], 1) ++
           select_fields([:id, :text], 1) ++
           select_fields([:id], 0)
  end

  test "normalize: select with map/2" do
    query = Post |> select([p], map(p, [:id, :title])) |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields == select_fields([:id, :post_title], 0)

    query = Post |> select([p], {map(p, [:id, :title]), p.title}) |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]

    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], {p, map(c, [:id, :text])})
      |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links, :crazy_post], 0) ++
           select_fields([:id, :text], 1)
  end

  test "normalize: select with map/2 on assoc" do
    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], map(p, [:id, :title, comments: [:id, :text]]))
      |> preload([p, c], comments: c)
      |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           select_fields([:id, :text], 1)

    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], map(p, [:id, :title, comments: [:id, :text, post: :id], extra_comments: :id]))
      |> preload([p, c], comments: {c, post: p}, extra_comments: c)
      |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           select_fields([:id], 1) ++
           select_fields([:id, :text], 1) ++
           select_fields([:id], 0)
  end

  test "normalize: windows" do
    assert_raise Ecto.QueryError, ~r"unknown window :v given to over/2", fn ->
      Comment
      |> windows([c], w: [partition_by: c.id])
      |> select([c], count(c.id) |> over(:v))
      |> normalize()
    end
  end

  test "normalize: preload" do
    message = ~r"the binding used in `from` must be selected in `select` when using `preload`"
    assert_raise Ecto.QueryError, message, fn ->
      Post |> preload(:hello) |> select([p], p.title) |> normalize
    end

    message = ~r"invalid query has specified more bindings than"
    assert_raise Ecto.QueryError, message, fn ->
      Post |> preload([p, c], comments: c) |> normalize
    end
  end

  test "normalize: preload assoc" do
    query = from(p in Post, join: c in assoc(p, :comments), preload: [comments: c])
    normalize(query)

    message = ~r"field `Ecto.Query.PlannerTest.Post.not_field` in preload is not an association"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(p in Post, join: c in assoc(p, :comments), preload: [not_field: c])
      normalize(query)
    end

    message = ~r"requires an inner, left or lateral join, got right join"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(p in Post, right_join: c in assoc(p, :comments), preload: [comments: c])
      normalize(query)
    end
  end

  test "normalize: fragments do not support preloads" do
    query = from p in Post, join: c in fragment("..."), preload: [comments: c]
    assert_raise Ecto.QueryError, ~r/can only preload sources with a schema/, fn ->
      normalize(query)
    end
  end

  test "normalize: all does not allow updates" do
    message = ~r"`all` does not allow `update` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, update: [set: [name: "foo"]]) |> normalize(:all)
    end
  end

  test "normalize: update all only allow filters and checks updates" do
    message = ~r"`update_all` requires at least one field to be updated"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, select: p, update: []) |> normalize(:update_all)
    end

    message = ~r"duplicate field `title` for `update_all`"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, select: p, update: [set: [title: "foo", title: "bar"]])
      |> normalize(:update_all)
    end

    message = ~r"`update_all` allows only `where` and `join` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, order_by: p.title, update: [set: [title: "foo"]]) |> normalize(:update_all)
    end
  end

  test "normalize: delete all only allow filters and forbids updates" do
    message = ~r"`delete_all` does not allow `update` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, update: [set: [name: "foo"]]) |> normalize(:delete_all)
    end

    message = ~r"`delete_all` allows only `where` and `join` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, order_by: p.title) |> normalize(:delete_all)
    end
  end
end
