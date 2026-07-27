#!/usr/bin/env escript
%%! -sname freeq_view -setcookie freeq_dev
%% Minimal pure-Erlang view host (same wire shape as Gleam freeq_gtk_view).
-mode(compile).

main([]) ->
    Gtk = 'freeq_gtk@localhost',
    true = register(freeq_view, self()),
    io:format("erlang view host ~p → ~p~n", [node(), Gtk]),
    State = #{
        lines => [<<"· erlang host ready">>, <<"· type in GTK and press Send">>],
        draft => <<>>
    },
    connect_loop(Gtk, State).

connect_loop(Gtk, State) ->
    case net_kernel:connect_node(Gtk) of
        true ->
            io:format("connected~n"),
            push(Gtk, State),
            loop(Gtk, State);
        _ ->
            timer:sleep(1000),
            connect_loop(Gtk, State)
    end.

loop(Gtk, State) ->
    receive
        {changed, <<"input">>, Text} ->
            loop(Gtk, State#{draft => Text});
        {activate, <<"input">>, Text} ->
            loop(Gtk, submit(Gtk, State, Text));
        {clicked, <<"send">>} ->
            #{draft := Draft} = State,
            loop(Gtk, submit(Gtk, State, Draft));
        Other ->
            io:format("event ~p~n", [Other]),
            loop(Gtk, State)
    after 500 ->
        loop(Gtk, State)
    end.

submit(Gtk, State, Text0) ->
    Text = string:trim(Text0),
    case Text of
        <<>> -> State;
        _ ->
            Line = <<"you: ", Text/binary>>,
            #{lines := Lines} = State,
            New = State#{lines => Lines ++ [Line], draft => <<>>},
            push(Gtk, New),
            New
    end.

push(Gtk, #{lines := Lines, draft := Draft}) ->
    View = {view, <<"freeq">>, <<"#playground">>, 720, 520,
            {vbox, <<"root">>, 8, [
                {label, <<"topic">>, <<"Erlang owns this view">>, true},
                {scrolled, <<"log_scroll">>,
                    {list, <<"log">>, Lines}},
                {hbox, <<"composer">>, 8, [
                    {entry, <<"input">>, Draft, <<"Message…">>, false},
                    {button, <<"send">>, <<"Send">>, suggested}
                ]}
            ]}},
    {freeq_gtk, Gtk} ! View,
    ok.
