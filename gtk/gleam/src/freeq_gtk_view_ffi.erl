%% Erlang distribution helpers for freeq_gtk_view (Gleam host).
-module(freeq_gtk_view_ffi).
-export([
    start_node/2,
    register_view/0,
    connect/1,
    push_view/2,
    recv_event/1,
    env_or/2
]).

%% Gleam Event constructors (must match freeq_gtk_view.Event field order).
%% Clicked(id) | Activate(id, text) | Changed(id, text) | Selected(id, index, item) | Unknown(raw)

-spec start_node(binary() | list(), binary() | list()) -> {ok, nil} | {error, binary()}.
start_node(Name0, Cookie0) ->
    %% Prefer name@localhost so peers using @localhost match (not @hostname).
    Name = normalize_node(Name0),
    Cookie = to_atom(Cookie0),
    case net_kernel:start([Name, shortnames]) of
        {ok, _} ->
            true = erlang:set_cookie(node(), Cookie),
            {ok, nil};
        {error, {already_started, _}} ->
            true = erlang:set_cookie(node(), Cookie),
            {ok, nil};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

normalize_node(B) when is_binary(B) ->
    case binary:split(B, <<"@">>) of
        [N] -> binary_to_atom(<<N/binary, "@localhost">>, utf8);
        [_, _] -> binary_to_atom(B, utf8)
    end;
normalize_node(L) when is_list(L) ->
    normalize_node(iolist_to_binary(L));
normalize_node(A) when is_atom(A) ->
    normalize_node(atom_to_binary(A, utf8)).

-spec register_view() -> boolean().
register_view() ->
    try
        true = register(freeq_view, self()),
        true
    catch
        error:badarg ->
            whereis(freeq_view) =:= self()
    end.

-spec connect(binary() | list()) -> boolean().
connect(Node0) ->
    Node = to_atom(Node0),
    net_kernel:connect_node(Node).

%% Push a Gleam View term to {freeq_gtk, Node}.
-spec push_view(binary() | list(), term()) -> {ok, nil} | {error, binary()}.
push_view(Node0, View) ->
    Node = to_atom(Node0),
    case net_kernel:connect_node(Node) of
        true ->
            {freeq_gtk, Node} ! View,
            {ok, nil};
        _ ->
            {error, <<"not connected">>}
    end.

%% Wait for a GTK UI event; decode into a Gleam Event custom type.
-spec recv_event(integer()) -> {ok, term()} | {error, nil}.
recv_event(TimeoutMs) ->
    receive
        Msg -> {ok, decode_event(Msg)}
    after TimeoutMs ->
        {error, nil}
    end.

-spec env_or(binary() | list(), binary() | list()) -> binary().
env_or(Key0, Default0) ->
    Key = to_list(Key0),
    case os:getenv(Key) of
        false -> iolist_to_binary(Default0);
        Val -> iolist_to_binary(Val)
    end.

decode_event({clicked, Id}) ->
    {clicked, to_bin(Id)};
decode_event({activate, Id, Text}) ->
    {activate, to_bin(Id), to_bin(Text)};
decode_event({changed, Id, Text}) ->
    {changed, to_bin(Id), to_bin(Text)};
decode_event({selected, Id, Index, Item}) when is_integer(Index) ->
    {selected, to_bin(Id), Index, to_bin(Item)};
decode_event(Other) ->
    {unknown, iolist_to_binary(io_lib:format("~p", [Other]))}.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

to_atom(B) when is_binary(B) -> binary_to_atom(B, utf8);
to_atom(L) when is_list(L) -> list_to_atom(L);
to_atom(A) when is_atom(A) -> A.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
