%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc Utils funcs for emqx-gateway
-module(emqx_gateway_utils).

-include("emqx_gateway.hrl").

-export([ childspec/2
        , childspec/3
        , childspec/4
        , supervisor_ret/1
        , find_sup_child/2
        ]).

-export([ apply/2
        , format_listenon/1
        , parse_listenon/1
        , unix_ts_to_rfc3339/1
        , unix_ts_to_rfc3339/2
        , listener_id/3
        , parse_listener_id/1
        , is_running/2
        ]).

-export([ stringfy/1
        , parse_address/1
        ]).

-export([ normalize_config/1
        ]).

%% Common Envs
-export([ active_n/1
        , ratelimit/1
        , frame_options/1
        , init_gc_state/1
        , stats_timer/1
        , idle_timeout/1
        , oom_policy/1
        ]).

-export([ default_tcp_options/0
        , default_udp_options/0
        , default_subopts/0
        ]).

-define(ACTIVE_N, 100).
-define(DEFAULT_IDLE_TIMEOUT, 30000).
-define(DEFAULT_GC_OPTS, #{count => 1000, bytes => 1024*1024}).
-define(DEFAULT_OOM_POLICY, #{max_heap_size => 4194304,
                              message_queue_len => 32000}).

-spec childspec(supervisor:worker(), Mod :: atom())
    -> supervisor:child_spec().
childspec(Type, Mod) ->
    childspec(Mod, Type, Mod, []).

-spec childspec(supervisor:worker(), Mod :: atom(), Args :: list())
    -> supervisor:child_spec().
childspec(Type, Mod, Args) ->
    childspec(Mod, Type, Mod, Args).

-spec childspec(atom(), supervisor:worker(), Mod :: atom(), Args :: list())
    -> supervisor:child_spec().
childspec(Id, Type, Mod, Args) ->
    #{ id => Id
     , start => {Mod, start_link, Args}
     , type => Type
     }.

-spec supervisor_ret(supervisor:startchild_ret())
    -> {ok, pid()}
     | {error, supervisor:startchild_err()}.
supervisor_ret({ok, Pid, _Info}) -> {ok, Pid};
supervisor_ret(Ret) -> Ret.

-spec find_sup_child(Sup :: pid() | atom(), ChildId :: supervisor:child_id())
    -> false
     | {ok, pid()}.
find_sup_child(Sup, ChildId) ->
    case lists:keyfind(ChildId, 1, supervisor:which_children(Sup)) of
        false -> false;
        {_Id, Pid, _Type, _Mods} -> {ok, Pid}
    end.

apply({M, F, A}, A2) when is_atom(M),
                          is_atom(M),
                          is_list(A),
                          is_list(A2) ->
    erlang:apply(M, F, A ++ A2);
apply({F, A}, A2) when is_function(F),
                       is_list(A),
                       is_list(A2) ->
    erlang:apply(F, A ++ A2);
apply(F, A2) when is_function(F),
                  is_list(A2) ->
    erlang:apply(F, A2).

format_listenon(Port) when is_integer(Port) ->
    io_lib:format("0.0.0.0:~w", [Port]);
format_listenon({Addr, Port}) when is_list(Addr) ->
    io_lib:format("~ts:~w", [Addr, Port]);
format_listenon({Addr, Port}) when is_tuple(Addr) ->
    io_lib:format("~ts:~w", [inet:ntoa(Addr), Port]).

parse_listenon(Port) when is_integer(Port) ->
    Port;
parse_listenon(IpPort) when is_tuple(IpPort) ->
    IpPort;
parse_listenon(Str) when is_binary(Str) ->
    parse_listenon(binary_to_list(Str));
parse_listenon(Str) when is_list(Str) ->
    try list_to_integer(Str)
    catch _ : _ ->
        case emqx_schema:to_ip_port(Str) of
            {ok, R} -> R;
            {error, _} ->
                error({invalid_listenon_name, Str})
        end
    end.

listener_id(GwName, Type, LisName) ->
    binary_to_atom(
      <<(bin(GwName))/binary, ":",
        (bin(Type))/binary,   ":",
        (bin(LisName))/binary
      >>).

parse_listener_id(Id) when is_atom(Id) ->
    parse_listener_id(atom_to_binary(Id));
parse_listener_id(Id) ->
    try
        [GwName, Type, Name] = binary:split(bin(Id), <<":">>, [global]),
        {GwName, Type, Name}
    catch
        _ : _ -> error({invalid_listener_id, Id})
    end.

