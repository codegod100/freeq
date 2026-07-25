%% freeq_web4 FFI — Ed25519 DPoP + DNS TXT for AT handle resolution.
-module(freeq_web4_ffi).
-export([
    ed25519_generate/0,
    ed25519_public/1,
    ed25519_sign/2,
    lookup_txt/1,
    system_time_seconds/0,
    strong_rand_bytes/1
]).

%% {PublicKey :: binary(), PrivateSeed :: binary()} — both 32 bytes.
ed25519_generate() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    Seed =
        case byte_size(Priv) of
            32 -> Priv;
            64 -> binary:part(Priv, 0, 32);
            _ -> Priv
        end,
    {Pub, Seed}.

%% Derive public key from 32-byte seed.
ed25519_public(Seed) when is_binary(Seed), byte_size(Seed) =:= 32 ->
    {Pub, _} = crypto:generate_key(eddsa, ed25519, Seed),
    Pub;
ed25519_public(Priv) when is_binary(Priv), byte_size(Priv) =:= 64 ->
    Seed = binary:part(Priv, 0, 32),
    {Pub, _} = crypto:generate_key(eddsa, ed25519, Seed),
    Pub.

%% Sign message bytes with Ed25519 (EdDSA, no digest).
ed25519_sign(Msg, Seed) when is_binary(Msg), is_binary(Seed) ->
    crypto:sign(eddsa, none, Msg, [Seed, ed25519]).

%% DNS TXT lookup. Returns a list of binary strings (one per TXT string).
lookup_txt(NameBin) when is_binary(NameBin) ->
    Name = unicode:characters_to_list(NameBin),
    case inet_res:lookup(Name, in, txt) of
        Records when is_list(Records) ->
            lists:flatmap(fun txt_strings/1, Records);
        _ ->
            []
    end.

txt_strings([H | _] = L) when is_list(H) ->
    %% list of charlists (split TXT)
    [list_to_binary(lists:flatten(L))];
txt_strings(Txt) when is_list(Txt) ->
    [list_to_binary(Txt)];
txt_strings(Bin) when is_binary(Bin) ->
    [Bin];
txt_strings(_) ->
    [].

system_time_seconds() ->
    erlang:system_time(second).

strong_rand_bytes(N) when is_integer(N), N > 0 ->
    crypto:strong_rand_bytes(N).
