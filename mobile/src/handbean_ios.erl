-module(handbean_ios).
-export([present_file/2, guest_linked/0, guest_exec/3]).
-on_load(init/0).

init() ->
    case os:getenv("MOB_BEAMS_DIR") of
        false -> ok;
        _ -> erlang:load_nif("handbean_ios", 0)
    end.

present_file(_Path, _Mode) ->
    {error, nif_not_loaded}.

guest_linked() ->
    false.

guest_exec(_TimeoutMs, _Root, _Command) ->
    {error, guest_not_linked}.