is_running(ListenerId, #{<<"bind">> := ListenOn0}) ->
    ListenOn = emqx_gateway_utils:parse_listenon(ListenOn0),
    try esockd:listener({ListenerId, ListenOn}) of
        Pid when is_pid(Pid)->
            true
    catch _:_ ->
        false
    end.

bin(A) when is_atom(A) ->
    atom_to_binary(A);
bin(L) when is_list(L); is_binary(L) ->
    iolist_to_binary(L).

unix_ts_to_rfc3339(Keys, Map) when is_list(Keys) ->
    lists:foldl(fun(K, Acc) -> unix_ts_to_rfc3339(K, Acc) end, Map, Keys);
unix_ts_to_rfc3339(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Map;
        Ts ->
          Map#{Key =>
               emqx_rule_funcs:unix_ts_to_rfc3339(Ts, <<"millisecond">>)}
    end.

unix_ts_to_rfc3339(Ts) ->
    emqx_rule_funcs:unix_ts_to_rfc3339(Ts, <<"millisecond">>).

-spec stringfy(term()) -> binary().
stringfy(T) when is_list(T); is_binary(T) ->
    iolist_to_binary(T);
stringfy(T) ->
    iolist_to_binary(io_lib:format("~0p", [T])).

-spec parse_address(binary()|list()) -> {list(), integer()}.
parse_address(S) when is_binary(S); is_list(S) ->
    S1 = case is_binary(S) of
            true -> lists:reverse(binary_to_list(S));
             _ -> lists:reverse(S)
         end,
    case re:split(S1, ":", [{parts, 2}, {return, list}]) of
        [Port0, Host0] ->
            {lists:reverse(Host0), list_to_integer(lists:reverse(Port0))};
        _ ->
            error(badarg)
    end.

-spec normalize_config(emqx_config:config())
    -> list({ Type :: udp | tcp | ssl | dtls
            , Name :: atom()
            , ListenOn :: esockd:listen_on()
            , SocketOpts :: esockd:option()
            , Cfg :: map()
            }).
normalize_config(RawConf) ->
    LisMap = maps:get(listeners, RawConf, #{}),
    Cfg0 = maps:without([listeners], RawConf),
    lists:append(maps:fold(fun(Type, Liss, AccIn1) ->
        Listeners =
            maps:fold(fun(Name, Confs, AccIn2) ->
                ListenOn   = maps:get(bind, Confs),
                SocketOpts = esockd_opts(Type, Confs),
                RemainCfgs = maps:without(
                               [bind, tcp, ssl, udp, dtls]
                               ++ proplists:get_keys(SocketOpts), Confs),
                Cfg = maps:merge(Cfg0, RemainCfgs),
                [{Type, Name, ListenOn, SocketOpts, Cfg}|AccIn2]
            end, [], Liss),
            [Listeners|AccIn1]
    end, [], LisMap)).

esockd_opts(Type, Opts0) ->
    Opts1 = maps:with([acceptors, max_connections, max_conn_rate,
                       proxy_protocol, proxy_protocol_timeout], Opts0),
    Opts2 = Opts1#{access_rules => esockd_access_rules(maps:get(access_rules, Opts0, []))},
    maps:to_list(case Type of
        tcp  -> Opts2#{tcp_options => sock_opts(tcp, Opts0)};
        ssl  -> Opts2#{tcp_options => sock_opts(tcp, Opts0),
                       ssl_options => ssl_opts(ssl, Opts0)};
        udp  -> Opts2#{udp_options => sock_opts(udp, Opts0)};
        dtls -> Opts2#{udp_options => sock_opts(udp, Opts0),
                       dtls_options => ssl_opts(dtls, Opts0)}
    end).

esockd_access_rules(StrRules) ->
    Access = fun(S) ->
        [A, CIDR] = string:tokens(S, " "),
        {list_to_atom(A), case CIDR of "all" -> all; _ -> CIDR end}
    end,
    [Access(R) || R <- StrRules].

ssl_opts(Name, Opts) ->
    maps:to_list(
        emqx_tls_lib:drop_tls13_for_old_otp(
            maps:without([enable],
                maps:get(Name, Opts, #{})))).

sock_opts(Name, Opts) ->
    maps:to_list(
        maps:without([active_n],
            maps:get(Name, Opts, #{}))).

%%--------------------------------------------------------------------
%% Envs

active_n(Options) ->
    maps:get(active_n, Options, ?ACTIVE_N).

-spec idle_timeout(map()) -> pos_integer().
idle_timeout(Options) ->
    maps:get(idle_timeout, Options, ?DEFAULT_IDLE_TIMEOUT).

-spec ratelimit(map()) -> esockd_rate_limit:config() | undefined.
ratelimit(Options) ->
    maps:get(ratelimit, Options, undefined).

-spec frame_options(map()) -> map().
frame_options(Options) ->
    maps:get(frame, Options, #{}).

-spec init_gc_state(map()) -> emqx_gc:gc_state() | undefined.
init_gc_state(Options) ->
    emqx_misc:maybe_apply(fun emqx_gc:init/1, force_gc_policy(Options)).

-spec force_gc_policy(map()) -> emqx_gc:opts() | undefined.
force_gc_policy(Options) ->
    maps:get(force_gc_policy, Options, ?DEFAULT_GC_OPTS).

-spec oom_policy(map()) -> emqx_types:oom_policy().
oom_policy(Options) ->
    maps:get(force_shutdown_policy, Options, ?DEFAULT_OOM_POLICY).

-spec stats_timer(map()) -> undefined | disabled.
stats_timer(Options) ->
    case enable_stats(Options) of true -> undefined; false -> disabled end.

-spec enable_stats(map()) -> boolean().
enable_stats(Options) ->
    maps:get(enable_stats, Options, true).

%%--------------------------------------------------------------------
%% Envs2

default_tcp_options() ->
    [binary, {packet, raw}, {reuseaddr, true},
     {nodelay, true}, {backlog, 512}].

default_udp_options() ->
    [binary].

default_subopts() ->
    #{rh  => 0, %% Retain Handling
      rap => 0, %% Retain as Publish
      nl  => 0, %% No Local
      qos => 0, %% QoS
      is_new => true
     }.
