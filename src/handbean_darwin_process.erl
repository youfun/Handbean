-module(handbean_darwin_process).
-on_load(init/0).

-export([available/0, verify_group/1, cleanup_group/4]).

init() ->
    case os:type() of
        {unix, darwin} ->
            _ = load_nif(),
            ok;
        _ ->
            ok
    end.

load_nif() ->
    case erlang:load_nif("handbean_darwin_process", 0) of
        ok ->
            ok;
        {error, _} ->
            case code:priv_dir(handbean) of
                {error, _} = Error -> Error;
                Priv -> erlang:load_nif(filename:join(Priv, "handbean_darwin_process"), 0)
            end
    end.

%% These fail-closed stubs remain active outside macOS or when the NIF cannot load.
available() -> false.
verify_group(_Pid) -> {error, unsupported}.
cleanup_group(_Pid, _StartSec, _StartUsec, _StartAbstime) -> {error, unsupported}.
