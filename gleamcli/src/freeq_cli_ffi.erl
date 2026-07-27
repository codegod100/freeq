-module(freeq_cli_ffi).
-export([get_line/1, getenv/0]).

get_line(Prompt) when is_binary(Prompt) ->
    case io:get_line(unicode:characters_to_list(Prompt)) of
        eof ->
            {error, nil};
        {error, _Reason} ->
            {error, nil};
        Data when is_binary(Data) ->
            {ok, Data};
        Data when is_list(Data) ->
            {ok, unicode:characters_to_binary(Data)}
    end;
get_line(Prompt) when is_list(Prompt) ->
    get_line(unicode:characters_to_binary(Prompt)).

getenv() ->
    case os:getenv("USER") of
        false ->
            {error, nil};
        Value when is_list(Value) ->
            {ok, unicode:characters_to_binary(Value)};
        Value when is_binary(Value) ->
            {ok, Value}
    end.
