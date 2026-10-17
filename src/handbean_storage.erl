-module(handbean_storage).
-on_load(init/0).

-export([lock/1, close/1, append_sync/4, replace_sync/3, remove_sync/2]).

init() ->
    %% Mob statically links this module and flattens application directories.
    %% Desktop releases load the shared library from the OTP priv directory.
    case erlang:load_nif("handbean_storage", 0) of
        ok -> ok;
        {error, _} ->
            case code:priv_dir(handbean) of
                {error, _} = Error -> Error;
                Priv -> erlang:load_nif(filename:join(Priv, "handbean_storage"), 0)
            end
    end.

lock(_Path) -> erlang:nif_error(nif_not_loaded).
close(_Lock) -> erlang:nif_error(nif_not_loaded).
append_sync(_Lock, _Path, _Offset, _Data) -> erlang:nif_error(nif_not_loaded).
replace_sync(_Lock, _Path, _Data) -> erlang:nif_error(nif_not_loaded).
remove_sync(_Lock, _Path) -> erlang:nif_error(nif_not_loaded).
