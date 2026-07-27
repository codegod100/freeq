%% Erlang distribution + freeq_view registration for freeq-web4 → freeq-gtk.
-module(freeq_web4_gtk_ffi).
-export([
    start_dist/2,
    register_freeq_view/0,
    connect/1,
    push_view/2,
    put_bridge/1,
    get_bridge/0,
    env_or/2,
    decode_event/1
]).

-define(BRIDGE_KEY, {freeq_web4, gtk_bridge_subject}).

-spec start_dist(binary() | list(), binary() | list()) -> {ok, nil} | {error, binary()}.
start_dist(Name0, Cookie0) ->
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
normalize_node(L) when is_list(L) -> normalize_node(iolist_to_binary(L));
normalize_node(A) when is_atom(A) -> normalize_node(atom_to_binary(A, utf8)).

-spec register_freeq_view() -> boolean().
register_freeq_view() ->
    try
        true = register(freeq_view, self()),
        true
    catch
        error:badarg ->
            whereis(freeq_view) =:= self()
    end.

-spec connect(binary() | list()) -> boolean().
connect(Node0) ->
    net_kernel:connect_node(to_atom(Node0)).

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

-spec put_bridge(term()) -> nil.
put_bridge(Subject) ->
    persistent_term:put(?BRIDGE_KEY, Subject),
    nil.

-spec get_bridge() -> {ok, term()} | {error, nil}.
get_bridge() ->
    try
        {ok, persistent_term:get(?BRIDGE_KEY)}
    catch
        error:badarg -> {error, nil}
    end.

-spec env_or(binary() | list(), binary() | list()) -> binary().
env_or(Key0, Default0) ->
    Key = to_list(Key0),
    case os:getenv(Key) of
        false -> iolist_to_binary(Default0);
        Val -> iolist_to_binary(Val)
    end.

%% Decode raw dist mailbox terms into freeq_web4/ui.Event constructors.
-spec decode_event(term()) -> term().
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
